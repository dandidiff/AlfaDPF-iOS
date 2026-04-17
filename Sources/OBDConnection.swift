import Foundation
import Network

/// Wi-Fi TCP client for an ELM327-style OBD dongle.
///
/// Typical dongle exposes a TCP server at 192.168.0.10:35000 once the phone
/// joins its Wi-Fi. `connect()` retries forever with a fixed backoff; callers
/// await `isReady()` before sending commands. Line protocol: ASCII commands
/// terminated by `\r`, responses terminated by the `>` prompt character.
actor OBDConnection {
    struct Endpoint {
        var host: String
        var port: UInt16
        static let defaultELM = Endpoint(host: "192.168.0.10", port: 35000)
    }

    enum State { case idle, connecting, ready, failed(Error) }

    private let endpoint: Endpoint
    private var connection: NWConnection?
    private(set) var state: State = .idle
    private var reconnectTask: Task<Void, Never>?
    private var readTimeoutTask: Task<Void, Never>?
    private var readyContinuations: [CheckedContinuation<Void, Never>] = []
    private var sendQueue: [CheckedContinuation<Void, Never>] = []
    private var isSending = false
    private var rxBuffer = Data()
    private var pendingRead: CheckedContinuation<String, Error>?

    init(endpoint: Endpoint = .defaultELM) {
        self.endpoint = endpoint
    }

    /// Starts a reconnect loop. Returns immediately; await `isReady()` to
    /// block until the socket is usable.
    func start() {
        reconnectTask?.cancel()
        reconnectTask = Task { await reconnectLoop() }
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        readTimeoutTask?.cancel()
        readTimeoutTask = nil
        connection?.cancel()
        connection = nil
        resumePendingRead(with: CancellationError())
        resumeReadyContinuations()
        rxBuffer.removeAll(keepingCapacity: false)
        state = .idle
    }

    func isReady() async {
        switch state {
        case .ready: return
        default:
            await withCheckedContinuation { cont in
                readyContinuations.append(cont)
            }
        }
    }

    /// Sends `command` (without trailing `\r`), awaits the `>` prompt, returns
    /// the raw response body with the prompt and echo stripped.
    func send(_ command: String, timeout: TimeInterval = 2.0) async throws -> String {
        await acquireSendSlot()
        defer { releaseSendSlot() }

        guard case .ready = state, let connection else {
            throw OBDError.notReady
        }
        let payload = (command + "\r").data(using: .ascii)!
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
        return try await readUntilPrompt(timeout: timeout, echo: command)
    }

    // MARK: - Private

    private func reconnectLoop() async {
        while !Task.isCancelled {
            state = .connecting
            let conn = NWConnection(
                host: .init(endpoint.host),
                port: .init(rawValue: endpoint.port)!,
                using: .tcp
            )
            connection = conn
            conn.stateUpdateHandler = { [weak self] newState in
                Task { await self?.handleNWState(newState) }
            }
            conn.start(queue: .global(qos: .userInitiated))
            receiveLoop(on: conn)

            // Wait until the connection either becomes ready or fails.
            await waitForTerminalState()
            guard !Task.isCancelled else { break }
            if case .ready = state { return }

            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s backoff
        }
    }

    private func waitForTerminalState() async {
        // Polling is fine here — state transitions are rare.
        while !Task.isCancelled, case .connecting = state {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func handleNWState(_ nw: NWConnection.State) async {
        switch nw {
        case .ready:
            // ELM327 wants a reset + a couple of AT lines before first use.
            // That's handled by ELM327Session on top of this, not here.
            state = .ready
            readyContinuations.forEach { $0.resume() }
            readyContinuations.removeAll()
        case .failed(let err), .waiting(let err):
            state = .failed(err)
            connection?.cancel()
            connection = nil
            resumePendingRead(with: err)
        case .cancelled:
            state = .idle
        default: break
        }
    }

    private func receiveLoop(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                await self.onReceive(data: data, error: error, complete: isComplete)
                if !isComplete, error == nil {
                    await self.receiveLoop(on: conn)
                }
            }
        }
    }

    private func onReceive(data: Data?, error: NWError?, complete: Bool) async {
        if let error {
            resumePendingRead(with: error)
            return
        }
        guard let data, !data.isEmpty else { return }
        rxBuffer.append(data)
        tryCompletePendingRead()
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
            precondition(pendingRead == nil, "OBDConnection: concurrent reads not supported")
            pendingRead = cont
            armReadTimeout(after: timeout)
            tryCompletePendingRead()
        }
        // Strip command echo (ELM327 echoes unless ATE0 was sent) and CR/LF.
        var lines = raw.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespaces) == echo {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    private func armReadTimeout(after timeout: TimeInterval) {
        readTimeoutTask?.cancel()

        let timeoutNs = UInt64(max(timeout, 0) * 1_000_000_000)
        readTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNs)
            await self?.failPendingReadIfNeeded(with: OBDError.timeout)
        }
    }

    private func failPendingReadIfNeeded(with error: Error) {
        guard pendingRead != nil else { return }
        resumePendingRead(with: error)
    }

    private func resumePendingRead(with error: Error) {
        guard let pendingRead else { return }
        self.pendingRead = nil
        readTimeoutTask?.cancel()
        readTimeoutTask = nil
        pendingRead.resume(throwing: error)
    }

    private func resumeReadyContinuations() {
        readyContinuations.forEach { $0.resume() }
        readyContinuations.removeAll()
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

enum OBDError: Error {
    case notReady
    case protocolError(String)
    case timeout
}
