import Foundation
import Network

/// Wi-Fi TCP client for an ELM327-style OBD dongle.
///
/// Typical dongle exposes a TCP server at 192.168.0.10:35000 once the phone
/// joins its Wi-Fi. `connect()` retries forever with a fixed backoff; callers
/// await `isReady()` before sending commands. The command/response framing
/// lives in `ELMLineEngine`; this actor owns the socket and its lifecycle.
actor OBDConnection: OBDTransport {
    struct Endpoint {
        var host: String
        var port: UInt16
        static let defaultELM = Endpoint(host: "192.168.0.10", port: 35000)
    }

    enum State { case idle, connecting, ready, failed(Error) }

    private let endpoint: Endpoint
    private let engine = ELMLineEngine()
    private var connection: NWConnection?
    private(set) var state: State = .idle
    private var reconnectTask: Task<Void, Never>?
    private var readyContinuations: [CheckedContinuation<Void, Never>] = []

    init(endpoint: Endpoint = .defaultELM) {
        self.endpoint = endpoint
    }

    /// Starts a reconnect loop. Returns immediately; await `isReady()` to
    /// block until the socket is usable.
    func start() {
        reconnectTask?.cancel()
        reconnectTask = Task { await reconnectLoop() }
    }

    func stop() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.cancel()
        connection = nil
        await engine.reset()
        resumeReadyContinuations()
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

    func send(_ command: String, header: String?, timeout: TimeInterval) async throws -> String {
        guard case .ready = state, let connection else {
            throw OBDError.notReady
        }
        return try await engine.perform(command, header: header, timeout: timeout) { data in
            try await Self.write(data, over: connection)
        }
    }

    // MARK: - Private

    private static func write(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    private func reconnectLoop() async {
        while !Task.isCancelled {
            state = .connecting
            await engine.reset()
            let conn = NWConnection(
                host: .init(endpoint.host),
                port: .init(rawValue: endpoint.port)!,
                using: .tcp
            )
            connection = conn
            conn.stateUpdateHandler = { [weak self] newState in
                Task { await self?.handleNWState(newState, for: conn) }
            }
            conn.start(queue: .global(qos: .userInitiated))
            receiveLoop(on: conn)

            // Wait until the connection either becomes ready or fails.
            await waitWhile { if case .connecting = $0 { return true } else { return false } }
            guard !Task.isCancelled else { break }

            // Stay parked while the socket is healthy; a drop (failed /
            // cancelled / remote close) falls through into the retry path.
            if case .ready = state {
                await waitWhile { if case .ready = $0 { return true } else { return false } }
                guard !Task.isCancelled else { break }
            }

            conn.cancel()
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s backoff
        }
    }

    private func waitWhile(_ predicate: (State) -> Bool) async {
        // Polling is fine here — state transitions are rare.
        while !Task.isCancelled, predicate(state) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func handleNWState(_ nw: NWConnection.State, for conn: NWConnection) async {
        // Events from a superseded connection must not touch shared state —
        // e.g. an old socket's `.failed` arriving while a fresh attempt is
        // mid-handshake would tear the new one down.
        guard conn === connection else { return }
        switch nw {
        case .ready:
            // ELM327 wants a reset + a couple of AT lines before first use.
            // That's handled by ELM327 on top of this, not here.
            state = .ready
            resumeReadyContinuations()
        case .failed(let err), .waiting(let err):
            await connectionLost(err, conn: conn)
        case .cancelled:
            state = .idle
        default: break
        }
    }

    private func connectionLost(_ error: Error, conn: NWConnection) async {
        state = .failed(error)
        conn.cancel()
        await engine.failPendingRead(with: error)
    }

    private func receiveLoop(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                await self.onReceive(data: data, error: error, complete: isComplete, conn: conn)
                if !isComplete, error == nil {
                    await self.receiveLoop(on: conn)
                }
            }
        }
    }

    private func onReceive(data: Data?, error: NWError?, complete: Bool, conn: NWConnection) async {
        guard conn === connection else { return }
        if let data {
            await engine.ingest(data)
        }
        if let error {
            await connectionLost(error, conn: conn)
        } else if complete {
            // Remote close (dongle rebooted or dropped the session). Without
            // this the state would stay `.ready` on a dead socket forever.
            await connectionLost(OBDError.protocolError("connection closed by adapter"), conn: conn)
        }
    }

    private func resumeReadyContinuations() {
        readyContinuations.forEach { $0.resume() }
        readyContinuations.removeAll()
    }
}
