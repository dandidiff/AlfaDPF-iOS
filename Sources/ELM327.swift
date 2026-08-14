import Foundation

/// Thin ELM327 protocol wrapper around `OBDConnection`. Responsibilities:
/// - run the AT init sequence once per socket
/// - format Mode 22 PID requests
/// - parse hex response frames
///
/// Intentionally dumb. No caching, no PID-specific decoding — that lives in
/// `DPFMonitor` where scaling factors are owned alongside the regen logic.
struct ELM327 {
    let connection: any OBDTransport

    /// Boots the adapter into a known state and negotiates the diagnostic
    /// protocol. Called once after (re)connect.
    ///
    /// - `cachedProtocol`: protocol number previously negotiated for this exact
    ///   adapter endpoint (from `ATDPN`). When present, `ATSP<cached>` is tried
    ///   instead of the automatic search (`ATSP0`), which dominates warm
    ///   reconnect time on slow adapters. The fast path is kept only when the
    ///   DPF probe proves an ECU answered (`62` positive or `7F22` negative);
    ///   a bare `OK` from `ATSPx` is never treated as proof (clone firmware
    ///   can accept it without applying it). Otherwise the sequence falls back
    ///   once to `ATSP0`.
    /// - `probeHeader`: physical ECU address for the mandatory Mode 22 probe.
    ///   Defaults to `18DA10F1`; pass a remembered validated route so the
    ///   probe answers on vehicles where the DPF PID lives elsewhere.
    /// - Returns the normalized protocol number reported by `ATDPN` (nil when
    ///   the optional query fails), so the caller can persist it for the next
    ///   session.
    func initializeSession(cachedProtocol: Int? = nil,
                           probeHeader: String? = nil) async throws -> Int? {
        let initStartedAt = Date()
        // ATZ reboots the chip and prints a version banner. Some old clones
        // reboot successfully but omit or delay the final prompt; in that case
        // prove the command channel is alive instead of rejecting the adapter.
        do {
            let reset = try await connection.send("ATZ", timeout: 5.0)
            if !Self.isAcceptedATResponse(reset) {
                OBDLog.log("init: ATZ rejected (\(reset)); probing with ATI")
                try await probeIdentityAfterReset()
            }
        } catch {
            OBDLog.log("init: ATZ did not complete (\(error)); probing with ATI")
            try await probeIdentityAfterReset()
        }

        // Protocol selection is intentionally not in this list: it is the only
        // step with a cached fast path and a fallback, so it runs below.
        let boot = [
            "ATE0",        // echo off
            "ATL0",        // linefeeds off
            "ATS0",        // spaces off in responses
            "ATH1",        // headers on (needed to know which ECU replied)
            "ATAT1"        // adaptive timing
        ]
        for cmd in boot {
            do {
                let response = try await connection.send(cmd)
                if !Self.isAcceptedATResponse(response) {
                    OBDLog.log("init: optional \(cmd) rejected: \(response)")
                }
            } catch {
                // Formatting and adaptive timing are optimizations. The parser
                // already tolerates echo, spaces and linefeeds, so a clone that
                // lacks one of these commands can still be usable.
                OBDLog.log("init: optional \(cmd) unavailable: \(error)")
            }
        }

        // First real request triggers the protocol search ("SEARCHING...").
        // Keep the live session DPF-only: generic Mode 01 traffic can disturb
        // the physical Mode 22 header context on real FCA vehicles.
        let header = probeHeader ?? "18DA10F1"
        let probeCommand = "22380B"
        var path: String
        var probe: String?

        if let cached = cachedProtocol, (1...9).contains(cached) {
            // Fast path: force the remembered protocol instead of re-running
            // the automatic search. Only an ECU-proven probe keeps it.
            let spResponse = try? await connection.send("ATSP\(cached)", timeout: 2.0)
            if let spResponse,
               Self.isAcceptedATResponse(spResponse),
               let fastProbe = try? await connection.send(
                   probeCommand, header: header, timeout: 12.0
               ),
               Self.isECUProvenDiagnosticProbe(fastProbe) {
                probe = fastProbe
                path = "cached(\(cached))"
            } else {
                // Stale cache (adapter moved to another car, clone that did
                // not apply ATSPx, or NO DATA ambiguity): fall back once to
                // the automatic search.
                if spResponse != nil {
                    OBDLog.log("init: cached ATSP\(cached) not confirmed; falling back to ATSP0")
                } else {
                    OBDLog.log("init: cached ATSP\(cached) unavailable; falling back to ATSP0")
                }
                await logOptionalSP0()
                probe = try? await connection.send(
                    probeCommand, header: header, timeout: 12.0
                )
                path = "fallback"
            }
        } else {
            // Automatic protocol detection. Forcing a protocol (e.g. ATSP6)
            // returns NO DATA on every PID when it doesn't exactly match the
            // car; auto lets the ELM negotiate the right CAN variant, like Car
            // Scanner. NO DATA is acceptable here because it still proves that
            // ELM parsed and executed the diagnostic request; '?', adapter
            // errors and silence are not.
            await logOptionalSP0()
            probe = try? await connection.send(
                probeCommand, header: header, timeout: 12.0
            )
            path = "auto"
        }

        guard let probe else {
            throw OBDError.protocolError("adapter did not answer DPF protocol probe")
        }
        guard Self.isAcceptedDiagnosticProbe(probe) else {
            throw OBDError.protocolError("adapter rejected DPF protocol probe: \(probe)")
        }
        OBDLog.log(String(
            format: "init: protocol path %@ after %.2f s",
            path,
            Date().timeIntervalSince(initStartedAt)
        ))

        // Log the negotiated protocol so a NO DATA problem is diagnosable from
        // the in-app console (e.g. "A6" = auto, CAN 11-bit 500k), and hand the
        // normalized number back for the per-adapter cache.
        if let proto = try? await connection.send("ATDPN") {
            let text = proto.trimmingCharacters(in: .whitespacesAndNewlines)
            OBDLog.log("protocol: \(text)")
            return Self.parseProtocol(from: text)
        }
        return nil
    }

