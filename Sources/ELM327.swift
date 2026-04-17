import Foundation

/// Thin ELM327 protocol wrapper around `OBDConnection`. Responsibilities:
/// - run the AT init sequence once per socket
/// - format Mode 22 PID requests
/// - parse hex response frames
///
/// Intentionally dumb. No caching, no PID-specific decoding — that lives in
/// `DPFMonitor` where scaling factors are owned alongside the regen logic.
struct ELM327 {
    let connection: OBDConnection

    /// Boots the adapter into a known state. Called once after (re)connect.
    func initializeSession() async throws {
        // Order matters: reset first, then echo off so later parsing is clean.
        let boot = [
            "ATZ",         // reset
            "ATE0",        // echo off
            "ATL0",        // linefeeds off
            "ATS0",        // spaces off in responses
            "ATH1",        // headers on (needed to know which ECU replied)
            "ATSP6",       // CAN 11-bit 500k; FCA cars mostly use this
            "ATAT1"        // adaptive timing
        ]
        for cmd in boot {
            _ = try await connection.send(cmd)
        }
    }

    /// Requests a Mode 22 PID and returns the raw data bytes of the reply
    /// (positive response only — mode byte + PID echo stripped).
    func readMode22(pid: UInt16) async throws -> [UInt8] {
        let cmd = String(format: "22%04X", pid)
        let response = try await connection.send(cmd)
        return try Self.parseMode22Response(response, expectedPID: pid)
    }

    static func parseMode22Response(_ text: String, expectedPID: UInt16) throws -> [UInt8] {
        // Responses look like (with ATH1):
        //   7E8 06 62 1C 30 00 00 12 34
        // First byte after header is length; 62 = 0x22 + 0x40 (positive reply).
        let lines = text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let line = lines.first(where: { !$0.hasPrefix("NO DATA") && !$0.hasPrefix("?") }) else {
            throw OBDError.protocolError("no data: \(text)")
        }
        let bytes = try parseHexBytes(from: line)
        // Drop CAN header (first 3 bytes for 11-bit) + length byte.
        guard bytes.count >= 6, bytes[3] == 0x62 else {
            throw OBDError.protocolError("unexpected frame: \(line)")
        }
        let pidHi = bytes[4], pidLo = bytes[5]
        let got = UInt16(pidHi) << 8 | UInt16(pidLo)
        guard got == expectedPID else {
            throw OBDError.protocolError("PID mismatch: want \(expectedPID), got \(got)")
        }
        return Array(bytes.dropFirst(6))
    }

    private static func parseHexBytes(from line: String) throws -> [UInt8] {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count.isMultiple(of: 2) else {
            throw OBDError.protocolError("odd-length hex frame: \(line)")
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(compact.count / 2)

        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else {
                throw OBDError.protocolError("invalid hex frame: \(line)")
            }
            bytes.append(byte)
            index = next
        }

        return bytes
    }
}
