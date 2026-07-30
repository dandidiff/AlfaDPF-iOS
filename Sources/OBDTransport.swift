import Foundation

enum OBDError: Error {
    case notReady
    case protocolError(String)
    case timeout
}

/// A byte transport that speaks the ELM327 line protocol: ASCII commands
/// terminated by `\r`, responses terminated by the `>` prompt character.
/// The app uses `BLEConnection` (Bluetooth Low Energy GATT). The legacy TCP
/// implementation remains outside the app target only for transport tests.
protocol OBDTransport: Actor {
    func start()
    func stop() async
    /// Suspends until the transport is usable. Resumes early if `stop()` is
    /// called; callers must check for cancellation afterwards.
    func isReady() async
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

    /// Runs one command/response exchange. `write` delivers the raw bytes to
    /// the wire; the engine owns everything before and after. When `header`
    /// is set, `ATSH<header>` is sent first within the same critical section.
    func perform(_ command: String,
                 header: String? = nil,
                 timeout: TimeInterval,
                 write: (Data) async throws -> Void) async throws -> String {
        await acquireSendSlot()
        defer { releaseSendSlot() }

        if let header, header != currentHeader {
            do {
                _ = try await writeAndRead("ATSH" + header, timeout: timeout, write: write)
                currentHeader = header
            } catch {
                OBDLog.log("✗ ATSH\(header): \(error)")
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
    }

    // MARK: - Private

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
