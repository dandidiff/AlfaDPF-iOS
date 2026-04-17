import Foundation

/// Live DPF state derived from the ECU. All fields optional — not every ECU
/// exposes every signal, and we should never fabricate values.
struct DPFState: Equatable {
    var sootMassGrams: Double?
    var ashMassGrams: Double?
    var distanceSinceLastRegenKm: Double?
    var timeSinceLastRegenMin: Double?
    var exhaustTempC: Double?
    var regenActive: Bool?        // true while a regen cycle is in progress
    var regenRequested: Bool?     // ECU is asking for a regen but it hasn't started
    var timestamp: Date = .init()
}

enum RegenEvent: Equatable {
    case started(at: Date, sootMass: Double?)
    case finished(at: Date, duration: TimeInterval)
    case aborted(at: Date, reason: String)
}

/// OBD PIDs we poll. The Mode 22 values below are **placeholders** — the real
/// Alfa/FCA-specific PIDs must come from the original app's dex or community
/// references before shipping. Leaving as `UInt16` so Mode 22 PIDs fit.
enum DPFPID: UInt16, CaseIterable {
    case sootMass            = 0x1C30  // placeholder
    case ashMass             = 0x1C31  // placeholder
    case distSinceRegen      = 0x1C32  // placeholder
    case timeSinceRegen      = 0x1C33  // placeholder
    case exhaustTemp         = 0x1C34  // placeholder
    case regenStatusBits     = 0x1C35  // placeholder — bitfield: active/requested/aborted

    var mode: UInt8 { 0x22 }
}
