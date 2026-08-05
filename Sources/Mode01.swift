import Foundation

/// Standard OBD-II Mode 01 live-data reader. These PIDs and decoders are
/// defined by SAE J1979 and are read only when the ECU supports them. They
/// provide portable engine data without pretending that every vehicle exposes
/// every optional PID.
struct Mode01Reader {
    let connection: any OBDTransport

    struct Live: Equatable {
        var rpm: Double?            // revolutions per minute
        var speedKph: Double?       // km/h
        var coolantC: Double?       // °C
        var intakeTempC: Double?    // °C
        var engineLoadPct: Double?  // %
        var turboBoostBar: Double?  // MAP minus barometric pressure
        var timestamp: Date = .init()
    }

    func poll() async -> Live {
        var out = Live()
        out.rpm          = try? await readRPM()
        out.speedKph     = try? await readDouble(pid: 0x0D, header: nil, decoder: Self.decodeSpeed)
        out.coolantC     = try? await readCoolantTemperature()
        out.intakeTempC  = try? await readDouble(pid: 0x0F, header: nil, decoder: Self.decodeIntakeTemp)
        out.engineLoadPct = try? await readDouble(pid: 0x04, header: nil, decoder: Self.decodeEngineLoad)
        if let manifold = try? await readManifoldAbsolutePressure(),
           let barometric = try? await readBarometricPressure() {
            out.turboBoostBar = Self.turboBoostBar(
                manifoldAbsoluteKPa: manifold,
                barometricKPa: barometric
            )
        }
        return out
    }

    func readRPM(header: String? = nil) async throws -> Double {
        try await readDouble(pid: 0x0C, header: header, decoder: Self.decodeRPM)
    }

    func readCoolantTemperature(header: String? = nil) async throws -> Double {
        try await readDouble(pid: 0x05, header: header, decoder: Self.decodeCoolant)
    }

    func readManifoldAbsolutePressure(header: String? = nil) async throws -> Double {
        try await readDouble(pid: 0x0B, header: header, decoder: Self.decodePressureKPa)
    }

    func readBarometricPressure(header: String? = nil) async throws -> Double {
        try await readDouble(pid: 0x33, header: header, decoder: Self.decodePressureKPa)
    }

    /// Converts SAE manifold absolute pressure and barometric pressure to
    /// driver-facing turbo boost. A negative difference is vacuum rather than
    /// turbo pressure, so the gauge bottoms out at zero.
    static func turboBoostBar(
        manifoldAbsoluteKPa: Double,
        barometricKPa: Double
    ) -> Double? {
        guard manifoldAbsoluteKPa.isFinite,
              barometricKPa.isFinite,
              manifoldAbsoluteKPa >= 0,
              barometricKPa > 0
        else { return nil }
        return max(0, manifoldAbsoluteKPa - barometricKPa) / 100.0
    }

    /// Maps the physical header used by enhanced FCA PIDs back to the standard
    /// functional OBD request header. Sending this explicitly is essential:
    /// `header: nil` would leave the ELM327 on the previous physical ATSH.
    static func functionalRequestHeader(forPhysicalHeader header: String) -> String? {
        let normalized = header.uppercased()
        if normalized.count == 3 { return "7DF" }
        if normalized.count == 8, normalized.hasPrefix("18DA") { return "18DB33F1" }
        return nil
    }

    private func readDouble(pid: UInt8,
                            header: String?,
                            decoder: ([UInt8]) throws -> Double) async throws -> Double {
        let cmd = String(format: "01%02X", pid)
        let response = try await connection.send(cmd, header: header)
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

    static func decodePressureKPa(_ b: [UInt8]) throws -> Double {
        guard let pressureKPa = b.first else {
            throw OBDError.protocolError("pressure needs 1 byte")
        }
        return Double(pressureKPa)
    }
}
