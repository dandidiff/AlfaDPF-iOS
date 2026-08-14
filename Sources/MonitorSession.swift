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
            if oldValue != status {
                publishCarPlayRefresh(.liveness)
            }
        }
    }
    private(set) var dpf: DPFState
    private(set) var lastRegenEvent: String?
    private(set) var activeScenario: DPFSimulationScenario?
    private(set) var alertAuthorization: AlertAuthorizationState = .checking
    private(set) var hasLiveTelemetry = false
    private(set) var carPlayAlertsEnabled: Bool
    private(set) var needsDrivingFocusGuidance: Bool
    private(set) var historyStore: DPFHistoryStore?
    private(set) var estimatedRegenerationTimeRemaining: TimeInterval? = nil

    var autoConnectEnabled: Bool {
        didSet {
            defaults.set(autoConnectEnabled, forKey: Self.autoConnectDefaultsKey)
        }
    }

    var transportKind: OBDTransportKind {
        didSet { transportKind.save(to: defaults) }
    }

    var wifiHost: String {
        didSet { defaults.set(wifiHost, forKey: Self.wifiHostDefaultsKey) }
    }

    var wifiPort: String {
        didSet { defaults.set(wifiPort, forKey: Self.wifiPortDefaultsKey) }
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

    var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: AppLanguage.defaultsKey)
        }
    }

    private var obd: (any OBDTransport)?
    private var monitor: DPFMonitor?
    private var bootTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var simulationTask: Task<Void, Never>?
    private var workGeneration: UInt64 = 0
    private var simulationTracker = RegenActivityTracker()
    private let alerts: AlertService
    private let liveActivity = DPFLiveActivityController()
    private let defaults: UserDefaults
    private var lastRecordedCloggingPercent: Double?
    private var lastPersistedState: DPFState?
    private var lastAcceptedPollSequence: UInt64 = 0
    private var reportedTelemetryInterruption = false
    private var lastLiveRegenState: Bool?
    private var engineOffDetector = RegenEngineOffDetector()
    private var regenTimeEstimator = RegenTimeEstimator()
    private var carPlayRefreshSubscribers: [
        UUID: AsyncStream<CarPlayRefreshEvent>.Continuation
    ] = [:]
    private static let autoConnectDefaultsKey = "autoConnectEnabled.v1"
    private static let dashboardMetricsDefaultsKey = "visibleDashboardMetrics.v1"
    private static let batteryMetricMigrationDefaultsKey = "batteryMetricAdded.v1"
    private static let appAccentDefaultsKey = "appAccent.v1"
    private static let wifiHostDefaultsKey = "wifiAdapterHost.v1"
    private static let wifiPortDefaultsKey = "wifiAdapterPort.v1"

    /// Secondary vehicle displays must never inherit a Test Lab fixture. Until
    /// a fresh real sample arrives, expose only the last persisted ECU state.
    var carPlayDPFState: DPFState {
        CarPlayTelemetryPolicy.displayState(
            current: dpf,
            lastPersisted: lastPersistedState,
            status: status,
            hasLiveTelemetry: hasLiveTelemetry
        )
    }

    /// CarPlay subscribes only while its scene is connected. A newest-one
    /// buffer coalesces dense ECU callbacks if the main actor is busy, avoiding
    /// an update backlog after iOS temporarily suspends execution.
    func carPlayRefreshEvents() -> AsyncStream<CarPlayRefreshEvent> {
        let id = UUID()
        let pair = AsyncStream<CarPlayRefreshEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        carPlayRefreshSubscribers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.carPlayRefreshSubscribers[id] = nil
            }
        }
        return pair.stream
    }

    private func publishCarPlayRefresh(_ event: CarPlayRefreshEvent) {
        for continuation in carPlayRefreshSubscribers.values {
            _ = continuation.yield(event)
        }
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
        let initialAppLanguage = AppLanguage.load(from: defaults)
        let initialTransportKind = OBDTransportKind.load(from: defaults)
        let initialWiFiHost = defaults.string(forKey: Self.wifiHostDefaultsKey)
            ?? WiFiAdapterEndpoint.commonDefault.host
        let initialWiFiPort = defaults.string(forKey: Self.wifiPortDefaultsKey)
            ?? String(WiFiAdapterEndpoint.commonDefault.port)
        let initialCarPlayAlertsEnabled = CarPlayAlertPreference.load(from: defaults)
        let saved = DPFStateStore.load(from: defaults)

        self.defaults = defaults
        self.alerts = AlertService(carPlayAlertsEnabled: initialCarPlayAlertsEnabled)
        self.historyStore = { () -> DPFHistoryStore? in
            do { return try DPFHistoryStore() } catch {
                OBDLog.log("history: store init failed: \(error)")
                return nil
            }
        }()
        self.autoConnectEnabled = initialAutoConnectEnabled
        self.visibleDashboardMetrics = initialVisibleDashboardMetrics
        self.appAccent = initialAppAccent
        self.appLanguage = initialAppLanguage
        self.transportKind = initialTransportKind
        self.wifiHost = initialWiFiHost
        self.wifiPort = initialWiFiPort
        self.carPlayAlertsEnabled = initialCarPlayAlertsEnabled
        self.needsDrivingFocusGuidance =
            DrivingFocusGuidancePreference.needsPresentation(from: defaults)
        self.dpf = saved ?? DPFState()
        self.lastPersistedState = saved
        if historyStore?.recordActiveRegenUnconfirmed() == true {
            OBDLog.log("history: active regen from previous app lifecycle marked unconfirmed")
        }
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

    /// Preserves a confirmed active cycle through transient unknown PID reads.
    /// Used by safety-sensitive UI such as disconnect confirmation.
    var isRegenerationInProgress: Bool {
        if status == .simulating { return dpf.isRegenerating }
        return status == .running && lastLiveRegenState == true
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
        if historyStore?.recordActiveRegenUnconfirmed() == true {
            OBDLog.log("history: active regen from previous session marked unconfirmed")
        }
        cancelWork()
        let generation = workGeneration
        let previousOBD = obd
        let previousMonitor = monitor
        obd = nil
        monitor = nil
        status = .connecting
        hasLiveTelemetry = false
        activeScenario = nil
        lastRegenEvent = nil
        lastAcceptedPollSequence = 0
        lastRecordedCloggingPercent = nil
        reportedTelemetryInterruption = false
        lastLiveRegenState = nil
        engineOffDetector.reset()
        regenTimeEstimator.reset()
        estimatedRegenerationTimeRemaining = nil

        bootTask = Task { [weak self] in
            await previousMonitor?.stop()
            await previousOBD?.stop()
            guard let self,
                  !Task.isCancelled,
                  generation == self.workGeneration
            else { return }
            await self.boot(generation: generation)
        }
    }

    func stop() {
        if historyStore?.recordActiveRegenUnconfirmed() == true {
            OBDLog.log("history: active regen marked unconfirmed on session stop")
        }
        cancelWork()
        let generation = workGeneration
        persistCurrentState()
        let obd = self.obd
        let monitor = self.monitor
        self.monitor = nil
        self.obd = nil
        activeScenario = nil
        status = .idle
        hasLiveTelemetry = false
        regenTimeEstimator.reset()
        estimatedRegenerationTimeRemaining = nil

        Task { [weak self] in
            await monitor?.stop()
            await obd?.stop()
            guard let self, generation == self.workGeneration else { return }
            await self.liveActivity.end()
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
        if historyStore?.recordActiveRegenUnconfirmed() == true {
            OBDLog.log("history: active regen marked unconfirmed before simulation")
        }
        cancelWork()
        let generation = workGeneration

        let obd = self.obd
        let monitor = self.monitor
        self.monitor = nil
        self.obd = nil
        simulationTracker = RegenActivityTracker()
        regenTimeEstimator.reset()
        estimatedRegenerationTimeRemaining = nil
        status = .simulating
        hasLiveTelemetry = false
        activeScenario = nil
        lastRegenEvent = "Ambiente di prova attivo"

        Task { [weak self] in
            await monitor?.stop()
            await obd?.stop()
            guard let self, generation == self.workGeneration else { return }
            if !self.skipAlertSetupForVisualTest {
                await self.alerts.configure()
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
        let generation = workGeneration
        simulationTask = Task { [weak self] in
            let sequence: [(DPFSimulationScenario, Date)] = [
                (.clean, base),
                (.loaded, base.addingTimeInterval(4 * 60)),
                (.regenStarted, base.addingTimeInterval(5 * 60)),
                (.regenInProgress, base.addingTimeInterval(11 * 60)),
                (.regenFinished, base.addingTimeInterval(17 * 60)),
            ]

            for (index, item) in sequence.enumerated() {
                guard let self,
                      !Task.isCancelled,
                      generation == self.workGeneration
                else { return }
                self.setSimulationState(item.0, at: item.1)
                if index < sequence.count - 1 {
                    try? await Task.sleep(for: self.simulationStepDuration)
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
        estimatedRegenerationTimeRemaining = regenTimeEstimator.observe(
            progressPercent: next.regenProgressPercent,
            regenerationMode: next.effectiveRegenerationMode,
            at: timestamp
        )
        dpf = next
        activeScenario = scenario

        switch event {
        case .started(_, let load):
            lastRegenEvent = "Rigenerazione rilevata: avviso di inizio inviato"
            runForCurrentGeneration {
                await self.alerts.notifyRegenStarted(cloggingPercent: load)
            }
        case .finished(_, let duration):
            lastRegenEvent = "Rigenerazione terminata: avviso di fine inviato"
            runForCurrentGeneration {
                await self.alerts.notifyRegenFinished(duration: duration)
            }
        case nil:
            lastRegenEvent = scenario.title
        }

        runForCurrentGeneration {
            await self.liveActivity.update(with: next)
        }
    }

    // MARK: - Real OBD session

    private func boot(generation: UInt64) async {
        guard generation == workGeneration else { return }
        let bootStartedAt = Date()
        // Notification settings and transport setup are independent. Running
        // them together removes an avoidable pause before connecting without
        // changing the adapter or ELM protocol sequence.
        let alertSetupTask = Task { [weak self, alerts] in
            let authorization = await alerts.configure()
            guard let self,
                  !Task.isCancelled,
                  generation == self.workGeneration
            else { return }
            self.alertAuthorization = authorization
        }

        let obd: any OBDTransport
        switch transportKind {
        case .bluetooth:
            OBDLog.log("connection: transport Bluetooth LE")
            obd = BLEConnection(defaults: defaults)
        case .wifi:
            guard let endpoint = WiFiAdapterEndpoint.parse(host: wifiHost, port: wifiPort) else {
                alertSetupTask.cancel()
                status = .failed(OBDError.invalidWiFiEndpoint.localizedDescription)
                hasLiveTelemetry = false
                return
            }
            OBDLog.log("connection: transport Wi-Fi TCP \(endpoint.host):\(endpoint.port)")
            obd = OBDConnection(endpoint: .init(host: endpoint.host, port: endpoint.port))
        }
        self.obd = obd
        await obd.start()
        guard !Task.isCancelled, generation == workGeneration else {
            await obd.stop()
            return
        }
        do {
            try await obd.isReady()
        } catch {
            alertSetupTask.cancel()
            guard !Task.isCancelled,
                  generation == workGeneration,
                  !(error is CancellationError)
            else {
                await obd.stop()
                return
            }
            OBDLog.log("connection: \(transportKind.title) setup failed: \(error)")
            status = .failed(Self.userMessage(
                for: error,
                fallback: "Impossibile connettersi all’adattatore OBD. Riprova."
            ))
            hasLiveTelemetry = false
            await obd.stop()
            return
        }
        guard !Task.isCancelled, generation == workGeneration else {
            await obd.stop()
            return
        }
        OBDLog.log(
            String(
                format: "connection: %@ ready after %.2f s",
                transportKind.title,
                Date().timeIntervalSince(bootStartedAt)
            )
        )

        let elm = ELM327(connection: obd)
        do {
            try await elm.initializeSession()
        } catch {
            alertSetupTask.cancel()
            guard !Task.isCancelled, generation == workGeneration else {
                await obd.stop()
                return
            }
            OBDLog.log("connection: adapter initialization failed: \(error)")
            status = .failed(Self.userMessage(
                for: error,
                fallback: "Impossibile inizializzare l’adattatore OBD. Riprova."
            ))
            hasLiveTelemetry = false
            await obd.stop()
            return
        }
        guard !Task.isCancelled, generation == workGeneration else {
            await obd.stop()
            return
        }

        let cacheIdentifier = await obd.cacheIdentifier()
        let profileStore = cacheIdentifier.map {
            DPFECUProfileStore(identifier: $0, defaults: defaults)
        }
        let monitor = DPFMonitor(
            elm: elm,
            alerts: alerts,
            profileStore: profileStore
        )
        self.monitor = monitor
        await monitor.start(interval: .seconds(2))
        guard !Task.isCancelled, generation == workGeneration else {
            await monitor.stop()
            await obd.stop()
            return
        }
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
                guard let self,
                      !Task.isCancelled,
                      generation == self.workGeneration
                else { return }
                if monitorSnapshot.pollSequence != self.lastAcceptedPollSequence {
                    self.lastAcceptedPollSequence = monitorSnapshot.pollSequence

                    if monitorSnapshot.hasRecentCoreTelemetry(),
                       !monitorSnapshot.freshPIDs.isEmpty,
                       monitorSnapshot.state.hasTelemetry {
                        self.acceptLive(monitorSnapshot.state)
                        await self.liveActivity.update(with: monitorSnapshot.state)
                        guard !Task.isCancelled,
                              generation == self.workGeneration
                        else { return }
                    }
                }
                // Freshness is a wall-clock property, not a poll-completion
                // property. A long header probe or a blocked transport write
                // must not leave the dashboard labelled Live indefinitely
                // just because `pollSequence` has not advanced yet.
                if monitorSnapshot.pollSequence > 0,
                   !monitorSnapshot.hasRecentCoreTelemetry() {
                    self.markTelemetryInterrupted(with: monitorSnapshot.state)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func acceptLive(_ snapshot: DPFState) {
        _ = engineOffDetector.observe(
            voltage: snapshot.batteryVoltage,
            at: snapshot.timestamp,
            coreTelemetryAvailable: true
        )
        dpf = snapshot
        hasLiveTelemetry = true
        reportedTelemetryInterruption = false
        if isFailed(status) {
            status = .running
        }

        let historyTransition = RegenHistoryTransition.resolve(
            previous: lastLiveRegenState,
            observed: snapshot.regenActive
        )
        lastLiveRegenState = historyTransition.nextKnownState
        publishCarPlayRefresh(
            historyTransition.didStart || historyTransition.didFinish
                ? .regenerationEdge
                : .telemetry
        )
        estimatedRegenerationTimeRemaining = regenTimeEstimator.observe(
            progressPercent: snapshot.regenProgressPercent,
            regenerationMode: historyTransition.nextKnownState == true ? .active : .none,
            at: snapshot.timestamp
        )

        // History recording: sample on ≥1% load delta.
        if let store = historyStore, let load = snapshot.cloggingPercent {
            let delta = lastRecordedCloggingPercent.map { abs(load - $0) } ?? .infinity
            if delta >= 1.0 {
                let generation = workGeneration
                Task { [weak self] in
                    let recorded = await store.recordSampleAsync(
                        timestamp: snapshot.timestamp,
                        cloggingPercent: load,
                        exhaustTempC: snapshot.exhaustTempC,
                        regenActive: historyTransition.nextKnownState == true,
                        distanceSinceLastRegenKm: snapshot.distanceSinceLastRegenKm
                    )
                    guard let self, generation == self.workGeneration else { return }
                    if recorded {
                        self.lastRecordedCloggingPercent = load
                    }
                }
            }
        }

        // Regen cycle tracking is based only on fresh live edges. A cached
        // active state from a previous app run cannot prove whether that cycle
        // later completed or was interrupted.
        if historyTransition.confirmedInitialInactivity,
           historyStore?.recordActiveRegenUnconfirmed() == true {
            OBDLog.log("history: unresolved regen from previous app lifecycle marked unconfirmed")
        }
        if historyTransition.didStart,
           let load = snapshot.cloggingPercent {
            _ = historyStore?.recordRegenStart(at: snapshot.timestamp, load: load)
        } else if historyTransition.didFinish {
            _ = historyStore?.recordRegenFinish(
                at: snapshot.timestamp,
                endingLoad: snapshot.cloggingPercent
            )
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

    private func markTelemetryInterrupted(with latestMonitorState: DPFState) {
        // Keep `dpf` untouched: it is the last accepted snapshot and the UI
        // will immediately relabel it as historical via `hasLiveTelemetry`.

        // ATRV remains available from many ELM adapters after ECU traffic
        // disappears. Only sustained low-voltage evidence following a live
        // alternator baseline can classify the active cycle as interrupted.
        let engineOffConfirmed = engineOffDetector.observe(
            voltage: latestMonitorState.batteryVoltage,
            at: latestMonitorState.timestamp,
            coreTelemetryAvailable: false
        )
        let wasRegenerating = lastLiveRegenState == true
        if wasRegenerating, engineOffConfirmed,
           historyStore?.recordRegenInterrupted(
               at: latestMonitorState.timestamp,
               endingLoad: latestMonitorState.cloggingPercent ?? dpf.cloggingPercent
           ) == true {
            let voltage = latestMonitorState.batteryVoltage ?? 0
            OBDLog.log(String(
                format: "history: regen interrupted — sustained battery drop to %.1fV after telemetry loss",
                voltage
            ))
        }

        guard !reportedTelemetryInterruption else { return }
        persistCurrentState()
        hasLiveTelemetry = false
        regenTimeEstimator.reset()
        estimatedRegenerationTimeRemaining = nil
        reportedTelemetryInterruption = true
        status = .failed(AppLocalization.string("Telemetria OBD interrotta. Mostro l’ultimo stato valido."))
        OBDLog.log("telemetry: no core DPF response for 8 s; preserving cached snapshot")
        if transportKind == .wifi {
            // A post-ready TCP loss is terminal. Stop both loops so no further
            // command is attempted until a new session reruns the ELM bootstrap.
            pollTask?.cancel()
            pollTask = nil
            if let monitor {
                Task { await monitor.stop() }
            }
        }
    }

    private func cancelWork() {
        workGeneration &+= 1
        bootTask?.cancel()
        pollTask?.cancel()
        simulationTask?.cancel()
        bootTask = nil
        pollTask = nil
        simulationTask = nil
    }

    private func runForCurrentGeneration(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        let generation = workGeneration
        Task { [weak self] in
            guard let self, generation == self.workGeneration else { return }
            await operation()
        }
    }

    private func isFailed(_ status: Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private static func userMessage(for error: Error, fallback: String.LocalizationValue) -> String {
        if let obdError = error as? OBDError {
            return obdError.localizedDescription
        }
        return AppLocalization.string(key: fallback)
    }

    private var skipAlertSetupForVisualTest: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["ALFADPF_SKIP_ALERT_SETUP"] == "1"
#else
        false
#endif
    }

    private var simulationStepDuration: Duration {
#if DEBUG
        if let raw = ProcessInfo.processInfo.environment["ALFADPF_SIMULATION_STEP_SECONDS"],
           let seconds = Double(raw),
           (1...30).contains(seconds) {
            return .seconds(seconds)
        }
#endif
        return .seconds(2)
    }
}
