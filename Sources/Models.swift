import Foundation

/// Which transport carries the ELM327 byte stream. Persisted so the app
/// reconnects the same way next launch (and CarPlay picks the same one).
enum TransportKind: String, CaseIterable, Identifiable {
    case bluetooth
    case wifi

    var id: String { rawValue }
    var label: String {
        switch self {
        case .bluetooth: return "Bluetooth"
        case .wifi:      return "Wi-Fi"
        }
    }

    private static let defaultsKey = "transportKind"

    static func saved() -> TransportKind {
        TransportKind(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .bluetooth
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }

    func makeTransport() -> any OBDTransport {
        switch self {
        case .bluetooth: return BLEConnection()
        case .wifi:      return OBDConnection()
        }
    }
}

/// Live DPF state derived from the ECU. All fields optional — not every ECU
/// exposes every signal, and we never fabricate values.
struct DPFState: Codable, Equatable, Sendable {
    /// FCA's proprietary calculated DPF-load index. Community definitions
    /// expose it as a percentage, but it is not a universal physical
    /// saturation measurement and must not be compared blindly across apps.
    var cloggingPercent: Double?
    var exhaustTempC: Double?
    var distanceSinceLastRegenKm: Double?
    var regenProgressPercent: Double?     // 0 when idle, >0 while a regen is running
    var totalRegenCount: Double?
    var regenActive: Bool?                // derived: progress > hysteresis
    /// Audit data for the load value. Persisting it makes an on-road
    /// comparison diagnosable later without Xcode attached.
    var cloggingRaw: UInt32?
    var cloggingECUHeader: String?
    var cloggingSourceVerified: Bool?
    var timestamp: Date = .init()
}

extension DPFState {
    /// True when at least one real ECU value can be shown. The timestamp alone
    /// never turns an empty state into a cached dashboard.
    var hasTelemetry: Bool {
        cloggingPercent != nil
            || exhaustTempC != nil
            || distanceSinceLastRegenKm != nil
            || regenProgressPercent != nil
            || totalRegenCount != nil
    }

    /// Applies only values that were actually read in the new sample.
    /// `nil` means “not refreshed”, never “replace the last valid value”.
    func mergingFreshTelemetry(from fresh: DPFState) -> DPFState {
        var merged = self
        merged.cloggingPercent = fresh.cloggingPercent ?? cloggingPercent
        merged.exhaustTempC = fresh.exhaustTempC ?? exhaustTempC
        merged.distanceSinceLastRegenKm =
            fresh.distanceSinceLastRegenKm ?? distanceSinceLastRegenKm
        merged.regenProgressPercent =
            fresh.regenProgressPercent ?? regenProgressPercent
        merged.totalRegenCount = fresh.totalRegenCount ?? totalRegenCount
        if fresh.cloggingPercent != nil {
            merged.cloggingRaw = fresh.cloggingRaw
            merged.cloggingECUHeader = fresh.cloggingECUHeader
            merged.cloggingSourceVerified = fresh.cloggingSourceVerified
        }
        if fresh.regenActive != nil {
            merged.regenActive = fresh.regenActive
        }
        if fresh.hasTelemetry {
            merged.timestamp = fresh.timestamp
        }
        return merged
    }
}

/// Small local cache used only to restore the last real ECU snapshot. No
/// simulated values are written and nothing leaves the device.
enum DPFStateStore {
    private static let defaultsKey = "lastRealDPFState.v1"

    static func load(from defaults: UserDefaults = .standard) -> DPFState? {
        guard let data = defaults.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(DPFState.self, from: data),
              state.hasTelemetry
        else { return nil }
        return state
    }

