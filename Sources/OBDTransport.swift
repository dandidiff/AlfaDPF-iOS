import Foundation

enum OBDError: Error, Equatable, Sendable, LocalizedError {
    case notReady
    case protocolError(String)
    case timeout
    case connectionTimeout
    case bluetoothUnauthorized
    case bluetoothPoweredOff
    case bluetoothUnavailable
    case connectionFailed
    case incompatibleAdapter
    case invalidWiFiEndpoint
    case wifiConnectionTimeout

    var errorDescription: String? {
        switch self {
        case .notReady:
            return String(localized: "L’adattatore OBD non è pronto.")
        case .protocolError:
            return String(localized: "Errore di comunicazione con l’adattatore OBD.")
        case .timeout:
            return String(localized: "L’adattatore OBD non ha risposto in tempo.")
        case .connectionTimeout:
            return String(localized: "Nessuna connessione con l’adattatore OBD entro 30 secondi. Verifica che sia alimentato e vicino.")
        case .bluetoothUnauthorized:
            return String(localized: "Accesso Bluetooth negato. Abilitalo nelle Impostazioni di iOS.")
        case .bluetoothPoweredOff:
            return String(localized: "Bluetooth è disattivato. Attivalo e riprova.")
        case .bluetoothUnavailable:
            return String(localized: "Bluetooth non è disponibile su questo dispositivo.")
        case .connectionFailed:
            return String(localized: "Errore durante la connessione Bluetooth all’adattatore OBD.")
        case .incompatibleAdapter:
            return String(localized: "L’adattatore Bluetooth non espone una connessione ELM327 compatibile.")
        case .invalidWiFiEndpoint:
            return String(localized: "Impostazioni Wi-Fi non valide. Controlla indirizzo e porta.")
        case .wifiConnectionTimeout:
            return String(localized: "Impossibile raggiungere l’adattatore OBD Wi-Fi entro 30 secondi. Verifica la rete, l’indirizzo e la porta.")
        }
    }
}

/// A byte transport that speaks the ELM327 line protocol: ASCII commands
/// terminated by `\r`, responses terminated by the `>` prompt character.
/// The app uses either `BLEConnection` (Bluetooth Low Energy GATT) or
/// `OBDConnection` (a local Wi-Fi TCP socket).
protocol OBDTransport: Actor {
    func start()
    func stop() async
    /// Suspends until the transport is usable. Throws a user-readable error
    /// when setup fails or times out, and `CancellationError` when `stop()`
    /// tears down a pending connection.
    func isReady() async throws
    /// Sends `command` (without trailing `\r`), awaits the `>` prompt, returns
    /// the raw response body with the prompt and echo stripped.
    ///
    /// When `header` is non-nil, an `ATSH<header>` is sent first, in the same
    /// critical section, so the request is physically addressed to a specific
    /// ECU (needed for manufacturer Mode 22 PIDs) without another command
    /// interleaving between the header and the request.
    func send(_ command: String, header: String?, timeout: TimeInterval) async throws -> String
}

extension OBDTransport {
    func send(_ command: String, timeout: TimeInterval = 2.0) async throws -> String {
        try await send(command, header: nil, timeout: timeout)
    }
    func send(_ command: String, header: String?) async throws -> String {
        try await send(command, header: header, timeout: 2.0)
    }
}

