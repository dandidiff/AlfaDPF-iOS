import Foundation

/// Standard OBD-II Mode 01 live-data reader. These PIDs and decoders are
/// defined by SAE J1979 and work on every OBD-II vehicle, so they give us a
/// real signal on day one — even before the Alfa-specific Mode 22 PIDs for
/// DPF monitoring are mapped.
struct Mode01Reader {
    let connection: any OBDTransport

    struct Live: Equatable {
        var rpm: Double?            // revolutions per minute
        var speedKph: Double?       // km/h
        var coolantC: Double?       // °C
        var intakeTempC: Double?    // °C
        var engineLoadPct: Double?  // %
        var timestamp: Date = .init()
    }

    func poll() async -> Live {
        var out = Live()
        out.rpm          = try? await readDouble(pid: 0x0C, decoder: Self.decodeRPM)
        out.speedKph     = try? await readDouble(pid: 0x0D, decoder: Self.decodeSpeed)
        out.coolantC     = try? await readDouble(pid: 0x05, decoder: Self.decodeCoolant)
        out.intakeTempC  = try? await readDouble(pid: 0x0F, decoder: Self.decodeIntakeTemp)
        out.engineLoadPct = try? await readDouble(pid: 0x04, decoder: Self.decodeEngineLoad)
        return out
    }

    private func readDouble(pid: UInt8, decoder: ([UInt8]) throws -> Double) async throws -> Double {
        let cmd = String(format: "01%02X", pid)
        let response = try await connection.send(cmd)
        let bytes = try Self.parseMode01(response, expectedPID: pid)
        return try decoder(bytes)
    }

    // MARK: - Frame parsing

    /// Parses a Mode 01 response, returning the data bytes after the
    /// `41 <pid>` marker. Tolerates CAN headers when `ATH1` is active.
    static func parseMode01(_ text: String, expectedPID: UInt8) throws -> [UInt8] {
        // 41 = 0x01 + 0x40 (positive reply), followed by the echoed PID.
        try ELM327.extractPayload(after: String(format: "41%02X", expectedPID), in: text)
    }

    // MARK: - Decoders (SAE J1979)

    static func decodeRPM(_ b: [UInt8]) throws -> Double {
        guard b.count >= 2 else { throw OBDError.protocolError("rpm needs 2 bytes") }
        return (Double(b[0]) * 256.0 + Double(b[1])) / 4.0
    }

    static func decodeSpeed(_ b: [UInt8]) throws -> Double {
        guard let v = b.first else { throw OBDError.protocolError("speed needs 1 byte") }
        return Double(v)
    }

    static func decodeCoolant(_ b: [UInt8]) throws -> Double {
        guard let v = b.first else { throw OBDError.protocolError("coolant needs 1 byte") }
        return Double(v) - 40.0
    }

    static func decodeIntakeTemp(_ b: [UInt8]) throws -> Double {
        guard let v = b.first else { throw OBDError.protocolError("intake temp needs 1 byte") }
        return Double(v) - 40.0
    }

    static func decodeEngineLoad(_ b: [UInt8]) throws -> Double {
        guard let v = b.first else { throw OBDError.protocolError("load needs 1 byte") }
        return Double(v) * 100.0 / 255.0
    }
}
