import Foundation

/// Polls regen-relevant PIDs on a cadence, maintains the latest `DPFState`,
/// and emits `RegenEvent`s on state-transition edges. Owns the only place in
/// the app where raw bytes turn into physical units; scaling factors live
/// here alongside the state machine that depends on them.
actor DPFMonitor {
    private let elm: ELM327
    private let alerts: AlertService
    private var pollTask: Task<Void, Never>?

    private(set) var latest = DPFState()
    private var regenStartedAt: Date?

    /// True until the first poll has populated a baseline. Prevents the
    /// "plug in mid-regen and get a spurious started alert" bug.
    private var needsBaseline = true

    /// Number of consecutive polls where the regen-status read failed. After
    /// a few, we drop the state to unknown so we don't keep firing
    /// transitions off stale truth.
    private var consecutiveStatusFailures = 0
    private static let statusFailureThreshold = 3

    init(elm: ELM327, alerts: AlertService) {
        self.elm = elm
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
        var next = DPFState()
        next.timestamp = Date()

        next.sootMassGrams = try? await readScaled(.sootMass, scale: 1.0 / 100.0)
        next.ashMassGrams = try? await readScaled(.ashMass, scale: 1.0 / 100.0)
        next.distanceSinceLastRegenKm = try? await readScaled(.distSinceRegen, scale: 1.0)
        next.timeSinceLastRegenMin = try? await readScaled(.timeSinceRegen, scale: 1.0)
        next.exhaustTempC = try? await readScaled(.exhaustTemp, scale: 0.1, offset: -40)

        // Regen status is the load-bearing signal. Track failures explicitly.
        do {
            let bytes = try await elm.readMode22(pid: DPFPID.regenStatusBits.rawValue)
            if let bits = bytes.first {
                next.regenActive = (bits & 0b0000_0001) != 0
                next.regenRequested = (bits & 0b0000_0010) != 0
                consecutiveStatusFailures = 0
            }
        } catch {
            consecutiveStatusFailures += 1
            if consecutiveStatusFailures >= Self.statusFailureThreshold {
                // Don't carry stale regen state forward — mark unknown so the
                // edge detector can't fire phantom transitions.
                next.regenActive = nil
                next.regenRequested = nil
            } else {
                // Short blips: keep the previous values so the UI doesn't flicker.
                next.regenActive = latest.regenActive
                next.regenRequested = latest.regenRequested
            }
        }

        if needsBaseline {
            needsBaseline = false
        } else {
            emitEvents(previous: latest, current: next)
        }
        latest = next
    }

    private func readScaled(_ pid: DPFPID, scale: Double, offset: Double = 0) async throws -> Double {
        let bytes = try await elm.readMode22(pid: pid.rawValue)
        // Default decode: big-endian UInt (1..4 bytes) * scale + offset.
        // Real signals need per-PID decoders — flag for review.
        guard !bytes.isEmpty, bytes.count <= 4 else {
            throw OBDError.protocolError("unexpected byte count for \(pid)")
        }
        let raw = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Double(raw) * scale + offset
    }

    // MARK: - Event detection

    private func emitEvents(previous: DPFState, current: DPFState) {
        // Edges only fire on known→known transitions. nil means we don't
        // know, so we refuse to guess.
        guard let wasActive = previous.regenActive,
              let nowActive = current.regenActive else { return }

        if !wasActive && nowActive {
            regenStartedAt = current.timestamp
            Task { await alerts.notifyRegenStarted(sootMass: current.sootMassGrams) }
        } else if wasActive && !nowActive, let started = regenStartedAt {
            let duration = current.timestamp.timeIntervalSince(started)
            regenStartedAt = nil
            Task { await alerts.notifyRegenFinished(duration: duration) }
        }
    }
}