    private func probeIdentityAfterReset() async throws {
        try await Task.sleep(for: .milliseconds(300))
        let wake = try await connection.send("ATI", timeout: 3.0)
        if !Self.isAcceptedATResponse(wake) {
            // ATI is not universal on old clones. Do not fail yet: the DPF-only
            // diagnostic probe below remains the mandatory proof of operation.
            OBDLog.log("init: optional ATI rejected after reset: \(wake)")
        }
    }

    /// Sends `ATSP0` (automatic search) tolerating rejection, as the boot
    /// sequence always did: the diagnostic probe that follows decides.
    private func logOptionalSP0() async {
        if let sp0 = try? await connection.send("ATSP0", timeout: 2.0),
           !Self.isAcceptedATResponse(sp0) {
            OBDLog.log("init: ATSP0 rejected: \(sp0)")
        }
    }

    static func isAcceptedATResponse(_ response: String) -> Bool {
        let lines = response
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        guard !lines.isEmpty else { return false }
        return !lines.contains(where: {
            $0 == "?"
                || $0 == "NO DATA"
                || $0 == "STOPPED"
                || $0.contains("ERROR")
                || $0.contains("UNABLE TO CONNECT")
        })
    }

    static func isAcceptedDiagnosticProbe(_ response: String) -> Bool {
        let lines = response
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("SEARCHING") }
        guard !lines.isEmpty else { return false }
        guard !lines.contains(where: {
            $0 == "?"
                || $0 == "STOPPED"
                || $0.contains("ERROR")
                || $0.contains("UNABLE TO CONNECT")
        }) else { return false }