    static func save(_ state: DPFState, to defaults: UserDefaults = .standard) {
        guard state.hasTelemetry, let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

/// Repeatable data sets used by the in-app Test Lab. They deliberately feed
/// the same `DPFState` and regeneration state machine used by the real ECU, so
/// the UI, Live Activity and notifications can be exercised without a car.
enum DPFSimulationScenario: String, CaseIterable, Identifiable {
    case clean
    case loaded
    case regenStarted
    case regenInProgress
    case regenFinished
    case unavailable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean:           return "DPF pulito"
        case .loaded:          return "Carico elevato"
        case .regenStarted:    return "Inizio rigenerazione"
        case .regenInProgress: return "Rigenerazione al 52%"
        case .regenFinished:   return "Fine rigenerazione"
        case .unavailable:     return "Dati assenti"
        }
    }

    var detail: String {
        switch self {
        case .clean:           return "28% · temperatura normale"
        case .loaded:          return "88% · rigenerazione vicina"
        case .regenStarted:    return "96% · deve suonare l'avviso"
        case .regenInProgress: return "72% · scarico caldo"
        case .regenFinished:   return "32% · deve suonare la fine"
        case .unavailable:     return "Verifica trattini e stato sconosciuto"
        }
    }

    var symbol: String {
        switch self {
        case .clean:           return "checkmark.circle.fill"
        case .loaded:          return "exclamationmark.triangle.fill"
        case .regenStarted:    return "flame.fill"
        case .regenInProgress: return "arrow.triangle.2.circlepath"
        case .regenFinished:   return "flag.checkered"
        case .unavailable:     return "questionmark.circle"
        }
    }

    func state(at timestamp: Date = .init()) -> DPFState {
        switch self {
        case .clean:
            return DPFState(
                cloggingPercent: 28,
                exhaustTempC: 168,
                distanceSinceLastRegenKm: 35,
                regenProgressPercent: 0,
                totalRegenCount: 291,
                regenActive: false,
                timestamp: timestamp
            )
        case .loaded:
            return DPFState(
                cloggingPercent: 88,
                exhaustTempC: 238,
                distanceSinceLastRegenKm: 410,
                regenProgressPercent: 0,
                totalRegenCount: 291,
                regenActive: false,
                timestamp: timestamp
            )
        case .regenStarted:
            return DPFState(
                cloggingPercent: 96,
                exhaustTempC: 575,
                distanceSinceLastRegenKm: 414,
                regenProgressPercent: 1.5,
                totalRegenCount: 291,
                regenActive: true,
                timestamp: timestamp
            )
        case .regenInProgress:
            return DPFState(
                cloggingPercent: 72,
                exhaustTempC: 648,
                distanceSinceLastRegenKm: 419,
                regenProgressPercent: 52,
                totalRegenCount: 291,
                regenActive: true,
                timestamp: timestamp
            )
        case .regenFinished:
            return DPFState(
                cloggingPercent: 32,
                exhaustTempC: 408,
                distanceSinceLastRegenKm: 0.3,
                regenProgressPercent: 0,
                totalRegenCount: 292,
                regenActive: false,
                timestamp: timestamp
            )
        case .unavailable:
            return DPFState(timestamp: timestamp)
        }
    }
}

enum RegenEvent: Equatable {
    case started(at: Date, cloggingPercent: Double?)
    case finished(at: Date, duration: TimeInterval)
}

/// Converts the continuous ECU "regen process" percentage into stable
/// start/finish edges. It deliberately keeps its state across missing samples:
/// a transient OBD timeout must not create a second start alert when data
/// resumes. A first valid active sample does emit `.started`, so connecting a
/// few seconds after the ECU began regenerating still warns the driver.
struct RegenActivityTracker {
    private static let startThresholdPercent = 0.01
    private static let stopThresholdPercent = 0.001
    /// FCA variants that don't expose a useful progress PID can still be
    /// identified conservatively: during an active burn the exhaust is hot
    /// while the calculated soot load falls steadily.
    private static let inferredStartTemperatureC = 500.0
    private static let inferredStopTemperatureC = 460.0
    private static let inferredMinimumLoadDrop = 1.0
    private static let inferredDeclineSamples = 3
    private static let inferredCoolSamplesToFinish = 3
    private static let maximumCandidateGap: TimeInterval = 90

