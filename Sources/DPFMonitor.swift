import Foundation

/// Polls regen-relevant PIDs on a cadence, maintains the latest `DPFState`,
/// and emits `RegenEvent`s on state-transition edges. Owns the only place in
/// the app where raw bytes turn into physical units; scaling factors live on
/// `DPFPID` alongside the state machine that depends on them.
actor DPFMonitor {
    private let elm: ELM327
    private let alerts: AlertService
    private var pollTask: Task<Void, Never>?

    private(set) var latest = DPFState()
    private var regenStartedAt: Date?

    /// True until the first poll has populated a baseline. Prevents the
    /// "plug in mid-regen and get a spurious started alert" bug.
    private var needsBaseline = true

    /// Number of consecutive polls where the regen-progress read failed.
    /// After a few, we drop the state to unknown so we don't keep firing
    /// transitions off stale truth.
    private var consecutiveProgressFailures = 0
    private static let progressFailureThreshold = 3

    /// Percentage of `regenProgressPercent` above which we consider the ECU
    /// to be actively regenerating. A small epsilon avoids flapping around
    /// sensor noise when the cycle is idle.
    private static let regenActiveThresholdPercent = 0.5

    init(elm: ELM327, alerts: AlertService) {
        self.elm = elm
        self.alerts = alerts
    }

    func start(interval: Duration = .seconds(2)) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Polling

    private func pollOnce() async {
        var next = DPFState()
        next.timestamp = Date()

        next.cloggingPercent          = try? await read(.cloggingPercent)
        next.exhaustTempC             = try? await read(.exhaustTempC)
        next.totalRegenCount          = try? await read(.totalRegenCount)
        next.distanceSinceLastRegenKm = try? await read(.distanceSinceRegenKm)

        // Regen progress is the load-bearing signal for the notification
        // edge detector. Track failures explicitly.
        do {
            let pct = try await read(.regenProgressPercent)
            next.regenProgressPercent = pct
            next.regenActive = pct > Self.regenActiveThresholdPercent
            consecutiveProgressFailures = 0
        } catch {
            consecutiveProgressFailures += 1
            if consecutiveProgressFailures >= Self.progressFailureThreshold {
                next.regenProgressPercent = nil
                next.regenActive = nil
            } else {
                next.regenProgressPercent = latest.regenProgressPercent
                next.regenActive = latest.regenActive
            }
        }

        if needsBaseline {
            needsBaseline = false
        } else {
            emitEvents(previous: latest, current: next)
        }
        latest = next
    }

    private func read(_ pid: DPFPID) async throws -> Double {
        let bytes = try await elm.readMode22(pid: pid.rawValue)
        return try pid.decode(bytes: bytes)
    }

    // MARK: - Event detection

    private func emitEvents(previous: DPFState, current: DPFState) {
        // Edges only fire on known→known transitions. nil means we don't
        // know, so we refuse to guess.
        guard let wasActive = previous.regenActive,
              let nowActive = current.regenActive else { return }

        if !wasActive && nowActive {
            regenStartedAt = current.timestamp
            Task { await alerts.notifyRegenStarted(cloggingPercent: current.cloggingPercent) }
        } else if wasActive && !nowActive, let started = regenStartedAt {
            let duration = current.timestamp.timeIntervalSince(started)
            regenStartedAt = nil
            Task { await alerts.notifyRegenFinished(duration: duration) }
        }
    }
}