        if lines.contains("NO DATA") { return true }
        return isECUProvenDiagnosticProbe(response)
    }

    /// Stricter probe acceptance for the cached-protocol fast path. `NO DATA`
    /// alone does NOT prove the forced protocol is right — it can also mean
    /// the forced protocol does not match the vehicle. Only an ECU reply
    /// (positive `62…` or negative `7F 22 …`) confirms the protocol works, so
    /// the cached fast path is kept exclusively on ECU-proven probes.
    static func isECUProvenDiagnosticProbe(_ response: String) -> Bool {
        let lines = response
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("SEARCHING") }
        guard !lines.isEmpty else { return false }
        guard !lines.contains(where: {
            $0 == "?"
                || $0 == "NO DATA"
                || $0 == "STOPPED"
                || $0.contains("ERROR")
                || $0.contains("UNABLE TO CONNECT")
        }) else { return false }
        return lines.contains(where: { line in
            let compact = line.filter { !$0.isWhitespace }
            guard compact.allSatisfy(\.isHexDigit) else { return false }
            return compact.contains("62380B") || compact.contains("7F22")
        })
    }

    /// Normalizes an `ATDPN` reply into the numeric ELM327 protocol (1–9).
    /// Accepts the common forms (`7`, `A7`, `A6`, with spaces/echo) and
    /// rejects descriptions and the automatic-search marker (`0`/`A0`), which
    /// must not be cached.
    static func parseProtocol(from response: String) -> Int? {
        let lines = response
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        for line in lines {
            var compact = line.filter { !$0.isWhitespace }
            guard !compact.isEmpty, !compact.hasPrefix("AT") else { continue }
            if compact.hasPrefix("A") { compact.removeFirst() }
            let numberPrefix = String(compact.prefix(while: \.isNumber))
            guard let number = Int(numberPrefix), (1...9).contains(number) else {
                continue
            }
            return number
        }
        return nil
    }

    /// Requests a Mode 22 PID and returns the raw data bytes of the reply
    /// (positive response only — mode byte + PID echo stripped). `header`
    /// physically addresses the ECU that owns the PID (see `OBDTransport`).
    func readMode22(pid: UInt16, header: String? = nil) async throws -> [UInt8] {
        let cmd = String(format: "22%04X", pid)
        let response = try await connection.send(cmd, header: header)
        return try Self.parseMode22Response(response, expectedPID: pid)
    }

    /// Reads the vehicle supply voltage measured at the adapter. `ATRV` is an
    /// ELM command rather than an ECU PID, so it does not change the selected
    /// diagnostic header.
    func readBatteryVoltage() async throws -> Double {
        let response = try await connection.send("ATRV")
        return try Self.parseBatteryVoltage(response)
    }

    static func parseBatteryVoltage(_ text: String) throws -> Double {
        let candidates = text
            .split(whereSeparator: { $0.isNewline || $0 == ">" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        for candidate in candidates {
            let compact = candidate
                .filter { !$0.isWhitespace }
                .uppercased()
            guard compact.hasSuffix("V") else { continue }
            guard let voltage = Double(compact.dropLast()), voltage.isFinite,
                  (0...100).contains(voltage)
            else { continue }
            return voltage
        }

        throw OBDError.protocolError("invalid ATRV response: \(text)")
    }

    static func parseMode22Response(_ text: String, expectedPID: UInt16) throws -> [UInt8] {
        // 62 = 0x22 + 0x40 (positive reply), followed by the echoed PID.
        try extractPayload(after: String(format: "62%04X", expectedPID), in: text)
    }

    /// Finds the positive-response marker (`62<pid>` / `41<pid>`) in an ELM327
    /// reply and returns the data bytes after it.
    ///
    /// Scans the hex text rather than decoding fixed offsets because the frame
    /// shape varies wildly between adapter configs: an 11-bit CAN header with
    /// ATH1 is *3 hex chars* (`7E8`), 29-bit is 8, ATH0 has none, and clones
    /// disagree about spaces. Non-hex lines (`SEARCHING...`, `NO DATA`,
    /// command echo without a marker, `CAN ERROR`) are skipped.
    static func extractPayload(after marker: String, in text: String) throws -> [UInt8] {
        // `isNewline`, not `== "\r" || == "\n"`: a CRLF pair is a single
        // Character in Swift and would slip through the equality checks.
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for line in lines {
            let compact = line.filter { !$0.isWhitespace }.uppercased()
            guard compact.allSatisfy(\.isHexDigit) else { continue }

            // A marker match must leave a whole number of payload bytes;
            // otherwise it straddled a byte boundary — keep scanning.
            var searchFrom = compact.startIndex
            while let range = compact.range(of: marker, range: searchFrom..<compact.endIndex) {
                let payloadHex = compact[range.upperBound...]
                if payloadHex.count.isMultiple(of: 2) {
                    return try parseHexBytes(from: String(payloadHex))
                }
                searchFrom = compact.index(after: range.lowerBound)
            }
        }
        throw OBDError.protocolError("no \(marker) response in: \(text)")
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
