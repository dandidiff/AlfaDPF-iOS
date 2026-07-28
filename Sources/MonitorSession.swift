import Foundation
import Observation
import UIKit

/// Phone-side coordinator. The real connection intentionally polls only the
/// Alfa/FCA Mode 22 DPF monitor: mixing generic engine Mode 01 commands back
/// into this session previously made the two ECU/header contexts interfere.
@MainActor
@Observable
final class MonitorSession {
    enum Status: Equatable {
        case idle
        case connecting
        case running
        case simulating
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var dpf: DPFState
    private(set) var lastRegenEvent: String?
    private(set) var activeScenario: DPFSimulationScenario?
    private(set) var alertAuthorization: AlertAuthorizationState = .checking
    private(set) var hasLiveTelemetry = false

    /// User-selected transport; persisted and applied on the next connection.
    var transportKind: TransportKind = .saved() {
        didSet { transportKind.save() }
    }

    private var obd: (any OBDTransport)?
    private var monitor: DPFMonitor?
    private var bootTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var simulationTask: Task<Void, Never>?
    private var simulationTracker = RegenActivityTracker()
    private let alerts = AlertService()
    private let liveActivity = DPFLiveActivityController()
    private let defaults: UserDefaults
    private var lastPersistedState: DPFState?
    private var lastAcceptedPollSequence: UInt64 = 0
    private var reportedTelemetryInterruption = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = DPFStateStore.load(from: defaults)
        self.dpf = saved ?? DPFState()
        self.lastPersistedState = saved
    }

    /// Cached values remain visible while idle, reconnecting, or after an
    /// error, but the UI renders them as historical rather than live.
    var isShowingCachedTelemetry: Bool {
        dpf.hasTelemetry && !hasLiveTelemetry && status != .simulating
    }

    /// Reads the current settings without triggering the system sheet, so the
    /// first-launch explanation can appear before iOS asks for permission.
    func prepareNotificationAuthorizationAtLaunch() async -> Bool {
        if skipAlertSetupForVisualTest {
            alertAuthorization = .checking
            return false
        }
        alertAuthorization = await alerts.currentAuthorizationState()
        return alertAuthorization.authorization == .notDetermined
    }

    func requestNotificationAuthorization() async {
        alertAuthorization = await alerts.configure()
    }

    func refreshNotificationAuthorization() async {
        guard !skipAlertSetupForVisualTest else { return }
        alertAuthorization = await alerts.currentAuthorizationState()
    }

    func startAutomaticallyIfNeeded() {
        guard status == .idle || isFailed(status) else { return }
        start()
    }

    func start() {
        guard status == .idle || isFailed(status) else { return }
        cancelWork()
        let previousOBD = obd
        let previousMonitor = monitor
        obd = nil
        monitor = nil
        status = .connecting
        hasLiveTelemetry = false
        activeScenario = nil
        lastRegenEvent = nil
        lastAcceptedPollSequence = 0
        reportedTelemetryInterruption = false
        UIApplication.shared.isIdleTimerDisabled = true

        bootTask = Task { [weak self] in
            await previousMonitor?.stop()
            await previousOBD?.stop()
            guard !Task.isCancelled else { return }
            await self?.boot()
        }
    }

    func stop() {
        cancelWork()
        persistCurrentState()
        let obd = self.obd
        let monitor = self.monitor
        self.monitor = nil
        self.obd = nil
        activeScenario = nil
        status = .idle
        hasLiveTelemetry = false
        UIApplication.shared.isIdleTimerDisabled = false

        Task {
            await monitor?.stop()
            await obd?.stop()
            await liveActivity.end()
        }
    }

    /// Verifies banner + sound independently of ECU data.
    func testNotification() {
        Task {
            alertAuthorization = await alerts.configure()
            await alerts.notifyTest()
        }
    }

    func persistCurrentState() {
        guard status != .simulating, dpf.hasTelemetry else { return }
        DPFStateStore.save(dpf, to: defaults)
        lastPersistedState = dpf
    }

    // MARK: - Test Lab

    func startSimulation() {
        cancelWork()

        let obd = self.obd
        let monitor = self.monitor
        self.monitor = nil
        self.obd = nil
        simulationTracker = RegenActivityTracker()
        status = .simulating
        hasLiveTelemetry = false
        activeScenario = nil
        lastRegenEvent = "Ambiente di prova attivo"
        UIApplication.shared.isIdleTimerDisabled = false

        Task {
            await monitor?.stop()
            await obd?.stop()
            if !skipAlertSetupForVisualTest {
                await alerts.configure()
            }
        }
        setSimulationState(.clean)
    }

    func applySimulation(_ scenario: DPFSimulationScenario) {
        if status != .simulating { startSimulation() }
        simulationTask?.cancel()
        simulationTask = nil
        setSimulationState(scenario)
    }