/// Transport-agnostic half of the ELM327 line protocol: serializes commands,
/// frames `CMD\r` → bytes-until-`>` exchanges, applies read timeouts, and
/// drops stale receive data. Transports own the socket/GATT plumbing and
/// delegate the request/response discipline here so the tricky concurrency
/// lives (and is tested) in exactly one place.
actor ELMLineEngine {
    private var rxBuffer = Data()
    private var pendingRead: CheckedContinuation<String, Error>?
    /// Bumped on every armed read so a stale timeout task can recognize it
    /// lost the race against a completed response and must not fire.
    private var readGeneration: UInt64 = 0
    private var readTimeoutTask: Task<Void, Never>?
    private var sendQueue: [CheckedContinuation<Void, Never>] = []
    private var isSending = false
    /// Last `ATSH` header applied to the adapter, so we only re-send it when
    /// it changes. Cleared by `reset()` (the adapter forgets it on reconnect).
    private var currentHeader: String?
    /// First byte of a 29-bit CAN ID. Genuine ELM327 v1.5 firmware expects
    /// this through ATCP, with ATSH carrying the remaining three bytes.
    private var currentCANPriority: String?

    /// Runs one command/response exchange. `write` delivers the raw bytes to
    /// the wire; the engine owns everything before and after. When `header`
    /// is set, `ATSH<header>` is sent first within the same critical section.
    func perform(_ command: String,
                 header: String? = nil,
                 timeout: TimeInterval,
                 write: (Data) async throws -> Void) async throws -> String {
        await acquireSendSlot()
        defer { releaseSendSlot() }

        if let header, header.uppercased() != currentHeader {
            do {
                try await applyHeader(header, timeout: timeout, write: write)
            } catch {
                OBDLog.log("✗ header \(header): \(error)")
                throw error
            }
        }

        do {
            let response = try await writeAndRead(command, timeout: timeout, write: write)
            let shown = response.isEmpty ? "(empty)" : response.replacingOccurrences(of: "\n", with: " ⏎ ")
            OBDLog.log("← \(shown)")
            return response
        } catch {
            OBDLog.log("✗ \(command): \(error)")
            throw error
        }
    }

    private func writeAndRead(_ command: String,
                              timeout: TimeInterval,
                              write: (Data) async throws -> Void) async throws -> String {
        // Drop anything still buffered from a previous command (e.g. a reply
        // that arrived after its read timed out) so it can't be served as the
        // answer to this one.
        rxBuffer.removeAll(keepingCapacity: true)
        OBDLog.log("→ \(command)")
        try await write((command + "\r").data(using: .ascii)!)
        return try await readUntilPrompt(timeout: timeout, echo: command)
    }

    /// Feeds bytes received from the wire into the pending read, if any.
    func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        rxBuffer.append(data)
        tryCompletePendingRead()
    }

    /// Fails the in-flight read (connection lost, transport stopping, …).
    func failPendingRead(with error: Error) {
        resumePendingRead(with: error)
    }

    /// Clears buffered bytes and cancels the in-flight read. Call when the
    /// underlying connection is torn down or replaced.
    func reset() {
        resumePendingRead(with: CancellationError())
        rxBuffer.removeAll(keepingCapacity: false)
        currentHeader = nil
        currentCANPriority = nil
    }

    // MARK: - Private

    private func applyHeader(
        _ rawHeader: String,
        timeout: TimeInterval,
        write: (Data) async throws -> Void
    ) async throws {
        let header = rawHeader.filter { !$0.isWhitespace }.uppercased()
        guard header.allSatisfy(\.isHexDigit) else {
            throw OBDError.protocolError("invalid request header: \(rawHeader)")
        }

        switch header.count {
        case 8:
            let priority = String(header.prefix(2))
            let threeByteHeader = String(header.suffix(6))
            do {
                if priority != currentCANPriority {
                    try await performATControl(
                        "ATCP" + priority,
                        timeout: timeout,
                        write: write
                    )
                    currentCANPriority = priority
                }
                try await performATControl(
                    "ATSH" + threeByteHeader,
                    timeout: timeout,
                    write: write
                )
            } catch let error as OBDError {
                // Some newer ELM-compatible firmware accepts a complete
                // four-byte CAN ID in ATSH but omits the legacy ATCP command.
                guard case .protocolError = error else { throw error }
                OBDLog.log("header: legacy ATCP/ATSH rejected; trying four-byte ATSH")
                try await performATControl(
                    "ATSH" + header,
                    timeout: timeout,
                    write: write
                )
                currentCANPriority = priority
            }
        case 3, 6:
            try await performATControl("ATSH" + header, timeout: timeout, write: write)
        default:
            throw OBDError.protocolError("unsupported request header: \(rawHeader)")
        }

        currentHeader = header
    }

    private func performATControl(
        _ command: String,
        timeout: TimeInterval,
        write: (Data) async throws -> Void
    ) async throws {
        let response = try await writeAndRead(command, timeout: timeout, write: write)
        let shown = response.isEmpty
            ? "(empty)"
            : response.replacingOccurrences(of: "\n", with: " ⏎ ")
        OBDLog.log("← \(shown)")
        guard Self.isSuccessfulATResponse(response) else {
            throw OBDError.protocolError("\(command) rejected: \(response)")
        }
    }

    static func isSuccessfulATResponse(_ response: String) -> Bool {
        let lines = response
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        guard lines.contains("OK") else { return false }
        return !lines.contains(where: {
            $0 == "?"
                || $0 == "NO DATA"
                || $0 == "STOPPED"
                || $0.contains("ERROR")
                || $0.contains("UNABLE TO CONNECT")
        })
    }

    private func tryCompletePendingRead() {
        guard let cont = pendingRead,
              let promptIdx = rxBuffer.firstIndex(of: 0x3E) // '>'
        else { return }
        let payload = rxBuffer[..<promptIdx]
        rxBuffer.removeSubrange(...promptIdx)
        pendingRead = nil
        readTimeoutTask?.cancel()
        readTimeoutTask = nil
        let text = String(data: payload, encoding: .ascii) ?? ""
        cont.resume(returning: text)
    }

    private func readUntilPrompt(timeout: TimeInterval, echo: String) async throws -> String {
        let raw: String = try await withCheckedThrowingContinuation { cont in
            precondition(pendingRead == nil, "ELMLineEngine: concurrent reads not supported")
            pendingRead = cont
            armReadTimeout(after: timeout)
            tryCompletePendingRead()
        }
        // Strip command echo (ELM327 echoes unless ATE0 was sent) and CR/LF.
        // `isNewline` also matches a CRLF pair, which is a single Character.
        var lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespaces) == echo {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    private func armReadTimeout(after timeout: TimeInterval) {
        readTimeoutTask?.cancel()
        readGeneration &+= 1
        let generation = readGeneration

        let timeoutNs = UInt64(max(timeout, 0) * 1_000_000_000)
        readTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNs)
            // A cancelled sleep returns immediately — without these guards a
            // timeout task raced by its own response could kill the *next*
            // command's read.
            guard !Task.isCancelled else { return }
            await self?.readTimedOut(generation: generation)
        }
    }

    private func readTimedOut(generation: UInt64) {
        guard generation == readGeneration, pendingRead != nil else { return }
        resumePendingRead(with: OBDError.timeout)
    }

    private func resumePendingRead(with error: Error) {
        guard let pendingRead else { return }
        self.pendingRead = nil
        readTimeoutTask?.cancel()
        readTimeoutTask = nil
        pendingRead.resume(throwing: error)
    }

    private func acquireSendSlot() async {
        if !isSending {
            isSending = true
            return
        }

        await withCheckedContinuation { cont in
            sendQueue.append(cont)
        }
    }

    private func releaseSendSlot() {
        if let next = sendQueue.first {
            sendQueue.removeFirst()
            next.resume()
        } else {
            isSending = false
        }
    }
}
