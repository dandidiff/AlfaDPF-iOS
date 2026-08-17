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
    /// Protocol search is triggered with a functional (non-addressed) Mode 22
    /// request so the live session stays DPF-only: generic Mode 01 traffic can
    /// disturb the physical Mode 22 header context on real FCA vehicles. Some
    /// ELM327 clones cannot start negotiation from a *physically addressed*
    /// `22380B` request, so the trigger is sent functionally and falls back to
    /// the generic `0100` trigger only when Mode 22 cannot negotiate at all.
    func initializeSession() async throws {
        let initStartedAt = Date()
        var channelAcknowledged = false

        // ATZ reboots the chip and prints a version banner. Some old clones
        // reboot successfully but omit or delay the final prompt; in that case
        // prove the command channel is alive instead of rejecting the adapter.
        do {
            let reset = try await connection.send("ATZ", timeout: 5.0)
            channelAcknowledged = Self.isAcceptedATResponse(reset)
            if !channelAcknowledged {
                OBDLog.log("init: ATZ rejected (\(reset)); probing with ATI")
                channelAcknowledged = (try? await probeIdentityAfterReset()) == true
            }
        } catch {
            OBDLog.log("init: ATZ did not complete (\(error)); probing with ATI")
            channelAcknowledged = (try? await probeIdentityAfterReset()) == true
        }

        let boot = [
            "ATE0",        // echo off
            "ATL0",        // linefeeds off
            "ATS0",        // spaces off in responses
            "ATH1",        // headers on (needed to know which ECU replied)
            "ATSP0",       // automatic protocol selection
            "ATAT1"        // adaptive timing
        ]
        for cmd in boot {
            do {
                let response = try await connection.send(cmd)
                channelAcknowledged = channelAcknowledged || Self.isAcceptedATResponse(response)
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

        // Trigger protocol negotiation. This request is only an autodetect
        // trigger: a timeout, NO DATA or an adapter-specific error must not
        // invalidate the session, because the DPF PIDs are optional and are
        // probed independently by DPFMonitor afterwards.
        await logOptionalProtocolSearch()

        guard channelAcknowledged else {
            throw OBDError.protocolError("adapter did not acknowledge the ELM327 initialization")
        }

        OBDLog.log(String(
            format: "init: protocol path %@ after %.2f s",
            "ATSP0/Mode22",
            Date().timeIntervalSince(initStartedAt)
        ))

        // Log the negotiated protocol so a NO DATA problem is diagnosable from
        // the in-app console (e.g. "A6" = auto, CAN 11-bit 500k).
        if let proto = try? await connection.send("ATDPN") {
            OBDLog.log("protocol: \(proto.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private func probeIdentityAfterReset() async throws -> Bool {
        try await Task.sleep(for: .milliseconds(300))
        let wake = try await connection.send("ATI", timeout: 3.0)
        if !Self.isAcceptedATResponse(wake) {
            // ATI is not universal on old clones. Do not fail yet: another AT
            // command in the boot sequence may still prove the channel.
            OBDLog.log("init: optional ATI rejected after reset: \(wake)")
        }
        return Self.isAcceptedATResponse(wake)
    }

    /// Triggers the ELM327's automatic protocol search (the "SEARCHING..."
    /// autodetect) with a functional Mode 22 request so the live session stays
    /// DPF-only: generic Mode 01 traffic can disturb the physical Mode 22
    /// header context on real FCA vehicles. `NO DATA` is an acceptable outcome
    /// — it proves the ELM settled on a protocol even though no ECU answered
    /// the broadcast.
    ///
    /// Only a failure to *negotiate* (`UNABLE TO CONNECT`, `?`, `ERROR`,
    /// `STOPPED`, or a timeout) falls back to the generic `0100` trigger. That
    /// reproduces the previous behavior for clones that only complete autodetect
    /// from Mode 01, so those adapters cannot regress. Failure of either trigger
    /// is diagnostic only and never invalidates the session.
    private func logOptionalProtocolSearch() async {
        if await triggerProtocolSearch("22380B") {
            return
        }
        OBDLog.log("init: Mode 22 trigger did not negotiate; falling back to Mode 01")
        _ = await triggerProtocolSearch("0100")
    }

    /// Runs one protocol-search trigger and returns whether the ELM negotiated
    /// a protocol (even with `NO DATA`). Returns false only when the request
    /// could not negotiate at all — the signal to try the Mode 01 fallback.
    private func triggerProtocolSearch(_ command: String) async -> Bool {
        do {
            let response = try await connection.send(command, timeout: 12.0)
            if Self.failedToNegotiate(response) {
                OBDLog.log("init: optional \(command) did not negotiate: \(response)")
                return false
            }
            if !Self.isAcceptedATResponse(response) {
                // NO DATA (or another non-ack) still means the ELM executed the
                // request; acceptable for a protocol trigger.
                OBDLog.log("init: optional \(command) protocol search returned: \(response)")
            }
            return true
        } catch {
            OBDLog.log("init: optional \(command) protocol search unavailable: \(error)")
            return false
        }
    }

    /// True when the ELM327 could not even complete protocol negotiation for
    /// the request — the signal for the Mode 01 fallback. `NO DATA` and a bare
    /// `SEARCHING...` preamble are NOT negotiation failures: they mean the ELM
    /// settled on a protocol but no ECU answered.
    static func failedToNegotiate(_ response: String) -> Bool {
        let lines = response
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        return lines.contains(where: {
            $0 == "?"
                || $0 == "STOPPED"
                || $0.contains("ERROR")
                || $0.contains("UNABLE TO CONNECT")
        })
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
