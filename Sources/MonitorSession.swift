import Foundation
import Observation
import UIKit

/// Phone-side coordinator. The real connection intentionally polls only the
/// Alfa/FCA Mode 22 DPF monitor: mixing generic engine Mode 01 commands into
/// this session makes the ECU/header contexts interfere on the real vehicle.
@MainActor
@Observable
final class MonitorSession {
    /// Phone and CarPlay must control one BLE/ELM session. Creating a second
    /// coordinator from the CarPlay scene would race the same adapter and ECU.
    static let shared = MonitorSession()

    typealias Status = SessionStatus

    private(set) var status: Status = .idle {
        didSet {
            UIApplication.shared.isIdleTimerDisabled = status.keepsScreenAwake
        }
    }
    private(set) var dpf: DPFState
    private(set) var lastRegenEvent: String?
    private(set) var activeScenario: DPFSimulationScenario?
    private(set) var alertAuthorization: AlertAuthorizationState = .checking
    private(set) var hasLiveTelemetry = false
    private(set) var carPlayAlertsEnabled: Bool
    private(set) var needsDrivingFocusGuidance: Bool

    var autoConnectEnabled: Bool {
        didSet {
            defaults.set(autoConnectEnabled, forKey: Self.autoConnectDefaultsKey)
        }
    }

    var visibleDashboardMetrics: Set<DashboardMetric> {
        didSet {
            let values = visibleDashboardMetrics.map(\.rawValue).sorted()
            defaults.set(values, forKey: Self.dashboardMetricsDefaultsKey)
        }
    }

    var appAccent: StelvioAccent {
        didSet {
            defaults.set(appAccent.rawValue, forKey: Self.appAccentDefaultsKey)
        }
    }

    private var obd: (any OBDTransport)?
    private var monitor: DPFMonitor?
    private var bootTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var simulationTask: Task<Void, Never>?
    private var simulationTracker = RegenActivityTracker()
    private let alerts: AlertService
    private let liveActivity = DPFLiveActivityController()
    private let defaults: UserDefaults
    private var lastPersistedState: DPFState?
    private var lastAcceptedPollSequence: UInt64 = 0
    private var reportedTelemetryInterruption = false
    private static let autoConnectDefaultsKey = "autoConnectEnabled.v1"
    private static let dashboardMetricsDefaultsKey = "visibleDashboardMetrics.v1"
    private static let batteryMetricMigrationDefaultsKey = "batteryMetricAdded.v1"
    private static let appAccentDefaultsKey = "appAccent.v1"

    /// Secondary vehicle displays must never inherit a Test Lab fixture. Until
    /// a fresh real sample arrives, expose only the last persisted ECU state.
    var carPlayDPFState: DPFState {
        CarPlayTelemetryPolicy.displayState(
            current: dpf,
            lastPersisted: lastPersistedState,
            hasLiveTelemetry: hasLiveTelemetry
        )
    }

    init(defaults: UserDefaults = .standard) {
        let initialAutoConnectEnabled: Bool
        if defaults.object(forKey: Self.autoConnectDefaultsKey) == nil {
            initialAutoConnectEnabled = true
        } else {
            initialAutoConnectEnabled = defaults.bool(forKey: Self.autoConnectDefaultsKey)
        }

        let initialVisibleDashboardMetrics: Set<DashboardMetric>
        if let stored = defaults.stringArray(forKey: Self.dashboardMetricsDefaultsKey) {
            var visibleMetrics = Set(stored.compactMap(DashboardMetric.init(rawValue:)))
            if !defaults.bool(forKey: Self.batteryMetricMigrationDefaultsKey) {
                visibleMetrics.insert(.batteryVoltage)
                defaults.set(true, forKey: Self.batteryMetricMigrationDefaultsKey)
            }
            defaults.set(
                visibleMetrics.map(\.rawValue).sorted(),
                forKey: Self.dashboardMetricsDefaultsKey
            )
            initialVisibleDashboardMetrics = visibleMetrics
        } else {
            initialVisibleDashboardMetrics = Set(DashboardMetric.allCases)
            defaults.set(true, forKey: Self.batteryMetricMigrationDefaultsKey)
        }

        let initialAppAccent = defaults.string(forKey: Self.appAccentDefaultsKey)
            .flatMap(StelvioAccent.init(rawValue:)) ?? .rossoAlfa
        let initialCarPlayAlertsEnabled = CarPlayAlertPreference.load(from: defaults)
        let saved = DPFStateStore.load(from: defaults)

        self.defaults = defaults
        self.alerts = AlertService(carPlayAlertsEnabled: initialCarPlayAlertsEnabled)
        self.autoConnectEnabled = initialAutoConnectEnabled
        self.visibleDashboardMetrics = initialVisibleDashboardMetrics
        self.appAccent = initialAppAccent
        self.carPlayAlertsEnabled = initialCarPlayAlertsEnabled
        self.needsDrivingFocusGuidance =
            DrivingFocusGuidancePreference.needsPresentation(from: defaults)
        self.dpf = saved ?? DPFState()
        self.lastPersistedState = saved
    }

