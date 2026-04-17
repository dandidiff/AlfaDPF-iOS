import Foundation

/// Standard OBD-II Mode 01 live-data reader. These PIDs and decoders are
/// defined by SAE J1979 and work on every OBD-II vehicle, so they give us a
/// real signal on day one — even before the Alfa-specific Mode 22 PIDs for
/// DPF monitoring are mapped.
struct Mode01Reader {
    let connection: OBDConnection

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
    /// `41 <pid>` header. Tolerates CAN headers when `ATH1` is active.
    static func parseMode01(_ text: String, expectedPID: UInt8) throws -> [UInt8] {
        let lines = text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let line = lines.first(where: { !$0.hasPrefix("NO DATA") && !$0.hasPrefix("?") }) else {
            throw OBDError.protocolError("no data: \(text)")
        }
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count.isMultiple(of: 2) else {
            throw OBDError.protocolError("odd-length hex: \(line)")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(compact.count / 2)
        var i = compact.startIndex
        while i < compact.endIndex {
            let next = compact.index(i, offsetBy: 2)
            guard let b = UInt8(compact[i..<next], radix: 16) else {
                throw OBDError.protocolError("invalid hex: \(line)")
            }
            bytes.append(b)
            i = next
        }
        guard bytes.count >= 2 else {
            throw OBDError.protocolError("mode01 frame too short: \(line)")
        }

        // Find the `41 <pid>` marker. With ATH1 we have a CAN header + length
        // byte in front; without it, `41` is near the start. Scanning is
        // simpler than hard-coding offsets and handles both modes.
        for idx in 0..<(bytes.count - 1) where bytes[idx] == 0x41 && bytes[idx + 1] == expectedPID {
            return Array(bytes.dropFirst(idx + 2))
        }
        throw OBDError.protocolError("no 41 \(String(format: "%02X", expectedPID)) marker: \(line)")
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
