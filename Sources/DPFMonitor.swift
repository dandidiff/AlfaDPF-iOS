import Foundation

/// Atomic hand-off from the OBD actor to the UI coordinator. The ECU values
/// may be retained from the last good poll, while `lastSuccessfulCoreReadAt`
/// tells the caller whether they are still live or must be shown as cached.
struct DPFMonitorSnapshot: Sendable {
    var state = DPFState()
    var pollSequence: UInt64 = 0
    var freshPIDs: Set<DPFPID> = []
    var failedPIDs: Set<DPFPID> = []
    var lastSuccessfulReadAt: Date?
    var lastSuccessfulCoreReadAt: Date?

    var hasFreshCoreTelemetry: Bool {
        freshPIDs.contains(.cloggingPercent)
            || freshPIDs.contains(.exhaustTempC)
            || freshPIDs.contains(.postDPFTempC)
            || freshPIDs.contains(.regenProgressPercent)
    }

    func hasRecentCoreTelemetry(at now: Date = .init(),
                                maximumAge: TimeInterval = 8) -> Bool {
        guard let lastSuccessfulCoreReadAt else { return false }
        return now.timeIntervalSince(lastSuccessfulCoreReadAt) <= maximumAge
    }
}

/// Polls regen-relevant PIDs on a cadence, maintains the latest `DPFState`,
/// and emits `RegenEvent`s on state-transition edges. Owns the only place in
/// the app where raw bytes turn into physical units; scaling factors live on
/// `DPFPID` alongside the state machine that depends on them.
actor DPFMonitor {
    private struct PIDReading {
        var value: Double
        var raw: UInt32
        var bytes: [UInt8]
        var header: String
    }

    private let elm: ELM327
    private let mode01: Mode01Reader
    private let alerts: AlertService
    private var pollTask: Task<Void, Never>?

    private(set) var latest = DPFState()
    private(set) var snapshot = DPFMonitorSnapshot()
    private var regenTracker = RegenActivityTracker()
    private var pollSequence: UInt64 = 0
    private var lastSuccessfulReadAt: Date?
    private var lastSuccessfulCoreReadAt: Date?
    private var pidRetryAfter: [DPFPID: Date] = [:]
    private var mode01RetryAfter: [UInt8: Date] = [:]
    private var preferredExhaustTemperaturePID: DPFPID?

    /// Number of consecutive polls where the regen-progress read failed.
    /// After a few, we drop the state to unknown so we don't keep firing
    /// transitions off stale truth.
    private var consecutiveProgressFailures = 0
    private static let progressFailureThreshold = 3
    init(elm: ELM327, alerts: AlertService) {
        self.elm = elm
        self.mode01 = Mode01Reader(connection: elm.connection)
        self.alerts = alerts
    }

    func start(interval: Duration = .seconds(2)) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Polling

    private func pollOnce() async {
        let sampledAt = Date()
        let cadenceSequence = pollSequence
        var fresh = DPFState(timestamp: sampledAt)
        var freshPIDs: Set<DPFPID> = []
        var failedPIDs: Set<DPFPID> = []

        // Regen progress is the load-bearing signal for the notification
        // edge detector, so read it before all other PIDs. When iOS wakes a
        // BLE app in the background the execution window is deliberately
        // short: start/finish alerts must never sit behind optional telemetry.
        do {
            let reading = try await read(.regenProgressPercent)
            fresh.regenProgressPercent = reading.value
            freshPIDs.insert(.regenProgressPercent)
            consecutiveProgressFailures = 0
        } catch {
            consecutiveProgressFailures += 1
            failedPIDs.insert(.regenProgressPercent)
        }

        // These two signals provide a conservative fallback on ECU variants
        // where 22380B remains zero or is unavailable: a hot exhaust together
        // with a sustained soot-load decrease is a real regeneration.
        do {
            let reading = try await read(.cloggingPercent)
            fresh.cloggingPercent = reading.value
            fresh.cloggingRaw = reading.raw
            fresh.cloggingECUHeader = reading.header
            fresh.cloggingSourceVerified = reading.header == "18DA10F1"
            freshPIDs.insert(.cloggingPercent)
        } catch {
            failedPIDs.insert(.cloggingPercent)
        }
        do {
            let (pid, reading) = try await readPreferredExhaustTemperature()
            fresh.exhaustTempC = reading.value
            fresh.exhaustTemperaturePID = pid.rawValue
            freshPIDs.insert(pid)
        } catch {
            failedPIDs.insert(.exhaustTempC)
            failedPIDs.insert(.postDPFTempC)
        }

        let event = regenTracker.observe(
            progressPercent: fresh.regenProgressPercent,
            at: sampledAt,
            cloggingPercent: fresh.cloggingPercent,
            exhaustTemperatureC: fresh.exhaustTempC
        )
        fresh.regenActive = regenTracker.isActive
        var next = latest.mergingFreshTelemetry(from: fresh)
        if consecutiveProgressFailures >= Self.progressFailureThreshold {
            // The tracker deliberately keeps its internal edge state so a
            // recovered zero can still emit a finish event. The display,
            // however, must not present an old progress/active value as live.
            next.regenProgressPercent = nil
            if event == nil {
                next.regenActive = nil
            }
        }
        // Publish the critical state immediately so the Live Activity/CarPlay
        // poller can render the edge without waiting for secondary ECU reads.
        latest = next

        // Queue the notification as part of this background work item. An
        // unstructured Task could be suspended before reaching the system.
        if let event { await emit(event) }

        // Make the established signals observable before any optional Mode 22
        // request. Actor reentrancy lets the UI poll this snapshot while the
        // ECU is answering the lower-priority reads below.
        pollSequence &+= 1
        let criticalCompletedAt = Date()
        if !freshPIDs.isEmpty {
            lastSuccessfulReadAt = criticalCompletedAt
        }
        if freshPIDs.contains(.cloggingPercent)
            || freshPIDs.contains(.exhaustTempC)
            || freshPIDs.contains(.postDPFTempC)
            || freshPIDs.contains(.regenProgressPercent) {
            lastSuccessfulCoreReadAt = criticalCompletedAt
        }
        snapshot = DPFMonitorSnapshot(
            state: next,
            pollSequence: pollSequence,
            freshPIDs: freshPIDs,
            failedPIDs: failedPIDs,
            lastSuccessfulReadAt: lastSuccessfulReadAt,
            lastSuccessfulCoreReadAt: lastSuccessfulCoreReadAt
        )

        // Non-critical telemetry comes last. A slow or unsupported PID cannot
        // delay the transition detector or its local notification.
        var secondary = DPFState(timestamp: sampledAt)
        // These values change slowly and are not needed for a regeneration
        // edge. Polling every fifth cycle keeps unsupported optional PIDs away
        // from the critical 2-second path.
        switch cadenceSequence % 5 {
        case 0:
            do {
                let reading = try await read(.distanceSinceRegenKm)
                secondary.distanceSinceLastRegenKm = reading.value
                freshPIDs.insert(.distanceSinceRegenKm)
            } catch {
                failedPIDs.insert(.distanceSinceRegenKm)
            }
        case 1:
            do {
                let reading = try await read(.totalRegenCount)
                secondary.totalRegenCount = reading.value
                freshPIDs.insert(.totalRegenCount)
            } catch {
                failedPIDs.insert(.totalRegenCount)
            }
        case 2:
            do {
                let reading = try await read(.oilPressureStatus)
                guard reading.raw <= UInt32(UInt8.max) else {
                    throw OBDError.protocolError("invalid oil pressure state")
                }
                secondary.oilPressureStatusRaw = UInt8(reading.raw)
                freshPIDs.insert(.oilPressureStatus)
            } catch {
                failedPIDs.insert(.oilPressureStatus)
            }
        case 3:
            // Adapter voltage is intentionally secondary: a slow clone must
            // never delay regeneration detection or make core DPF data stale.
            secondary.batteryVoltage = try? await elm.readBatteryVoltage()
        default:
            break
        }

        // Standard engine data comes strictly after the DPF transition
        // detector. Most cycles add one request; the turbo slot adds MAP and
        // barometric pressure so the displayed boost is not altitude-dependent.
        // The explicit functional header also prevents Mode 01 from inheriting
        // the previous physical Mode 22 ATSH context.
        if let physicalHeader = lastGoodHeader,
           let functionalHeader = Mode01Reader.functionalRequestHeader(
               forPhysicalHeader: physicalHeader
           ) {
            switch cadenceSequence % 4 {
            case 0, 2:
                secondary.engineRPM = try? await readMode01(pid: 0x0C) {
                    try await mode01.readRPM(header: functionalHeader)
                }
            case 1:
                let manifold = try? await readMode01(pid: 0x0B) {
                    try await mode01.readManifoldAbsolutePressure(header: functionalHeader)
                }
                let barometric = try? await readMode01(pid: 0x33) {
                    try await mode01.readBarometricPressure(header: functionalHeader)
                }
                if let manifold, let barometric {
                    secondary.turboBoostBar = Mode01Reader.turboBoostBar(
                        manifoldAbsoluteKPa: manifold,
                        barometricKPa: barometric
                    )
                }
            default:
                secondary.coolantTemperatureC = try? await readMode01(pid: 0x05) {
                    try await mode01.readCoolantTemperature(header: functionalHeader)
                }
            }
        }

        next = next.mergingFreshTelemetry(from: secondary)
        latest = next

        let completedAt = Date()
        if !freshPIDs.isEmpty {
            lastSuccessfulReadAt = completedAt
        }
        if freshPIDs.contains(.cloggingPercent)
            || freshPIDs.contains(.exhaustTempC)
            || freshPIDs.contains(.postDPFTempC)
            || freshPIDs.contains(.regenProgressPercent) {
            lastSuccessfulCoreReadAt = completedAt
        }
        snapshot = DPFMonitorSnapshot(
            state: next,
            pollSequence: pollSequence,
            freshPIDs: freshPIDs,
            failedPIDs: failedPIDs,
            lastSuccessfulReadAt: lastSuccessfulReadAt,
            lastSuccessfulCoreReadAt: lastSuccessfulCoreReadAt
        )
    }

    /// Candidate request headers for enhanced (Mode 22) PIDs. The DPF data
    /// lives in one specific ECU that only answers when physically addressed —
    /// the functional broadcast Mode 01 uses returns NO DATA. We try each
    /// until one answers, then cache it. Covers FCA 29-bit layouts (the Giulia
    /// / Stelvio reply from 18DAF1·10/18/01, so we address 18DA·{10,18,01}·F1)
    /// and the 11-bit fallback (7E0), so this self-configures per car.
    private static let candidateECUHeaders = ["18DA10F1", "18DA18F1", "18DA01F1", "7E0"]
    /// Working ECU header per PID — different enhanced signals can live on
    /// different ECUs, so each PID discovers and caches its own.
    private var ecuHeaders: [DPFPID: String] = [:]
    /// Last header that answered anything, tried first to keep probing cheap.
    private var lastGoodHeader: String?

    /// 223915 is the post-DPF probe and is the preferred comparable value for
    /// regeneration temperatures. Some ECU variants only expose the older
    /// 2218DE definition, so it remains an automatic fallback. When fallback
    /// is in use we retry the preferred probe periodically rather than locking
    /// a transient startup failure for the whole drive.
    private func readPreferredExhaustTemperature() async throws -> (DPFPID, PIDReading) {
        if preferredExhaustTemperaturePID == .postDPFTempC {
            do {
                return (.postDPFTempC, try await read(.postDPFTempC))
            } catch {
                preferredExhaustTemperaturePID = nil
            }
        }

        if preferredExhaustTemperaturePID == .exhaustTempC,
           !pollSequence.isMultiple(of: 30) {
            return (.exhaustTempC, try await read(.exhaustTempC))
        }

        do {
            let reading = try await read(.postDPFTempC)
            preferredExhaustTemperaturePID = .postDPFTempC
            return (.postDPFTempC, reading)
        } catch {
            let reading = try await read(.exhaustTempC)
            preferredExhaustTemperaturePID = .exhaustTempC
            return (.exhaustTempC, reading)
        }
    }

    private func read(_ pid: DPFPID) async throws -> PIDReading {
        if let retryAt = pidRetryAfter[pid], retryAt > Date() {
            throw OBDError.protocolError("\(pid.command) temporarily unavailable")
        }
        if let header = ecuHeaders[pid] {
            do {
                return try await read(pid, header: header)
            } catch {
                // A reconnect, ECU wake-up or different vehicle can invalidate
                // yesterday's cached address. Re-probe instead of remaining
                // permanently stuck on a dead header.
                ecuHeaders[pid] = nil
                OBDLog.log("DPF \(pid.command): cached header \(header) failed; probing again")
            }
        }
        // Not locked yet: probe candidate ECU addresses (a known-good one
        // first) until one answers this PID.
        var ordered = Self.candidateECUHeaders
        if let good = lastGoodHeader,
           good != Self.candidateECUHeaders.first,
           let i = ordered.firstIndex(of: good) {
            ordered.remove(at: i)
            // DA10F1 is the documented engine-ECU address for these DPF
            // definitions and always keeps priority. A fallback that answered
            // another PID must not silently redefine 2218E4 on a different ECU.
            ordered.insert(good, at: min(1, ordered.count))
        }
        var lastError: Error = OBDError.protocolError("no ECU answered \(pid)")
        for header in ordered {
            do {
                let reading = try await read(pid, header: header)
                ecuHeaders[pid] = header
                pidRetryAfter[pid] = nil
                lastGoodHeader = header
                OBDLog.log("DPF: \(pid) locked to \(header)")
                return reading
            } catch {
                lastError = error
            }
        }
        pidRetryAfter[pid] = Date().addingTimeInterval(30)
        throw lastError
    }

    private func read(_ pid: DPFPID, header: String) async throws -> PIDReading {
        let bytes = try await elm.readMode22(pid: pid.rawValue, header: header)
        let raw = try pid.integerRawValue(bytes: bytes)
        let value = try pid.decode(bytes: bytes)
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        if pid == .cloggingPercent
            || pid == .regenProgressPercent
            || pid == .oilPressureStatus
            || pid == .exhaustTempC
            || pid == .postDPFTempC {
            OBDLog.log(
                String(
                    format: "DPF %@ header=%@ bytes=%@ raw=%u formula=%@ value=%.3f",
                    pid.command,
                    header,
                    hex,
                    raw,
                    pid.formulaDescription,
                    value
                )
            )
        }
        return PIDReading(value: value, raw: raw, bytes: bytes, header: header)
    }

    private func readMode01(
        pid: UInt8,
        operation: () async throws -> Double
    ) async throws -> Double {
        if let retryAt = mode01RetryAfter[pid], retryAt > Date() {
            throw OBDError.protocolError(
                String(format: "Mode 01 PID %02X temporarily unavailable", pid)
            )
        }
        do {
            let value = try await operation()
            mode01RetryAfter[pid] = nil
            return value
        } catch {
            // Unsupported standard PIDs usually answer NO DATA immediately,
            // while poor clones may consume their full timeout. Back off so a
            // missing optional value cannot make every DPF cycle sluggish.
            mode01RetryAfter[pid] = Date().addingTimeInterval(30)
            throw error
        }
    }

    // MARK: - Event detection

    private func emit(_ event: RegenEvent) async {
        switch event {
        case .started(_, let cloggingPercent):
            await alerts.notifyRegenStarted(cloggingPercent: cloggingPercent)
        case .finished(_, let duration):
            await alerts.notifyRegenFinished(duration: duration)
        }
    }
}