    private enum Evidence {
        case progressPID
        case thermalLoadTrend
    }

    private(set) var isActive: Bool?
    private var startedAt: Date?
    private var evidence: Evidence?
    private var hotCandidateStartedAt: Date?
    private var hotCandidatePeakLoad: Double?
    private var hotCandidatePreviousLoad: Double?
    private var hotCandidateDeclineCount = 0
    private var hotCandidateLastSampleAt: Date?
    private var consecutiveCoolSamples = 0

    mutating func observe(progressPercent: Double?,
                          at timestamp: Date,
                          cloggingPercent: Double?,
                          exhaustTemperatureC: Double? = nil) -> RegenEvent? {
        let validProgress = progressPercent.flatMap { $0.isFinite ? $0 : nil }

        if isActive == true {
            if validProgress.map({ $0 >= Self.startThresholdPercent }) == true {
                // An inferred transition can later be confirmed by the
                // dedicated PID; from that point its zero edge is definitive.
                evidence = .progressPID
                consecutiveCoolSamples = 0
                return nil
            }

            switch evidence {
            case .progressPID:
                guard validProgress.map({ $0 <= Self.stopThresholdPercent }) == true else {
                    return nil
                }
            case .thermalLoadTrend:
                guard inferredBurnHasFinished(exhaustTemperatureC: exhaustTemperatureC) else {
                    return nil
                }
            case nil:
                return nil
            }

            isActive = false
            guard let startedAt else { return nil }
            self.startedAt = nil
            evidence = nil
            resetHotCandidate()
            return .finished(
                at: timestamp,
                duration: timestamp.timeIntervalSince(startedAt)
            )
        }

        if validProgress.map({ $0 >= Self.startThresholdPercent }) == true {
            isActive = true
            startedAt = timestamp
            evidence = .progressPID
            consecutiveCoolSamples = 0
            resetHotCandidate()
            return .started(at: timestamp, cloggingPercent: cloggingPercent)
        }

        if let inferredStart = observeHotLoadTrend(
            cloggingPercent: cloggingPercent,
            exhaustTemperatureC: exhaustTemperatureC,
            at: timestamp
        ) {
            isActive = true
            startedAt = inferredStart
            evidence = .thermalLoadTrend
            consecutiveCoolSamples = 0
            return .started(at: inferredStart, cloggingPercent: cloggingPercent)
        }

        // Preserve unknown when no trustworthy input exists. A missing sample
        // must not fabricate an idle edge or erase an in-progress candidate.
        guard validProgress != nil || exhaustTemperatureC != nil || cloggingPercent != nil else {
            return nil
        }
        isActive = false
        return nil
    }

    private mutating func observeHotLoadTrend(
        cloggingPercent: Double?,
        exhaustTemperatureC: Double?,
        at timestamp: Date
    ) -> Date? {
        guard let temperature = exhaustTemperatureC,
              temperature.isFinite,
              let load = cloggingPercent,
              load.isFinite
        else { return nil }

        guard temperature >= Self.inferredStartTemperatureC else {
            resetHotCandidate()
            return nil
        }

        if let last = hotCandidateLastSampleAt,
           timestamp.timeIntervalSince(last) > Self.maximumCandidateGap {
            resetHotCandidate()
        }

        if hotCandidateStartedAt == nil {
            hotCandidateStartedAt = timestamp
            hotCandidatePeakLoad = load
            hotCandidatePreviousLoad = load
            hotCandidateLastSampleAt = timestamp
            return nil
        }

        hotCandidatePeakLoad = max(hotCandidatePeakLoad ?? load, load)
        if let previous = hotCandidatePreviousLoad, load < previous - 0.02 {
            hotCandidateDeclineCount += 1
        } else if let previous = hotCandidatePreviousLoad, load > previous + 0.10 {
            hotCandidateDeclineCount = 0
        }
        hotCandidatePreviousLoad = load
        hotCandidateLastSampleAt = timestamp

        let totalDrop = (hotCandidatePeakLoad ?? load) - load
        guard totalDrop >= Self.inferredMinimumLoadDrop,
              hotCandidateDeclineCount >= Self.inferredDeclineSamples
        else { return nil }

        return hotCandidateStartedAt
    }