    /// Cached values remain visible while idle, reconnecting, or after an
    /// error, but the UI renders them as historical rather than live.
    var isShowingCachedTelemetry: Bool {
        dpf.hasTelemetry && !hasLiveTelemetry && status != .simulating
    }

    /// The transport can already be connected while the ECU is still
    /// returning its first useful DPF sample. Keep that phase explicit so the
    /// dashboard does not look frozen or empty.
    var isAwaitingTelemetry: Bool {
        status == .connecting || (status == .running && !hasLiveTelemetry)
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
            || needsDrivingFocusGuidance
    }

    func requestNotificationAuthorization() async {
        alertAuthorization = await alerts.configure()
    }

    func refreshNotificationAuthorization() async {
        guard !skipAlertSetupForVisualTest else { return }
        alertAuthorization = await alerts.currentAuthorizationState()
    }

    func acknowledgeDrivingFocusGuidance() {
        DrivingFocusGuidancePreference.acknowledge(in: defaults)
        needsDrivingFocusGuidance = false
    }

    func toggleCarPlayAlerts() async {
        let enabled = !carPlayAlertsEnabled
        await alerts.setCarPlayAlertsEnabled(enabled)
        defaults.set(enabled, forKey: CarPlayAlertPreference.defaultsKey)
        carPlayAlertsEnabled = enabled
        OBDLog.log("CarPlay alerts: \(enabled ? "enabled" : "disabled")")
    }

    func startAutomaticallyIfNeeded() {
        guard autoConnectEnabled else { return }
        guard status == .idle || isFailed(status) else { return }
        start()
    }

    func setDashboardMetric(_ metric: DashboardMetric, isVisible: Bool) {
        if isVisible {
            visibleDashboardMetrics.insert(metric)
        } else {
            visibleDashboardMetrics.remove(metric)
        }
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

    /// Queues the CarPlay-specific system test and exposes the actual queueing
    /// result to the vehicle UI instead of claiming success unconditionally.
    func testCarPlaySystemNotification() async -> Bool {
        let current = await alerts.currentAuthorizationState()
        guard current.authorization == .authorized else {
            alertAuthorization = current
            return false
        }
        alertAuthorization = await alerts.configure()
        return await alerts.notifyCarPlayTest()
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
            exhaustTemperatureC: next.exhaustTempC,
            regenerationMode: next.regenerationMode
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
        let bootStartedAt = Date()
        // Notification settings and BLE discovery are independent. Running
        // them together removes an avoidable pause before scanning without
        // changing the adapter or ELM protocol sequence.
        let alertSetupTask = Task { [weak self, alerts] in
            let authorization = await alerts.configure()
            guard !Task.isCancelled else { return }
            self?.alertAuthorization = authorization
        }

        let obd = BLEConnection()
        self.obd = obd
        await obd.start()
        do {
            try await obd.isReady()
        } catch {
            alertSetupTask.cancel()
            guard !Task.isCancelled, !(error is CancellationError) else {
                await obd.stop()
                return
            }
            OBDLog.log("connection: BLE setup failed: \(error)")
            status = .failed(Self.userMessage(
                for: error,
                fallback: "Impossibile connettersi all’adattatore OBD. Riprova."
            ))
            hasLiveTelemetry = false
            await obd.stop()
            return
        }
        guard !Task.isCancelled else {
            await obd.stop()
            return
        }
        OBDLog.log(
            String(
                format: "connection: BLE ready after %.2f s",
                Date().timeIntervalSince(bootStartedAt)
            )
        )

        let elm = ELM327(connection: obd)
        do {
            try await elm.initializeSession()
        } catch {
            alertSetupTask.cancel()
            guard !Task.isCancelled else { return }
            OBDLog.log("connection: adapter initialization failed: \(error)")
            status = .failed(Self.userMessage(
                for: error,
                fallback: "Impossibile inizializzare l’adattatore OBD. Riprova."
            ))
            hasLiveTelemetry = false
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
        OBDLog.log(
            String(
                format: "connection: session running after %.2f s",
                Date().timeIntervalSince(bootStartedAt)
            )
        )

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
        let importantEdge = last?.effectiveRegenerationMode != snapshot.effectiveRegenerationMode
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
        status = .failed(String(localized: "Telemetria OBD interrotta. Mostro l’ultimo stato valido."))
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

    private static func userMessage(for error: Error, fallback: String.LocalizationValue) -> String {
        if let obdError = error as? OBDError {
            return obdError.localizedDescription
        }
        return String(localized: fallback)
    }

    private var skipAlertSetupForVisualTest: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["ALFADPF_SKIP_ALERT_SETUP"] == "1"
#else
        false
#endif
    }
}