    /// Runs all important states in a few seconds. Timestamps are advanced by
    /// realistic intervals so the finish notification also tests duration.
    func runSimulationSequence() {
        startSimulation()
        let base = Date()
        simulationTask = Task { [weak self] in
            let sequence: [(DPFSimulationScenario, Date)] = [
                (.clean, base),
                (.loaded, base.addingTimeInterval(4 * 60)),
                (.regenStarted, base.addingTimeInterval(5 * 60)),
                (.regenInProgress, base.addingTimeInterval(11 * 60)),
                (.regenFinished, base.addingTimeInterval(17 * 60)),
            ]

            for (index, item) in sequence.enumerated() {
                guard !Task.isCancelled else { return }
                self?.setSimulationState(item.0, at: item.1)
                if index < sequence.count - 1 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func setSimulationState(
        _ scenario: DPFSimulationScenario,
        at timestamp: Date = .init()
    ) {
        var next = scenario.state(at: timestamp)
        let event = simulationTracker.observe(
            progressPercent: next.regenProgressPercent,
            at: timestamp,
            cloggingPercent: next.cloggingPercent,
            exhaustTemperatureC: next.exhaustTempC
        )
        next.regenActive = simulationTracker.isActive
        dpf = next
        activeScenario = scenario

        switch event {
        case .started(_, let load):
            lastRegenEvent = "Rigenerazione rilevata: avviso di inizio inviato"
            Task { await alerts.notifyRegenStarted(cloggingPercent: load) }
        case .finished(_, let duration):
            lastRegenEvent = "Rigenerazione terminata: avviso di fine inviato"
            Task { await alerts.notifyRegenFinished(duration: duration) }
        case nil:
            lastRegenEvent = scenario.title
        }

        Task { await liveActivity.update(with: next) }
    }

    // MARK: - Real OBD session

    private func boot() async {
        alertAuthorization = await alerts.configure()
        guard !Task.isCancelled else { return }

        let obd = transportKind.makeTransport()
        self.obd = obd
        await obd.start()
        await obd.isReady()
        guard !Task.isCancelled else {
            await obd.stop()
            return
        }

        let elm = ELM327(connection: obd)
        do {
            try await elm.initializeSession()
        } catch {
            guard !Task.isCancelled else { return }
            status = .failed("Adapter init failed: \(error)")
            hasLiveTelemetry = false
            UIApplication.shared.isIdleTimerDisabled = false
            await obd.stop()
            return
        }
        guard !Task.isCancelled else {
            await obd.stop()
            return
        }

        let monitor = DPFMonitor(elm: elm, alerts: alerts)
        self.monitor = monitor
        await monitor.start(interval: .seconds(2))
        status = .running

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let monitorSnapshot = await monitor.snapshot
                if monitorSnapshot.pollSequence != self?.lastAcceptedPollSequence {
                    self?.lastAcceptedPollSequence = monitorSnapshot.pollSequence

                    if monitorSnapshot.hasRecentCoreTelemetry(),
                       !monitorSnapshot.freshPIDs.isEmpty,
                       monitorSnapshot.state.hasTelemetry {
                        self?.acceptLive(monitorSnapshot.state)
                        await self?.liveActivity.update(with: monitorSnapshot.state)
                    } else if monitorSnapshot.pollSequence > 0,
                              !monitorSnapshot.hasRecentCoreTelemetry() {
                        self?.markTelemetryInterrupted()
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func acceptLive(_ snapshot: DPFState) {
        dpf = snapshot
        hasLiveTelemetry = true
        reportedTelemetryInterruption = false
        if isFailed(status) {
            status = .running
        }

        let last = lastPersistedState
        let elapsed = last.map { snapshot.timestamp.timeIntervalSince($0.timestamp) } ?? .infinity
        let importantEdge = last?.regenActive != snapshot.regenActive
            || last?.totalRegenCount != snapshot.totalRegenCount
        if elapsed >= 5 || importantEdge {
            DPFStateStore.save(snapshot, to: defaults)
            lastPersistedState = snapshot
        }
    }

    private func markTelemetryInterrupted() {
        guard !reportedTelemetryInterruption else { return }
        // Keep `dpf` untouched: it is the last accepted snapshot and the UI
        // will immediately relabel it as historical via `hasLiveTelemetry`.
        persistCurrentState()
        hasLiveTelemetry = false
        reportedTelemetryInterruption = true
        status = .failed("Telemetria OBD interrotta. Mostro l’ultimo stato valido.")
        OBDLog.log("telemetry: no core DPF response for 8 s; preserving cached snapshot")
    }

    private func cancelWork() {
        bootTask?.cancel()
        pollTask?.cancel()
        simulationTask?.cancel()
        bootTask = nil
        pollTask = nil
        simulationTask = nil
    }

    private func isFailed(_ status: Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private var skipAlertSetupForVisualTest: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["ALFADPF_SKIP_ALERT_SETUP"] == "1"
#else
        false
#endif
    }
}