    private mutating func inferredBurnHasFinished(
        exhaustTemperatureC: Double?
    ) -> Bool {
        guard let temperature = exhaustTemperatureC, temperature.isFinite else {
            return false
        }
        if temperature <= Self.inferredStopTemperatureC {
            consecutiveCoolSamples += 1
        } else {
            consecutiveCoolSamples = 0
        }
        return consecutiveCoolSamples >= Self.inferredCoolSamplesToFinish
    }

    private mutating func resetHotCandidate() {
        hotCandidateStartedAt = nil
        hotCandidatePeakLoad = nil
        hotCandidatePreviousLoad = nil
        hotCandidateDeclineCount = 0
        hotCandidateLastSampleAt = nil
    }
}

/// Alfa / FCA Mode 22 PIDs used for DPF monitoring.
///
/// The load, temperature, regeneration-process and distance definitions below
/// are community-validated on Alfa/FCA diesels; they are not published OEM
/// specifications. The historical regeneration counter is retained only for
/// decoding old captures and is not polled because sources disagree on its
/// PID across ECU variants. If a car returns `NO DATA`, compatibility is
/// unknown rather than something the app should guess.
///
/// Sources:
/// - https://www.alfaowner.com/threads/list-of-pids.305552/
/// - https://torque-bhp.com/community/main-forum/alfa-romeo-giulietta-dpf-pids/
/// - https://www.kapron-ap.com/dpf/dpf-diagnostics-fiat-en.html
enum DPFPID: UInt16, Hashable, Sendable {
    case cloggingPercent      = 0x18E4
    case exhaustTempC         = 0x18DE
    case totalRegenCount      = 0x18A4
    case regenProgressPercent = 0x380B
    case distanceSinceRegenKm = 0x3807

    var mode: UInt8 { 0x22 }

    var command: String {
        String(format: "22%04X", rawValue)
    }

    var formulaDescription: String {
        switch self {
        case .cloggingPercent:
            return "raw×1000/65535"
        case .exhaustTempC:
            return "raw×0.02−40 °C"
        case .totalRegenCount:
            return "raw"
        case .regenProgressPercent:
            return "raw×100/65535"
        case .distanceSinceRegenKm:
            return "raw24×0.1 km"
        }
    }

    func integerRawValue(bytes: [UInt8]) throws -> UInt32 {
        if self == .distanceSinceRegenKm {
            guard bytes.count >= 3 else {
                throw OBDError.protocolError("\(self) needs at least 3 bytes")
            }
            return UInt32(bytes[0]) << 16 |
                UInt32(bytes[1]) << 8 |
                UInt32(bytes[2])
        }

        guard bytes.count >= 2 else {
            throw OBDError.protocolError("\(self) needs at least 2 bytes")
        }
        return UInt32(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
    }

    /// Decodes a positive response payload (bytes after mode+pid echo) into
    /// a physical value. Distance is a three-byte value; the other signals
    /// are big-endian uint16 values.
    func decode(bytes: [UInt8]) throws -> Double {
        let raw = Double(try integerRawValue(bytes: bytes))
        switch self {
        // Exact published FCA/Torque equation. Keep the factor expressed as
        // a ratio: the rounded 0.01526 obscured provenance during comparisons.
        case .cloggingPercent:      return raw * (1000.0 / 65_535.0)
        case .exhaustTempC:         return raw * 0.02 - 40.0
        case .totalRegenCount:      return raw
        case .regenProgressPercent: return raw * (100.0 / 65_535.0)
        case .distanceSinceRegenKm: return raw * 0.1
        }
    }
}
