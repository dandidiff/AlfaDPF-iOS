import Foundation

/// Live DPF state derived from the ECU. All fields optional — not every ECU
/// exposes every signal, and we never fabricate values.
struct DPFState: Equatable {
    var cloggingPercent: Double?          // 0..100 — higher = closer to regen
    var exhaustTempC: Double?
    var distanceSinceLastRegenKm: Double?
    var regenProgressPercent: Double?     // 0 when idle, >0 while a regen is running
    var totalRegenCount: Double?
    var regenActive: Bool?                // derived: progress > hysteresis
    var timestamp: Date = .init()
}

enum RegenEvent: Equatable {
    case started(at: Date, cloggingPercent: Double?)
    case finished(at: Date, duration: TimeInterval)
}

/// Alfa / FCA Mode 22 PIDs used for DPF monitoring.
///
/// These are community-verified on Alfa Romeo Giulia 2.2D and shared across
/// the FCA group (Fiat / Alfa / Chrysler use the same ECU family). If your
/// car returns `NO DATA` for one of them, the ECU variant is different —
/// check the forums for your specific model before changing them.
///
/// Sources:
/// - https://www.alfaowner.com/threads/list-of-pids.305552/
/// - https://torque-bhp.com/community/main-forum/alfa-romeo-giulietta-dpf-pids/
/// - https://www.kapron-ap.com/dpf/dpf-diagnostics-fiat-en.html
enum DPFPID: UInt16 {
    case cloggingPercent      = 0x18E4
    case exhaustTempC         = 0x18DE
    case totalRegenCount      = 0x18A4
    case regenProgressPercent = 0x380B
    case distanceSinceRegenKm = 0x3807

    var mode: UInt8 { 0x22 }

    /// Decodes a positive response payload (bytes after mode+pid echo) into
    /// a physical value. Every Alfa DPF signal we've confirmed so far is a
    /// big-endian uint16 that's either multiplied by a constant or offset.
    func decode(bytes: [UInt8]) throws -> Double {
        guard bytes.count >= 2 else {
            throw OBDError.protocolError("\(self) needs at least 2 bytes")
        }
        let raw = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        switch self {
        case .cloggingPercent:      return raw * 0.01526
        case .exhaustTempC:         return raw * 0.02 - 40.0
        case .totalRegenCount:      return raw
        case .regenProgressPercent: return raw * 0.01526
        case .distanceSinceRegenKm: return raw
        }
    }
}
