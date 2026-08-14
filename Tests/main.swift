import Foundation
import Network
import CoreBluetooth

// Standalone test runner for the pure protocol logic + OBDConnection.
// Runs on macOS without Xcode:
//   swiftc Sources/Models.swift Sources/OBDLog.swift Sources/OBDTransport.swift \\
//          Sources/OBDConnection.swift Sources/BLEConnection.swift Sources/ELM327.swift \\
//          Sources/Mode01.swift Sources/DPFHistoryStore.swift Tests/main.swift \\
//          -lsqlite3 -o /tmp/alfadpf_tests && /tmp/alfadpf_tests

var failures = 0

func expect(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS: \(name)")
    } else {
        failures += 1
        print("FAIL: \(name)")
    }
}

func expectBytes(_ name: String, _ body: () throws -> [UInt8], prefix: [UInt8]) {
    do {
        let bytes = try body()
        expect(Array(bytes.prefix(prefix.count)) == prefix, name)
    } catch {
        failures += 1
        print("FAIL: \(name) — threw \(error)")
    }
}

func expectThrows(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        failures += 1
        print("FAIL: \(name) — expected throw, got none")
    } catch {
        print("PASS: \(name)")
    }
}

// Settings regression: the explanatory oil-pressure/SGW disclaimer is gone,
// while the categorical oil-pressure telemetry and diagnostics remain.
do {
    let appSource = try String(contentsOfFile: "Sources/AlfaDPFApp.swift", encoding: .utf8)
    let localization = try String(contentsOfFile: "App/Localizable.xcstrings", encoding: .utf8)
    let removedStrings = [
        "Pressione olio e SGW",
        "Sui diesel compatibili il PID disponibile indica uno stato ECU, non un valore in bar.",
        "Con bypass SGW già installato, i PID avanzati possono diventare accessibili se la centralina li espone."
    ]

    for string in removedStrings {
        expect(!appSource.contains(string), "settings regression: disclaimer source text removed")
        expect(!localization.contains(string), "settings regression: unused localization key removed")
    }
    expect(appSource.contains("title: \"STATO PRESSIONE OLIO\""),
           "settings regression: categorical oil-pressure card retained")
    expect(appSource.contains("Stato pressione olio 22194D"),
           "settings regression: oil-pressure diagnostic retained")
} catch {
    failures += 1
    print("FAIL: settings regression: could not read source or localization — \(error)")
}

actor InitializationTestTransport: OBDTransport {
    enum Behavior {
        case valid
        case rejectsEverything
        case resetTimeoutThenLegacy
    }

    struct Sent: Equatable {
        var command: String
        var header: String?
    }

    private let behavior: Behavior
    private var sent: [Sent] = []

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func start() {}
    func stop() async {}
    func isReady() async throws {}

    func send(_ command: String, header: String?, timeout: TimeInterval) async throws -> String {
        sent.append(.init(command: command, header: header))
        switch behavior {
        case .valid:
            if command == "ATZ" { return "ELM327 v1.5" }
            if command == "22380B" { return "NO DATA" }
            if command == "ATDPN" { return "A7" }
            return "OK"
        case .rejectsEverything:
            return "?"
        case .resetTimeoutThenLegacy:
            if command == "ATZ" { throw OBDError.timeout }
            if command == "ATI" { return "ELM327 v1.5" }
            if command == "22380B" { return "NO DATA" }
            if command == "ATDPN" { return "A7" }
            return "?"
        }
    }

    func commands() -> [Sent] { sent }
}

// MARK: - Session policies and deep links

expect(AppDeepLink.monitorURL.absoluteString == "alfadpf://monitor",
       "deep link: canonical URL remains stable")
expect(AppDeepLink.parse(URL(string: "alfadpf://monitor")!) == .monitor,
       "deep link: canonical monitor route")
expect(AppDeepLink.parse(URL(string: "alfadpf://connect")!) == .monitor,
       "deep link: legacy connect alias")
expect(AppDeepLink.parse(URL(string: "alfadpf:")!) == .monitor,
       "deep link: legacy bare scheme")
expect(AppDeepLink.parse(URL(string: "alfadpf://unknown")!) == nil,
       "deep link: rejects unknown destination")
expect(AppDeepLink.parse(URL(string: "alfadpf:///unknown")!) == nil,
       "deep link: rejects unknown path")
expect(AppDeepLink.parse(URL(string: "https://monitor")!) == nil,
       "deep link: rejects foreign scheme")

expect(SessionStatus.connecting.keepsScreenAwake,
       "idle timer: connecting keeps screen awake")
expect(SessionStatus.running.keepsScreenAwake,
       "idle timer: live session keeps screen awake")
expect(!SessionStatus.idle.keepsScreenAwake
       && !SessionStatus.simulating.keepsScreenAwake
       && !SessionStatus.failed("test").keepsScreenAwake,
       "idle timer: idle, simulation and failures release screen")

var engineOffDetector = RegenEngineOffDetector()
let voltageStart = Date(timeIntervalSince1970: 1_000)
expect(!engineOffDetector.observe(voltage: 12.4, at: voltageStart, coreTelemetryAvailable: false),
       "history engine-off: low voltage without a running baseline is inconclusive")
expect(!engineOffDetector.observe(voltage: 14.2, at: voltageStart, coreTelemetryAvailable: true),
       "history engine-off: live alternator voltage arms the detector")
expect(!engineOffDetector.observe(voltage: 12.6,
                                  at: voltageStart.addingTimeInterval(1),
                                  coreTelemetryAvailable: false),
       "history engine-off: one low sample is insufficient")
expect(!engineOffDetector.observe(voltage: 12.5,
                                  at: voltageStart.addingTimeInterval(3),
                                  coreTelemetryAvailable: false),
       "history engine-off: short low-voltage interval is insufficient")
expect(engineOffDetector.observe(voltage: 12.4,
                                 at: voltageStart.addingTimeInterval(6),
                                 coreTelemetryAvailable: false),
       "history engine-off: sustained drop after live running voltage confirms shutdown")
engineOffDetector.reset()
_ = engineOffDetector.observe(voltage: 14.1, at: voltageStart, coreTelemetryAvailable: true)
_ = engineOffDetector.observe(voltage: 12.5,
                              at: voltageStart.addingTimeInterval(1),
                              coreTelemetryAvailable: false)
_ = engineOffDetector.observe(voltage: 13.8,
                              at: voltageStart.addingTimeInterval(2),
                              coreTelemetryAvailable: true)
expect(!engineOffDetector.observe(voltage: 12.5,
                                  at: voltageStart.addingTimeInterval(6),
                                  coreTelemetryAvailable: false),
       "history engine-off: recovered live telemetry resets a transient drop")
engineOffDetector.reset()
_ = engineOffDetector.observe(voltage: 14.0, at: voltageStart, coreTelemetryAvailable: true)
_ = engineOffDetector.observe(voltage: 12.6,
                              at: voltageStart.addingTimeInterval(1),
                              coreTelemetryAvailable: true)
_ = engineOffDetector.observe(voltage: 12.5,
                              at: voltageStart.addingTimeInterval(2),
                              coreTelemetryAvailable: false)
_ = engineOffDetector.observe(voltage: 12.4,
                              at: voltageStart.addingTimeInterval(5),
                              coreTelemetryAvailable: false)
expect(!engineOffDetector.observe(voltage: 12.3,
                                  at: voltageStart.addingTimeInterval(8),
                                  coreTelemetryAvailable: false),
       "history engine-off: low last-live voltage invalidates an older alternator peak")

expect(SessionStatus.idle.carPlayConnectionAction == .connect
       && SessionStatus.failed("test").carPlayConnectionAction == .connect
       && SessionStatus.simulating.carPlayConnectionAction == .connect,
       "carplay: idle, failed and simulation states offer connect")
expect(SessionStatus.connecting.carPlayConnectionAction == .cancel,
       "carplay: connecting state offers cancellation")
expect(SessionStatus.running.carPlayConnectionAction == .disconnect,
       "carplay: running state offers disconnect")
expect(CarPlayRefreshPolicy.interval >= .seconds(10),
       "carplay: periodic dashboard refresh respects Apple's 10-second minimum")
expect(CarPlayRefreshTrigger.telemetry.minimumInterval >= 10
       && CarPlayRefreshTrigger.periodic.minimumInterval >= 10,
       "carplay: periodic and telemetry refreshes respect Apple's 10-second limit")
expect(CarPlayRefreshTrigger.regenerationEdge.minimumInterval <= 2
       && CarPlayRefreshTrigger.liveness.minimumInterval <= 2
       && CarPlayRefreshTrigger.deferredEvent.minimumInterval == 0,
       "carplay: discrete safety/liveness edges stay responsive without double-throttling deferred work")

let carPlayRefreshStart = Date(timeIntervalSince1970: 3_000)
var carPlayRefreshGate = CarPlayRefreshGate<String>()
expect(carPlayRefreshGate.evaluate(
    signature: "idle",
    at: carPlayRefreshStart,
    minimumInterval: 0
) == .render(effectiveInterval: nil),
       "carplay refresh: first presentation renders immediately")
expect(carPlayRefreshGate.evaluate(
    signature: "idle",
    at: carPlayRefreshStart.addingTimeInterval(0.5),
    minimumInterval: CarPlayRefreshTrigger.telemetry.minimumInterval
) == .skipDuplicate,
       "carplay refresh: unchanged presentation is deduplicated")
let throttledRefresh = carPlayRefreshGate.evaluate(
    signature: "regen-started",
    at: carPlayRefreshStart.addingTimeInterval(1),
    minimumInterval: CarPlayRefreshTrigger.regenerationEdge.minimumInterval
)
if case .deferFor(let delay) = throttledRefresh {
    expect(abs(delay - 1) < 0.001,
           "carplay refresh: changed telemetry is deferred only for the remaining throttle window")
} else {
    expect(false, "carplay refresh: changed telemetry is throttled before two seconds")
}
let allowedRefresh = carPlayRefreshGate.evaluate(
    signature: "regen-started",
    at: carPlayRefreshStart.addingTimeInterval(2),
    minimumInterval: CarPlayRefreshTrigger.regenerationEdge.minimumInterval
)
if case .render(let effectiveInterval) = allowedRefresh {
    expect(effectiveInterval.map { abs($0 - 2) < 0.001 } == true,
           "carplay refresh: changed telemetry renders at the bounded event interval")
} else {
    expect(false, "carplay refresh: changed telemetry renders after the throttle window")
}
expect(carPlayRefreshGate.evaluate(
    signature: "regen-started",
    at: carPlayRefreshStart.addingTimeInterval(10),
    minimumInterval: CarPlayRefreshTrigger.periodic.minimumInterval
) == .skipDuplicate,
       "carplay refresh: periodic deadline also skips unchanged content")

var periodicCollisionGate = CarPlayRefreshGate<String>()
_ = periodicCollisionGate.evaluate(
    signature: "before-periodic-collision",
    at: carPlayRefreshStart.addingTimeInterval(9.5),
    minimumInterval: 0
)
_ = periodicCollisionGate.evaluate(
    signature: "changed-before-periodic-tick",
    at: carPlayRefreshStart.addingTimeInterval(9.9),
    minimumInterval: CarPlayRefreshTrigger.telemetry.minimumInterval
)
expect(periodicCollisionGate.evaluate(
    signature: "changed-before-periodic-tick",
    at: carPlayRefreshStart.addingTimeInterval(10),
    minimumInterval: CarPlayRefreshTrigger.periodic.minimumInterval
) == .deferFor(9.5),
       "carplay refresh: periodic tick cannot bypass the global render throttle")

var carPlayRefreshMetrics = CarPlayRefreshMetrics()
carPlayRefreshMetrics.recordRequest(trigger: .telemetry)
carPlayRefreshMetrics.recordDecision(.skipDuplicate)
carPlayRefreshMetrics.recordRequest(trigger: .regenerationEdge)
carPlayRefreshMetrics.recordDecision(.render(effectiveInterval: 2))
carPlayRefreshMetrics.recordFailure()
let carPlayMetricsSummary = carPlayRefreshMetrics.summaryLine
expect(carPlayMetricsSummary.contains("requests=2")
       && carPlayMetricsSummary.contains("renders=1")
       && carPlayMetricsSummary.contains("duplicates=1")
       && carPlayMetricsSummary.contains("failures=1")
       && carPlayMetricsSummary.contains("event_requests=2")
       && carPlayMetricsSummary.contains("effective_interval=2.00s"),
       "carplay refresh: privacy-safe metrics expose effective interval and deduplication")
expect(!carPlayMetricsSummary.contains("VIN")
       && !carPlayMetricsSummary.contains("latitude")
       && !carPlayMetricsSummary.contains("longitude"),
       "carplay refresh: metrics contain no sensitive vehicle or location fields")

// QA matrix for the change-driven path. These virtual-clock checks exercise
// timing deterministically instead of making the suite sleep for real seconds.
var burstGate = CarPlayRefreshGate<String>()
var burstMetrics = CarPlayRefreshMetrics()
for index in 0...30 {
    let trigger: CarPlayRefreshTrigger = index == 0 ? .interaction : .telemetry
    burstMetrics.recordRequest(trigger: trigger)
    let decision = burstGate.evaluate(
        signature: "unchanged",
        at: carPlayRefreshStart.addingTimeInterval(Double(index) * 2),
        minimumInterval: trigger.minimumInterval
    )
    burstMetrics.recordDecision(decision)
}
expect(burstMetrics.requests == 31
       && burstMetrics.renders == 1
       && burstMetrics.duplicateSkips == 30
       && burstMetrics.deferrals == 0,
       "carplay refresh QA: one minute of unchanged ECU events causes one render")

var latestValueGate = CarPlayRefreshGate<String>()
_ = latestValueGate.evaluate(
    signature: "sample-a",
    at: carPlayRefreshStart,
    minimumInterval: 0
)
expect(latestValueGate.evaluate(
    signature: "sample-b",
    at: carPlayRefreshStart.addingTimeInterval(0.5),
    minimumInterval: CarPlayRefreshTrigger.telemetry.minimumInterval
) == .deferFor(9.5),
       "carplay refresh QA: first burst change waits for the remaining ten-second budget")
expect(latestValueGate.evaluate(
    signature: "sample-c",
    at: carPlayRefreshStart.addingTimeInterval(1),
    minimumInterval: CarPlayRefreshTrigger.telemetry.minimumInterval
) == .deferFor(9),
       "carplay refresh QA: a newer deferred value replaces stale work")
expect(latestValueGate.evaluate(
    signature: "sample-c",
    at: carPlayRefreshStart.addingTimeInterval(10),
    minimumInterval: CarPlayRefreshTrigger.telemetry.minimumInterval
) == .render(effectiveInterval: 10),
       "carplay refresh QA: newest burst value renders at the ten-second boundary")

var failureGate = CarPlayRefreshGate<String>()
_ = failureGate.evaluate(
    signature: "running",
    at: carPlayRefreshStart,
    minimumInterval: 0
)
expect(failureGate.evaluate(
    signature: "network-failed",
    at: carPlayRefreshStart.addingTimeInterval(2),
    minimumInterval: CarPlayRefreshTrigger.liveness.minimumInterval
) == .render(effectiveInterval: 2),
       "carplay refresh QA: network/liveness failure reaches CarPlay within two seconds")
expect(failureGate.evaluate(
    signature: "network-failed",
    at: carPlayRefreshStart.addingTimeInterval(10),
    minimumInterval: 0
) == .skipDuplicate,
       "carplay refresh QA: periodic fallback does not redraw the same failure")

var resumedGate = CarPlayRefreshGate<String>()
_ = resumedGate.evaluate(
    signature: "before-suspension",
    at: carPlayRefreshStart,
    minimumInterval: 0
)
expect(resumedGate.evaluate(
    signature: "latest-after-resume",
    at: carPlayRefreshStart.addingTimeInterval(60),
    minimumInterval: CarPlayRefreshTrigger.telemetry.minimumInterval
) == .render(effectiveInterval: 60),
       "carplay refresh QA: latest state renders immediately after a long suspension")
resumedGate.reset()
expect(resumedGate.evaluate(
    signature: "reconnected",
    at: carPlayRefreshStart.addingTimeInterval(61),
    minimumInterval: CarPlayRefreshTrigger.telemetry.minimumInterval
) == .render(effectiveInterval: nil),
       "carplay refresh QA: scene reconnect resets stale timing and content state")

let newestEventPair = AsyncStream<CarPlayRefreshEvent>.makeStream(
    bufferingPolicy: .bufferingNewest(1)
)
newestEventPair.continuation.yield(.telemetry)
newestEventPair.continuation.yield(.regenerationEdge)
newestEventPair.continuation.yield(.liveness)
var newestEventIterator = newestEventPair.stream.makeAsyncIterator()
let newestBufferedEvent = await newestEventIterator.next()
if case .liveness? = newestBufferedEvent {
    expect(true, "carplay refresh QA: suspension backlog retains only the newest event")
} else {
    expect(false, "carplay refresh QA: suspension backlog retains only the newest event")
}
newestEventPair.continuation.finish()

// Wiring audit: refresh evaluation must not start an extra ECU/network request,
// and CarPlay scene teardown must stop all three refresh tasks.
do {
    let carPlaySource = try String(
        contentsOfFile: "Sources/CarPlaySceneDelegate.swift",
        encoding: .utf8
    )
    let monitorSource = try String(
        contentsOfFile: "Sources/MonitorSession.swift",
        encoding: .utf8
    )
    if let refreshStart = carPlaySource.range(of: "private func refreshDashboard("),
       let refreshEnd = carPlaySource.range(
           of: "private func makeDashboardRenderSignature()",
           range: refreshStart.upperBound..<carPlaySource.endIndex
       ) {
        let refreshBody = String(carPlaySource[refreshStart.lowerBound..<refreshEnd.lowerBound])
        expect(!refreshBody.contains(".send(")
               && !refreshBody.contains(".start(")
               && !refreshBody.contains("poll"),
               "carplay refresh QA: UI refresh performs no additional ECU/network request")
    } else {
        expect(false, "carplay refresh QA: refresh body remains source-auditable")
    }
    expect(monitorSource.contains("bufferingPolicy: .bufferingNewest(1)"),
           "carplay refresh QA: suspended consumers cannot accumulate an event backlog")
    expect(carPlaySource.contains("periodicRefreshTask?.cancel()")
           && carPlaySource.contains("eventRefreshTask?.cancel()")
           && carPlaySource.contains("deferredRefreshTask?.cancel()"),
           "carplay refresh QA: disconnect/background teardown cancels refresh work")
} catch {
    failures += 1
    print("FAIL: carplay refresh QA: could not audit lifecycle wiring — \(error)")
}

expect(CarPlayNotificationTestPolicy.systemDeliveryDelay >= 10,
       "carplay notifications: system test leaves enough time to return Home")
expect(DPFLoadAlertLevel.resolve(loadPercent: nil, regenerationMode: .none) == .unavailable,
       "carplay colors: absent load stays neutral")
expect(DPFLoadAlertLevel.resolve(loadPercent: 84.9, regenerationMode: .none) == .low,
       "carplay colors: low load is green")
expect(DPFLoadAlertLevel.resolve(loadPercent: 85, regenerationMode: .none) == .nearRegeneration
       && DPFLoadAlertLevel.resolve(loadPercent: 95, regenerationMode: .none) == .nearRegeneration,
       "carplay colors: 85 through 95 warns that regeneration is near")
expect(DPFLoadAlertLevel.resolve(loadPercent: 95.1, regenerationMode: .none) == .regenerationImminent,
       "carplay colors: load above 95 warns that regeneration is imminent")
expect(DPFLoadAlertLevel.resolve(loadPercent: 30, regenerationMode: .active) == .activeRegeneration,
       "carplay colors: active regeneration overrides the load band with blue")
expect(DPFLoadAlertLevel.resolve(loadPercent: 88, regenerationMode: .passive) == .nearRegeneration,
       "carplay colors: passive regeneration preserves the load warning band")

var regenTimeEstimator = RegenTimeEstimator()
let estimatorStart = Date(timeIntervalSince1970: 2_000)
expect(regenTimeEstimator.observe(
    progressPercent: 10,
    regenerationMode: .active,
    at: estimatorStart
) == nil, "regen ETA: one sample never fabricates an estimate")
let publishedETA = regenTimeEstimator.observe(
    progressPercent: 15,
    regenerationMode: .active,
    at: estimatorStart.addingTimeInterval(60)
)
expect(publishedETA.map { abs($0 - 1_020) < 0.001 } == true,
       "regen ETA: progress rate produces a bounded remaining-time estimate")
expect(regenTimeEstimator.observe(
    progressPercent: nil,
    regenerationMode: .active,
    at: estimatorStart.addingTimeInterval(61)
) == publishedETA, "regen ETA: a missing active sample preserves the estimate")
expect(regenTimeEstimator.observe(
    progressPercent: nil,
    regenerationMode: .active,
    at: estimatorStart.addingTimeInterval(661)
) == nil, "regen ETA: a missing progress PID eventually expires the estimate")
expect(regenTimeEstimator.observe(
    progressPercent: 15,
    regenerationMode: .none,
    at: estimatorStart.addingTimeInterval(62)
) == nil, "regen ETA: leaving active mode clears the estimate")
expect(regenTimeEstimator.estimatedTimeRemaining == nil,
       "regen ETA: reset removes stale published state")

var fastRegenTimeEstimator = RegenTimeEstimator()
var fastAdapterETA: TimeInterval?
for second in 0...31 {
    fastAdapterETA = fastRegenTimeEstimator.observe(
        progressPercent: 10 + Double(second) * 0.1,
        regenerationMode: .active,
        at: estimatorStart.addingTimeInterval(Double(second))
    )
}
expect(fastAdapterETA != nil,
       "regen ETA: dense one-second samples retain the full observation window")

let unknownHistoryTransition = RegenHistoryTransition.resolve(
    previous: true,
    observed: nil
)
expect(unknownHistoryTransition.nextKnownState == true
       && !unknownHistoryTransition.didFinish,
       "history transition: an unknown poll preserves an active cycle")
let finishedHistoryTransition = RegenHistoryTransition.resolve(
    previous: unknownHistoryTransition.nextKnownState,
    observed: false
)
expect(finishedHistoryTransition.didFinish
       && finishedHistoryTransition.nextKnownState == false,
       "history transition: only confirmed inactivity closes an active cycle")
let initialInactiveTransition = RegenHistoryTransition.resolve(
    previous: nil,
    observed: false
)
expect(initialInactiveTransition.confirmedInitialInactivity,
       "history transition: first explicit idle sample can reconcile an orphan cycle")

let nonLiveCarPlayStatuses: [SessionStatus] = [
    .idle,
    .connecting,
    .simulating,
    .failed("test"),
]
for status in nonLiveCarPlayStatuses {
    expect(!CarPlayTelemetryPolicy.isLive(status: status, hasLiveTelemetry: true),
           "carplay liveness: non-running status stays offline")
}
expect(!CarPlayTelemetryPolicy.isLive(status: .running, hasLiveTelemetry: false),
       "carplay liveness: running transport without fresh telemetry stays offline")
expect(CarPlayTelemetryPolicy.isLive(status: .running, hasLiveTelemetry: true),
       "carplay liveness: running session with fresh telemetry is live")

var carPlayArtworkState = DPFState()
carPlayArtworkState.cloggingPercent = 90
for metric in CarPlayDashboardMetric.allCases {
    expect(CarPlayDashboardIconPolicy.tone(
        for: metric,
        state: carPlayArtworkState,
        isLive: false
    ) == .neutral, "carplay artwork: every offline tile is neutral")
}
expect(CarPlayDashboardIconPolicy.tone(
    for: .distance,
    state: carPlayArtworkState,
    isLive: true
) == .accent, "carplay artwork: ordinary live metrics use the app accent")
expect(CarPlayDashboardIconPolicy.tone(
    for: .dpf,
    state: carPlayArtworkState,
    isLive: true
) == .dpfSemantic(.nearRegeneration),
       "carplay artwork: live DPF tile preserves semantic warning color")
expect(CarPlayDashboardIconPolicy.tone(
    for: .regeneration,
    state: carPlayArtworkState,
    isLive: true
) == .accent, "carplay artwork: live idle regeneration tile uses accent")
carPlayArtworkState.regenActive = true
expect(CarPlayDashboardIconPolicy.tone(
    for: .regeneration,
    state: carPlayArtworkState,
    isLive: true
) == .regenerationSemantic(.active),
       "carplay artwork: active regeneration keeps its semantic color")
expect(CarPlayDashboardMetric.allCases.count == CarPlayDashboardPolicy.maximumTileCount,
       "carplay dashboard: glanceable grid stays within eight tiles")
expect(CarPlayDashboardPolicy.maximumInformationItemCount == 4,
       "carplay dashboard: detail surfaces stay compact")

func carPlayNotificationState(
    authorization: AlertAuthorizationState.Authorization = .authorized,
    timeSensitive: Bool = true,
    carPlay: Bool = true,
    alerts: Bool = true,
    sound: Bool = true
) -> AlertAuthorizationState {
    AlertAuthorizationState(
        authorization: authorization,
        timeSensitiveEnabled: timeSensitive,
        siriAnnouncementsEnabled: false,
        carPlayEnabled: carPlay,
        alertEnabled: alerts,
        lockScreenEnabled: true,
        soundEnabled: sound
    )
}

expect(carPlayNotificationState().carPlayNotificationIssues.isEmpty,
       "carplay notifications: fully enabled settings are ready")
expect(carPlayNotificationState().canPresentSystemCarPlayAlert,
       "carplay notifications: authorized visible CarPlay alerts can replace the CPAlert fallback")
expect(!carPlayNotificationState(authorization: .denied).canPresentSystemCarPlayAlert
       && !carPlayNotificationState(carPlay: false).canPresentSystemCarPlayAlert
       && !carPlayNotificationState(alerts: false).canPresentSystemCarPlayAlert,
       "carplay notifications: authorization, CarPlay and alert presentation are all required")
expect(carPlayNotificationState(
    authorization: .denied
).carPlayNotificationIssues == [.permissionDenied],
       "carplay notifications: denied authorization is diagnosed")
expect(carPlayNotificationState(
    authorization: .notDetermined
).carPlayNotificationIssues == [.permissionRequired],
       "carplay notifications: missing authorization is diagnosed")
expect(carPlayNotificationState(
    timeSensitive: false,
    carPlay: false,
    alerts: false,
    sound: false
).carPlayNotificationIssues == [
    .carPlayDisabled,
    .alertsDisabled,
    .timeSensitiveDisabled,
    .soundDisabled,
],
       "carplay notifications: every delivery and sound problem is exposed")

let carPlayAlertSuite = "AlphaDPF.CarPlayAlertPreferenceTests.\(UUID().uuidString)"
let carPlayAlertDefaults = UserDefaults(suiteName: carPlayAlertSuite)!
carPlayAlertDefaults.removePersistentDomain(forName: carPlayAlertSuite)
expect(CarPlayAlertPreference.load(from: carPlayAlertDefaults),
       "carplay alerts: delivery is enabled by default")
carPlayAlertDefaults.set(false, forKey: CarPlayAlertPreference.defaultsKey)
expect(!CarPlayAlertPreference.load(from: carPlayAlertDefaults),
       "carplay alerts: disabled preference persists")
carPlayAlertDefaults.set(true, forKey: CarPlayAlertPreference.defaultsKey)
expect(CarPlayAlertPreference.load(from: carPlayAlertDefaults),
       "carplay alerts: enabled preference persists")
expect(CarPlayNotificationRoute.production(carPlayAlertsEnabled: true) == .carPlay,
       "carplay alerts: enabled production events use the CarPlay category")
expect(CarPlayNotificationRoute.production(carPlayAlertsEnabled: false) == .phoneOnly,
       "carplay alerts: disabled production events remain phone-only")
expect(CarPlayNotificationRoute.explicitTest == .carPlay,
       "carplay alerts: an explicit user test still exercises CarPlay delivery")
carPlayAlertDefaults.removePersistentDomain(forName: carPlayAlertSuite)

let drivingFocusSuite = "AlphaDPF.DrivingFocusGuidance.\(UUID().uuidString)"
let drivingFocusDefaults = UserDefaults(suiteName: drivingFocusSuite)!
drivingFocusDefaults.removePersistentDomain(forName: drivingFocusSuite)
expect(DrivingFocusGuidancePreference.needsPresentation(from: drivingFocusDefaults),
       "driving focus onboarding: new and existing users see the guidance once")
DrivingFocusGuidancePreference.acknowledge(in: drivingFocusDefaults)
expect(!DrivingFocusGuidancePreference.needsPresentation(from: drivingFocusDefaults),
       "driving focus onboarding: acknowledgement persists")
drivingFocusDefaults.removePersistentDomain(forName: drivingFocusSuite)

let appLanguageSuite = "AlphaDPF.AppLanguage.\(UUID().uuidString)"
let appLanguageDefaults = UserDefaults(suiteName: appLanguageSuite)!
appLanguageDefaults.removePersistentDomain(forName: appLanguageSuite)
expect(AppLanguage.load(from: appLanguageDefaults) == .system,
       "app language: system locale is the default")
for language in AppLanguage.allCases {
    appLanguageDefaults.set(language.rawValue, forKey: AppLanguage.defaultsKey)
    expect(AppLanguage.load(from: appLanguageDefaults) == language,
           "app language: every supported selection persists")
}
appLanguageDefaults.set("unsupported", forKey: AppLanguage.defaultsKey)
expect(AppLanguage.load(from: appLanguageDefaults) == .system,
       "app language: invalid stored values fall back to system")
expect(AppLanguage.system.localeIdentifier == nil,
       "app language: system selection has no forced locale")
expect(AppLanguage.italian.localeIdentifier == "it"
       && AppLanguage.english.localeIdentifier == "en"
       && AppLanguage.french.localeIdentifier == "fr"
       && AppLanguage.spanish.localeIdentifier == "es",
       "app language: explicit locale identifiers are stable")
expect(AppLanguage.allCases.map(\.displayNameKey) == [
    "Sistema", "Italiano", "English", "Français", "Español",
], "app language: selector order and native names stay stable")
appLanguageDefaults.removePersistentDomain(forName: appLanguageSuite)

do {
    let localization = try String(
        contentsOfFile: "App/Localizable.xcstrings",
        encoding: .utf8
    )
    expect(localization.contains("\"Avanzamento\" : {"),
           "carplay localization: compact progress tile key is present")
} catch {
    failures += 1
    print("FAIL: carplay localization: could not read catalog — \(error)")
}

var carPlayCurrentState = DPFState()
carPlayCurrentState.cloggingPercent = 88
var carPlayPersistedState = DPFState()
carPlayPersistedState.cloggingPercent = 42
expect(CarPlayTelemetryPolicy.displayState(
    current: carPlayCurrentState,
    lastPersisted: carPlayPersistedState,
    status: .running,
    hasLiveTelemetry: true
).cloggingPercent == 88,
       "carplay telemetry: fresh real sample wins")
expect(CarPlayTelemetryPolicy.displayState(
    current: carPlayCurrentState,
    lastPersisted: carPlayPersistedState,
    status: .idle,
    hasLiveTelemetry: false
).cloggingPercent == 42,
       "carplay telemetry: cached real state hides non-live fixture")
expect(!CarPlayTelemetryPolicy.displayState(
    current: carPlayCurrentState,
    lastPersisted: nil,
    status: .failed("test"),
    hasLiveTelemetry: false
).hasTelemetry,
       "carplay telemetry: no real state displays unavailable values")

var carPlayAlertTracker = CarPlayRegenerationAlertTracker()
expect(carPlayAlertTracker.observe(
    isRegenerating: false,
    finishConfirmationSequence: 0,
    telemetryIsLive: false
) == nil, "carplay alert: cached telemetry never creates an event")
expect(carPlayAlertTracker.observe(
    isRegenerating: false,
    finishConfirmationSequence: 0,
    telemetryIsLive: true
) == nil, "carplay alert: first live sample arms without a false event")
expect(carPlayAlertTracker.observe(
    isRegenerating: true,
    finishConfirmationSequence: 0,
    telemetryIsLive: true
) == .started, "carplay alert: inactive-to-active edge starts regeneration")
expect(carPlayAlertTracker.observe(
    isRegenerating: true,
    finishConfirmationSequence: 0,
    telemetryIsLive: true
) == nil, "carplay alert: stable active state does not repeat")
expect(carPlayAlertTracker.observe(
    isRegenerating: nil,
    finishConfirmationSequence: 0,
    telemetryIsLive: true
) == nil, "carplay alert: unknown regeneration sample does not emit a false finish")
expect(carPlayAlertTracker.observe(
    isRegenerating: true,
    finishConfirmationSequence: 0,
    telemetryIsLive: true
) == nil, "carplay alert: recovery from unknown preserves the active edge")
expect(carPlayAlertTracker.observe(
    isRegenerating: false,
    finishConfirmationSequence: 0,
    telemetryIsLive: true
) == nil, "carplay alert: inactive edge waits for distance-reset confirmation")
expect(carPlayAlertTracker.observe(
    isRegenerating: false,
    finishConfirmationSequence: 1,
    telemetryIsLive: true
) == .finished, "carplay alert: confirmed distance reset finishes regeneration")
expect(carPlayAlertTracker.observe(
    isRegenerating: false,
    finishConfirmationSequence: 1,
    telemetryIsLive: true
) == nil, "carplay alert: stable confirmation sequence does not duplicate finish")
expect(carPlayAlertTracker.observe(
    isRegenerating: true,
    finishConfirmationSequence: 1,
    telemetryIsLive: false
) == nil && carPlayAlertTracker.observe(
    isRegenerating: true,
    finishConfirmationSequence: 1,
    telemetryIsLive: true
) == nil, "carplay alert: telemetry interruption rearms without a false event")

for error in [
    OBDError.notReady,
    .protocolError("test"),
    .timeout,
    .connectionTimeout,
    .bluetoothUnauthorized,
    .bluetoothPoweredOff,
    .bluetoothUnavailable,
    .connectionFailed,
    .incompatibleAdapter,
    .invalidWiFiEndpoint,
    .wifiConnectionTimeout,
] {
    expect(!error.localizedDescription.isEmpty,
           "OBD error: user-readable \(error)")
}

// MARK: - Optional project support

expect(
    ProjectSupport.donationURL.scheme == "https"
        && ProjectSupport.donationURL.host == "ko-fi.com"
        && ProjectSupport.donationURL.path == "/eddytamburi",
    "support: public Ko-fi URL is exact and HTTPS"
)
let supportPromptSuite = "AlphaDPF.SupportPrompt.\(UUID().uuidString)"
let supportPromptDefaults = UserDefaults(suiteName: supportPromptSuite)!
var promptedTooEarly = false
for _ in 1..<ProjectSupportPromptPolicy.launchThreshold {
    if ProjectSupportPromptPolicy.registerLaunch(in: supportPromptDefaults) {
        promptedTooEarly = true
    }
}
expect(!promptedTooEarly, "support: first nine launches do not prompt")
expect(ProjectSupportPromptPolicy.registerLaunch(in: supportPromptDefaults),
       "support: tenth launch requests the optional prompt")
expect(ProjectSupportPromptPolicy.registerLaunch(in: supportPromptDefaults),
       "support: pending prompt survives until it is actually presented")
ProjectSupportPromptPolicy.markPresented(in: supportPromptDefaults)
expect(!ProjectSupportPromptPolicy.registerLaunch(in: supportPromptDefaults),
       "support: prompt never nags again after presentation")
supportPromptDefaults.removePersistentDomain(forName: supportPromptSuite)

// MARK: - Mode 22 parsing

// Single frame, 11-bit CAN header (3 hex chars!), spaces off (ATH1 + ATS0).
expectBytes("mode22: 11-bit header, no spaces",
            { try ELM327.parseMode22Response("7E8056218E40CCD", expectedPID: 0x18E4) },
            prefix: [0x0C, 0xCD])

// Same frame with spaces (ATS1) and pad bytes.
expectBytes("mode22: 11-bit header, spaces, padding",
            { try ELM327.parseMode22Response("7E8 05 62 18 E4 0C CD 00 00", expectedPID: 0x18E4) },
            prefix: [0x0C, 0xCD])

// Headers off (ATH0).
expectBytes("mode22: no header",
            { try ELM327.parseMode22Response("6218E40CCD", expectedPID: 0x18E4) },
            prefix: [0x0C, 0xCD])

// 29-bit CAN header (Giulia/Stelvio): 18DAF1<src> <len> 62 <pid> <data>.
expectBytes("mode22: 29-bit header (Stelvio)",
            { try ELM327.parseMode22Response("18DAF110056218E40CCD", expectedPID: 0x18E4) },
            prefix: [0x0C, 0xCD])

// ELM prints SEARCHING... before the first response after protocol select.
expectBytes("mode22: SEARCHING... line skipped",
            { try ELM327.parseMode22Response("SEARCHING...\r7E8056218E40CCD", expectedPID: 0x18E4) },
            prefix: [0x0C, 0xCD])

// Dongle rebooted -> echo back on. Echo line must not confuse the parser.
expectBytes("mode22: echo line skipped",
            { try ELM327.parseMode22Response("2218E4\r7E8056218E40CCD", expectedPID: 0x18E4) },
            prefix: [0x0C, 0xCD])

expectThrows("mode22: NO DATA throws") {
    _ = try ELM327.parseMode22Response("NO DATA", expectedPID: 0x18E4)
}

expectThrows("mode22: ? throws") {
    _ = try ELM327.parseMode22Response("?", expectedPID: 0x18E4)
}

expectThrows("mode22: CAN ERROR throws") {
    _ = try ELM327.parseMode22Response("CAN ERROR", expectedPID: 0x18E4)
}

expectThrows("mode22: PID mismatch throws") {
    _ = try ELM327.parseMode22Response("7E8056218DE0CCD", expectedPID: 0x18E4)
}

expectBytes("mode22: coolant 221003 response",
            { try ELM327.parseMode22Response("18DAF110056210031900", expectedPID: 0x1003) },
            prefix: [0x19, 0x00])

// MARK: - Adapter voltage

do {
    let voltage = try ELM327.parseBatteryVoltage("12.6V\r>")
    expect(abs(voltage - 12.6) < 0.001, "ATRV: parses adapter voltage")
    let echoed = try ELM327.parseBatteryVoltage("ATRV\r14.2 V\r>")
    expect(abs(echoed - 14.2) < 0.001, "ATRV: ignores command echo and spaces")
} catch {
    failures += 1
    print("FAIL: ATRV parsing threw \(error)")
}

expectThrows("ATRV: rejects invalid response") {
    _ = try ELM327.parseBatteryVoltage("NO DATA\r>")
}

// MARK: - DPF decoding

do {
    let pct = try DPFPID.cloggingPercent.decode(bytes: [0x0C, 0xCD])
    expect(abs(pct - 50.0) < 0.1, "decode: clogging ~50%")
    let raw = try DPFPID.cloggingPercent.integerRawValue(bytes: [0x11, 0x27])
    let observed = try DPFPID.cloggingPercent.decode(bytes: [0x11, 0x27])
    expect(
        raw == 4391
            && abs(observed - (4391.0 * 1000.0 / 65_535.0)) < 0.000_001
            && DPFPID.cloggingPercent.formulaDescription == "raw×1000/65535",
        "decode: load retains exact raw value and published FCA equation"
    )
    let temp = try DPFPID.exhaustTempC.decode(bytes: [0x59, 0xD8]) // 23000 * 0.02 - 40
    expect(abs(temp - 420.0) < 0.01, "decode: exhaust 420 °C")
    let postDPFTemp = try DPFPID.postDPFTempC.decode(bytes: [0x7D, 0x00])
    expect(abs(postDPFTemp - 600.0) < 0.01, "decode: post-DPF exhaust 600 °C")
    let coolant = try DPFPID.coolantTemperatureC.decode(bytes: [0x19, 0x00])
    expect(
        coolant == 88
            && DPFPID.coolantTemperatureC.command == "221003"
            && DPFPID.coolantTemperatureC.formulaDescription == "raw×0.02−40 °C",
        "decode: FCA coolant raw 0x1900 is 88 °C"
    )
    let progress = try DPFPID.regenProgressPercent.decode(bytes: [0x80, 0x00])
    expect(abs(progress - 50.0) < 0.01, "decode: regen process ~50%")
    let distance = try DPFPID.distanceSinceRegenKm.decode(bytes: [0x00, 0x05, 0xE8])
    expect(abs(distance - 151.2) < 0.01, "decode: distance since regen 151.2 km")
    expect(
        try DPFPID.oilPressureStatus.integerRawValue(bytes: [0x02]) == 2,
        "decode: oil pressure status uses one byte"
    )
} catch {
    failures += 1
    print("FAIL: DPF decoding threw \(error)")
}

expectThrows("decode: distance requires three bytes") {
    _ = try DPFPID.distanceSinceRegenKm.decode(bytes: [0x05, 0xE8])
}

// MARK: - IBS battery state of charge

do {
    let direct = try DPFPID.batteryStateOfChargeDirect.decode(bytes: [0x01, 0x52])
    expect(abs(direct - 82.0) < 0.01, "ibs: direct 221005 uses payload byte B → 82%")
    let mirror = try DPFPID.batteryStateOfChargeMirror.decode(bytes: [0x4B])
    expect(abs(mirror - 75.0) < 0.01, "ibs: mirror 2219BD uses payload byte A → 75%")
    let directVoltage = try DPFPID.batteryVoltageDirect.decode(bytes: [0x80])
    let mirrorVoltage = try DPFPID.batteryVoltageMirror.decode(bytes: [0x64, 0x00])
    expect(abs(directVoltage - 12.8) < 0.001,
           "ibs voltage: direct 221004 uses byte A ÷ 10")
    expect(abs(mirrorVoltage - 12.8) < 0.001,
           "ibs voltage: engine mirror 221955 uses raw × 0.0005")
    var directIBSPayload = Array(repeating: UInt8(0), count: 13)
    directIBSPayload[1] = 82
    directIBSPayload[9] = 0x28
    directIBSPayload[10] = 0x00
    expect(abs(try BatteryTelemetryPolicy.directEmbeddedVoltage(bytes: directIBSPayload) - 12.8) < 0.001,
           "ibs voltage: 221005 bytes J/K expose the battery voltage used by other diagnostic apps")
    expect(try DPFPID.batteryStateOfChargeDirect.decode(bytes: [0x00, 0x00]) == 0,
           "ibs: 0% is a valid boundary")
    expect(try DPFPID.batteryStateOfChargeMirror.decode(bytes: [0x64]) == 100,
           "ibs: 100% is a valid boundary")
    expect(try (
        DPFPID.batteryStateOfChargeDirect.decode(bytes: [0xFF, 0x64]) == 100
            && DPFPID.batteryStateOfChargeMirror.decode(bytes: [0x00]) == 0
    ), "ibs: both sources accept both inclusive boundaries")
    let directFrame = try ELM327.parseMode22Response(
        "18DAF140056210050152",
        expectedPID: DPFPID.batteryStateOfChargeDirect.rawValue
    )
    let mirrorFrame = try ELM327.parseMode22Response(
        "18DAF110046219BD4B",
        expectedPID: DPFPID.batteryStateOfChargeMirror.rawValue
    )
    expect(try (
        DPFPID.batteryStateOfChargeDirect.decode(bytes: directFrame) == 82
            && DPFPID.batteryStateOfChargeMirror.decode(bytes: mirrorFrame) == 75
    ), "ibs: raw ECU frames propagate through Mode 22 parsing and PID decoding")
    expect(BatteryStateOfChargeSource.ibsDirect.pid == .batteryStateOfChargeDirect
           && BatteryStateOfChargeSource.engineECUMirror.pid == .batteryStateOfChargeMirror,
           "ibs: source maps to the right SOC PID")
    expect(BatteryStateOfChargeSource.ibsDirect.voltagePID == .batteryVoltageDirect
           && BatteryStateOfChargeSource.engineECUMirror.voltagePID == .batteryVoltageMirror,
           "ibs: source maps to the right battery-voltage fallback PID")
    expect(BatteryStateOfChargeSource.ibsDirect.requestHeader == "18DA40F1"
           && BatteryStateOfChargeSource.engineECUMirror.requestHeader == "18DA10F1",
           "ibs: direct routes to 18DA40F1, mirror to 18DA10F1")
} catch {
    failures += 1
    print("FAIL: IBS decoding threw \(error)")
}

expectThrows("ibs: direct requires at least two payload bytes") {
    _ = try DPFPID.batteryStateOfChargeDirect.decode(bytes: [0x52])
}
expectThrows("ibs voltage: embedded 221005 voltage requires bytes J/K") {
    _ = try BatteryTelemetryPolicy.directEmbeddedVoltage(bytes: [0x00, 0x52])
}
expectThrows("ibs voltage: implausible direct battery voltage is rejected") {
    _ = try DPFPID.batteryVoltageDirect.decode(bytes: [0xFF])
}
expectThrows("ibs: mirror requires at least one payload byte") {
    _ = try DPFPID.batteryStateOfChargeMirror.decode(bytes: [])
}
expectThrows("ibs: direct out-of-range value is rejected, never clamped") {
    _ = try DPFPID.batteryStateOfChargeDirect.decode(bytes: [0x00, 0x65]) // 101
}
expectThrows("ibs: mirror out-of-range value is rejected, never clamped") {
    _ = try DPFPID.batteryStateOfChargeMirror.decode(bytes: [0xFF]) // 255
}
expectThrows("ibs: unsupported NO DATA reply stays unavailable") {
    let bytes = try ELM327.parseMode22Response(
        "NO DATA\r>",
        expectedPID: DPFPID.batteryStateOfChargeDirect.rawValue
    )
    _ = try DPFPID.batteryStateOfChargeDirect.decode(bytes: bytes)
}
expectThrows("ibs: non-numeric payload is rejected") {
    let bytes = try ELM327.parseMode22Response(
        "18DAF1400562100501GG",
        expectedPID: DPFPID.batteryStateOfChargeDirect.rawValue
    )
    _ = try DPFPID.batteryStateOfChargeDirect.decode(bytes: bytes)
}

// Merging and freshness policy: a stale optional IBS sample must not be
// presented as live, and a fresh sample carries its source and timestamp.
let ibsAt = Date(timeIntervalSince1970: 1_750_000_100)
var ibsFresh = DPFState(timestamp: ibsAt)
ibsFresh.batteryStateOfChargePercent = 82
ibsFresh.batteryStateOfChargeSource = .ibsDirect
ibsFresh.batteryStateOfChargeUpdatedAt = ibsAt
ibsFresh.batterySystemVoltage = 12.8
ibsFresh.batterySystemVoltageUpdatedAt = ibsAt
let ibsStaleAt = ibsAt.addingTimeInterval(45)
var ibsStale = ibsFresh
ibsStale.timestamp = ibsStaleAt
ibsStale.batteryStateOfChargeUpdatedAt = ibsStaleAt
ibsStale.batterySystemVoltageUpdatedAt = ibsStaleAt
expect(ibsFresh.freshBatteryStateOfChargePercent(at: ibsAt.addingTimeInterval(10)) == 82,
       "ibs freshness: a recent SOC sample is live")
expect(ibsFresh.freshBatterySystemVoltage(at: ibsAt.addingTimeInterval(10)) == 12.8,
       "ibs freshness: a recent battery-ECU voltage sample is live")
expect(ibsStale.freshBatteryStateOfChargePercent(at: ibsStaleAt.addingTimeInterval(40)) == nil,
       "ibs freshness: a SOC sample older than the 30-second window is not live")
expect(ibsStale.freshBatterySystemVoltage(at: ibsStaleAt.addingTimeInterval(40)) == nil,
       "ibs freshness: a battery voltage older than the 30-second window is not live")
expect(DPFState().freshBatteryStateOfChargePercent() == nil,
       "ibs freshness: absent sample stays unavailable")
var ibsBase = DPFState(timestamp: ibsAt)
ibsBase.batteryVoltage = 14.1 // ATRV: internal only, never shown in the card.
let ibsMerged = ibsBase.mergingFreshTelemetry(from: ibsFresh)
expect(ibsMerged.batteryStateOfChargePercent == 82
       && ibsMerged.batteryStateOfChargeSource == .ibsDirect
       && ibsMerged.batteryStateOfChargeUpdatedAt == ibsAt
       && ibsMerged.batterySystemVoltage == 12.8
       && ibsMerged.batterySystemVoltageUpdatedAt == ibsAt
       && ibsMerged.batteryVoltage == 14.1,
       "ibs merge: SOC and battery voltage propagate independently from ATRV")
let ibsEmpty = DPFState(timestamp: ibsAt.addingTimeInterval(1))
let ibsNoRefresh = ibsMerged.mergingFreshTelemetry(from: ibsEmpty)
expect(ibsNoRefresh.batteryStateOfChargePercent == 82,
       "ibs merge: a poll without a battery reply keeps the last good value")
expect(ibsFresh.hasTelemetry, "ibs state: a charge value alone is telemetry")

let liveBatteryPresentation = BatteryMetricPresentation.resolve(
    state: ibsMerged,
    isLive: true,
    at: ibsAt.addingTimeInterval(10)
)
expect(liveBatteryPresentation == .init(
    headline: .stateOfChargePercent(82),
    voltageDetail: 12.8
), "ibs presentation: live iPhone/CarPlay headline receives SOC with voltage detail")
for boundary in [0.0, 100.0] {
    var boundaryState = ibsMerged
    boundaryState.batteryStateOfChargePercent = boundary
    expect(BatteryMetricPresentation.resolve(
        state: boundaryState,
        isLive: true,
        at: ibsAt.addingTimeInterval(10)
    ).headline == .stateOfChargePercent(boundary),
           "ibs presentation: \(Int(boundary))% boundary reaches iPhone/CarPlay unchanged")
}
expect(BatteryMetricPresentation.resolve(
    state: ibsMerged,
    isLive: false,
    at: ibsAt.addingTimeInterval(10)
) == .init(headline: .voltage(12.8), voltageDetail: nil),
       "ibs presentation: cached telemetry hides SOC and shows the saved IBS voltage")
expect(BatteryMetricPresentation.resolve(
    state: ibsMerged,
    isLive: true,
    at: ibsAt.addingTimeInterval(31)
) == .init(headline: .unavailable, voltageDetail: nil),
       "ibs presentation: stale live IBS data never falls back to ATRV")
var ibsInvalidPresentation = ibsMerged
ibsInvalidPresentation.batteryStateOfChargePercent = .nan
expect(BatteryMetricPresentation.resolve(
    state: ibsInvalidPresentation,
    isLive: true,
    at: ibsAt.addingTimeInterval(10)
) == .init(headline: .voltage(12.8), voltageDetail: nil),
       "ibs presentation: non-finite SOC cannot reach the UI")
ibsInvalidPresentation.batteryStateOfChargePercent = -0.1
expect(BatteryMetricPresentation.resolve(
    state: ibsInvalidPresentation,
    isLive: true,
    at: ibsAt.addingTimeInterval(10)
) == .init(headline: .voltage(12.8), voltageDetail: nil),
       "ibs presentation: negative SOC cannot reach the UI")
ibsInvalidPresentation.batteryStateOfChargePercent = 100.1
expect(BatteryMetricPresentation.resolve(
    state: ibsInvalidPresentation,
    isLive: true,
    at: ibsAt.addingTimeInterval(10)
) == .init(headline: .voltage(12.8), voltageDetail: nil),
       "ibs presentation: SOC above 100 cannot reach the UI")
expect(BatteryMetricPresentation.resolve(
    state: DPFState(timestamp: ibsAt),
    isLive: true,
    at: ibsAt
) == .init(headline: .unavailable, voltageDetail: nil),
       "ibs presentation: absent or unsupported telemetry stays unavailable")
var adapterOnlyBatteryState = DPFState(timestamp: ibsAt)
adapterOnlyBatteryState.batteryVoltage = 14.4
expect(BatteryMetricPresentation.resolve(
    state: adapterOnlyBatteryState,
    isLive: true,
    at: ibsAt
) == .init(headline: .unavailable, voltageDetail: nil),
       "ibs presentation: ATRV is internal evidence and never appears as battery voltage")

// Old persisted snapshots without the new fields must still decode.
let legacySuiteName = "AlfaDPF.Tests.Legacy.\(UUID().uuidString)"
let legacyDefaults = UserDefaults(suiteName: legacySuiteName)!
legacyDefaults.set(Data("""
{"cloggingPercent":67,"exhaustTempC":412,"batteryVoltage":14.1,"timestamp":1750000000}
""".utf8), forKey: "lastRealDPFState.v1")
let legacyLoaded = DPFStateStore.load(from: legacyDefaults)
expect(legacyLoaded?.cloggingPercent == 67
       && legacyLoaded?.batteryVoltage == 14.1
       && legacyLoaded?.batteryStateOfChargePercent == nil,
       "ibs legacy: a snapshot written before IBS still decodes")
legacyDefaults.removePersistentDomain(forName: legacySuiteName)

expectThrows("decode: coolant requires two bytes") {
    _ = try DPFPID.coolantTemperatureC.decode(bytes: [0x19])
}
expectThrows("decode: coolant rejects implausible value") {
    _ = try DPFPID.coolantTemperatureC.decode(bytes: [0xFF, 0xFF])
}
expectThrows("decode: coolant rejects NaN") {
    _ = try CoolantTelemetryPolicy.validated(.nan)
}
let coolantReadAt = Date(timeIntervalSince1970: 2_000)
var lastGoodCoolant = DPFState(timestamp: coolantReadAt)
lastGoodCoolant.coolantTemperatureC = 88
let missingCoolant = DPFState(timestamp: coolantReadAt.addingTimeInterval(10))
expect(
    lastGoodCoolant.mergingFreshTelemetry(from: missingCoolant).coolantTemperatureC == 88,
    "coolant: transient missing sample retains the last valid value"
)
expect(
    !CoolantTelemetryPolicy.isExpired(
        lastValidSampleAt: coolantReadAt,
        now: coolantReadAt.addingTimeInterval(29.9)
    ),
    "coolant: last valid value survives inside 30-second TTL"
)
expect(
    CoolantTelemetryPolicy.isExpired(
        lastValidSampleAt: coolantReadAt,
        now: coolantReadAt.addingTimeInterval(30)
    ),
    "coolant: stale live value expires after 30 seconds"
)

let migratedCoolant = DashboardMetricPreference.load(
    stored: [DashboardMetric.exhaustTemperature.rawValue],
    migrated: false,
    adding: .coolantTemperature
)
expect(
    migratedCoolant.visible.contains(.coolantTemperature) && migratedCoolant.didMigrate,
    "dashboard: existing users receive coolant card once"
)
let optedOutCoolant = DashboardMetricPreference.load(
    stored: [DashboardMetric.exhaustTemperature.rawValue],
    migrated: true,
    adding: .coolantTemperature
)
expect(
    !optedOutCoolant.visible.contains(.coolantTemperature) && !optedOutCoolant.didMigrate,
    "dashboard: manual coolant opt-out survives later launches"
)

do {
    let monitorSource = try String(contentsOfFile: "Sources/DPFMonitor.swift", encoding: .utf8)
    let appSource = try String(contentsOfFile: "Sources/AlfaDPFApp.swift", encoding: .utf8)
    let criticalPublish = monitorSource.range(of: "snapshot = DPFMonitorSnapshot(")
    let coolantRead = monitorSource.range(of: "read(.coolantTemperatureC)")
    let slots = (0..<12).map { DPFSecondaryPollSlot.resolve(sequence: UInt64($0)) }
    expect(
        slots.filter { $0 == .coolantTemperature }.count == 2
            && slots.filter { $0 == .batteryIBS }.count == 2
            && slots[5] == .batteryIBS
            && monitorSource.contains("switch DPFSecondaryPollSlot.resolve(sequence: cadenceSequence)")
            && monitorSource.contains("readBatteryTelemetry()")
            && monitorSource.contains("read(.coolantTemperatureC)")
            && !monitorSource.contains("\"0105\"")
            && criticalPublish.map { published in
                coolantRead.map { published.lowerBound < $0.lowerBound } ?? false
            } == true,
        "secondary cadence: coolant and IBS each occupy one reachable six-slot branch after critical publication"
    )
    expect(
        appSource.contains("title: \"LIQUIDO MOTORE\"")
            && appSource.contains("unit: \"°C\"")
            && appSource.contains("dpf.coolantTemperatureC"),
        "coolant UI: vehicle-data card uses Celsius and optional fallback"
    )
} catch {
    failures += 1
    print("FAIL: coolant source regression — \(error)")
}

// MARK: - Last real DPF snapshot

let snapshotSuite = "AlfaDPF.Tests.\(UUID().uuidString)"
let snapshotDefaults = UserDefaults(suiteName: snapshotSuite)!
let savedAt = Date(timeIntervalSince1970: 1_750_000_000)
let savedSnapshot = DPFState(
    cloggingPercent: 67,
    exhaustTempC: 412,
    coolantTemperatureC: 88,
    distanceSinceLastRegenKm: 238,
    regenProgressPercent: 0,
    totalRegenCount: 304,
    regenActive: false,
    batteryVoltage: 14.1,
    timestamp: savedAt
)
DPFStateStore.save(savedSnapshot, to: snapshotDefaults)
expect(
    DPFStateStore.load(from: snapshotDefaults) == savedSnapshot,
    "snapshot: last real telemetry survives relaunch"
)
DPFStateStore.save(DPFState(timestamp: savedAt), to: snapshotDefaults)
expect(
    DPFStateStore.load(from: snapshotDefaults) == savedSnapshot,
    "snapshot: empty telemetry never overwrites last values"
)
var derivedOnly = DPFState(timestamp: savedAt.addingTimeInterval(1))
derivedOnly.regenActive = false
DPFStateStore.save(derivedOnly, to: snapshotDefaults)
expect(
    !derivedOnly.hasTelemetry && DPFStateStore.load(from: snapshotDefaults) == savedSnapshot,
    "snapshot: derived idle state cannot erase real ECU values"
)

let partialAt = savedAt.addingTimeInterval(10)
let partialSnapshot = DPFState(
    cloggingPercent: 0,
    cloggingRaw: 0,
    cloggingECUHeader: "18DA10F1",
    cloggingSourceVerified: true,
    timestamp: partialAt
)
let mergedSnapshot = savedSnapshot.mergingFreshTelemetry(from: partialSnapshot)
expect(
    mergedSnapshot.cloggingPercent == 0
        && mergedSnapshot.cloggingRaw == 0
        && mergedSnapshot.cloggingECUHeader == "18DA10F1"
        && mergedSnapshot.cloggingSourceVerified == true
        && mergedSnapshot.exhaustTempC == savedSnapshot.exhaustTempC
        && mergedSnapshot.distanceSinceLastRegenKm == savedSnapshot.distanceSinceLastRegenKm
        && mergedSnapshot.timestamp == partialAt,
    "snapshot: a real zero updates only its field and preserves other last-good values"
)
let failedPoll = DPFState(timestamp: partialAt.addingTimeInterval(10))
expect(
    mergedSnapshot.mergingFreshTelemetry(from: failedPoll) == mergedSnapshot,
    "snapshot: failed poll cannot replace last-good values or freshness timestamp"
)
var newSignals = DPFState(timestamp: partialAt.addingTimeInterval(20))
newSignals.regenerationMode = .passive
newSignals.oilPressureStatusRaw = 2
newSignals.exhaustTempC = 601
newSignals.coolantTemperatureC = 92
newSignals.exhaustTemperaturePID = DPFPID.postDPFTempC.rawValue
let mergedNewSignals = mergedSnapshot.mergingFreshTelemetry(from: newSignals)
expect(
    mergedNewSignals.effectiveRegenerationMode == .passive
        && mergedNewSignals.isRegenerating
        && mergedNewSignals.oilPressureStatusText == "Normale"
        && mergedNewSignals.batteryVoltage == savedSnapshot.batteryVoltage
        && mergedNewSignals.coolantTemperatureC == 92
        && mergedNewSignals.exhaustTemperaturePID == DPFPID.postDPFTempC.rawValue,
    "snapshot: passive regen, oil state and temperature source merge safely"
)
var conflictingSignals = mergedNewSignals
conflictingSignals.regenActive = true
expect(
    conflictingSignals.effectiveRegenerationMode == .active,
    "snapshot: established active evidence wins over a conflicting optional mode"
)
snapshotDefaults.removePersistentDomain(forName: snapshotSuite)

// MARK: - Regen event tracking

let idleAt = Date(timeIntervalSince1970: 1_000)
let startedAt = idleAt.addingTimeInterval(5)
let finishedAt = startedAt.addingTimeInterval(12 * 60)
var tracker = RegenActivityTracker()

expect(
    tracker.observe(progressPercent: 0, at: idleAt, cloggingPercent: 72) == nil &&
    tracker.isActive == false,
    "regen tracker: idle baseline"
)
expect(
    tracker.observe(progressPercent: 0.2, at: startedAt, cloggingPercent: 72)
        == .started(at: startedAt, cloggingPercent: 72),
    "regen tracker: idle to active emits start"
)
expect(
    tracker.observe(progressPercent: nil,
                    at: startedAt.addingTimeInterval(3),
                    cloggingPercent: nil) == nil &&
    tracker.isActive == true,
    "regen tracker: missing sample preserves active state"
)
expect(
    tracker.observe(progressPercent: 18,
                    at: startedAt.addingTimeInterval(30),
                    cloggingPercent: 70) == nil,
    "regen tracker: active sample does not duplicate start"
)
expect(
    tracker.observe(progressPercent: 0, at: finishedAt, cloggingPercent: 31)
        == .finished(at: finishedAt, duration: 12 * 60),
    "regen tracker: active to idle emits finish"
)

var connectedMidRegen = RegenActivityTracker()
expect(
    connectedMidRegen.observe(progressPercent: 35,
                              at: startedAt,
                              cloggingPercent: 65)
        == .started(at: startedAt, cloggingPercent: 65),
    "regen tracker: first active sample still warns"
)

var modeTracker = RegenActivityTracker()
expect(
    modeTracker.observe(
        progressPercent: 0,
        at: idleAt,
        cloggingPercent: 70,
        regenerationMode: .passive
    ) == nil && modeTracker.isActive == false,
    "regen mode: passive is visible but does not emit an active-regeneration alert"
)
expect(
    modeTracker.observe(
        progressPercent: 0,
        at: startedAt,
        cloggingPercent: 70,
        regenerationMode: .active
    ) == .started(at: startedAt, cloggingPercent: 70),
    "regen mode: dedicated active state emits start"
)
expect(
    modeTracker.observe(
        progressPercent: 0,
        at: finishedAt,
        cloggingPercent: 60,
        regenerationMode: .passive
    ) == .finished(at: finishedAt, duration: 12 * 60),
    "regen mode: active to passive emits active-regeneration finish"
)

var fallbackWinsTracker = RegenActivityTracker()
expect(
    fallbackWinsTracker.observe(
        progressPercent: 2,
        at: startedAt,
        cloggingPercent: 70,
        regenerationMode: DPFRegenerationMode.none
    ) == .started(at: startedAt, cloggingPercent: 70),
    "regen mode: ECU idle state cannot suppress established progress evidence"
)

// Some FCA ECUs return a permanently-zero regeneration progress PID. In
// that case a high exhaust temperature plus a sustained soot-load drop must
// still create stable start/end edges for notifications and CarPlay.
let inferredAt = Date(timeIntervalSince1970: 2_000)
var inferredTracker = RegenActivityTracker()
expect(
    inferredTracker.observe(progressPercent: 0,
                            at: inferredAt,
                            cloggingPercent: 92.0,
                            exhaustTemperatureC: 565) == nil,
    "regen fallback: hot baseline alone is not enough"
)
expect(
    inferredTracker.observe(progressPercent: 0,
                            at: inferredAt.addingTimeInterval(5),
                            cloggingPercent: 91.6,
                            exhaustTemperatureC: 580) == nil,
    "regen fallback: first decline remains a candidate"
)
expect(
    inferredTracker.observe(progressPercent: nil,
                            at: inferredAt.addingTimeInterval(7),
                            cloggingPercent: nil,
                            exhaustTemperatureC: nil) == nil &&
    inferredTracker.observe(progressPercent: 0,
                            at: inferredAt.addingTimeInterval(10),
                            cloggingPercent: 91.2,
                            exhaustTemperatureC: 590) == nil,
    "regen fallback: missing sample preserves sustained decline"
)
expect(
    inferredTracker.observe(progressPercent: 0,
                            at: inferredAt.addingTimeInterval(15),
                            cloggingPercent: 90.8,
                            exhaustTemperatureC: 600)
        == .started(at: inferredAt, cloggingPercent: 90.8) &&
    inferredTracker.isActive == true,
    "regen fallback: hot sustained load drop emits start"
)
expect(
    inferredTracker.observe(progressPercent: 0,
                            at: inferredAt.addingTimeInterval(20),
                            cloggingPercent: 90.3,
                            exhaustTemperatureC: 610) == nil &&
    inferredTracker.isActive == true,
    "regen fallback: zero progress PID does not end inferred burn"
)
expect(
    inferredTracker.observe(progressPercent: 0,
                            at: inferredAt.addingTimeInterval(25),
                            cloggingPercent: 90.2,
                            exhaustTemperatureC: 440) == nil &&
    inferredTracker.observe(progressPercent: 0,
                            at: inferredAt.addingTimeInterval(30),
                            cloggingPercent: 90.2,
                            exhaustTemperatureC: 430) == nil,
    "regen fallback: waits for a stable cool-down"
)
expect(
    inferredTracker.observe(progressPercent: 0,
                            at: inferredAt.addingTimeInterval(35),
                            cloggingPercent: 90.2,
                            exhaustTemperatureC: 420)
        == .finished(at: inferredAt.addingTimeInterval(35), duration: 35) &&
    inferredTracker.isActive == false,
    "regen fallback: cool-down emits finish"
)

var hotButStableTracker = RegenActivityTracker()
for offset in stride(from: 0.0, through: 30.0, by: 5.0) {
    _ = hotButStableTracker.observe(
        progressPercent: 0,
        at: inferredAt.addingTimeInterval(offset),
        cloggingPercent: 75,
        exhaustTemperatureC: 620
    )
}
expect(
    hotButStableTracker.isActive == false,
    "regen fallback: high temperature without load drop stays idle"
)

var postRegenTailTracker = RegenActivityTracker()
for (offset, load) in [21.1, 20.8, 20.4, 20.0].enumerated() {
    _ = postRegenTailTracker.observe(
        progressPercent: 0,
        at: inferredAt.addingTimeInterval(Double(offset) * 5),
        cloggingPercent: load,
        exhaustTemperatureC: 615
    )
}
expect(
    postRegenTailTracker.isActive == false,
    "regen fallback: hot post-regeneration tail cannot create a second start"
)

// MARK: - Delayed regeneration-finish notification

let delayedFinishStartedAt = Date(timeIntervalSince1970: 3_000)
let delayedFinishEndedAt = delayedFinishStartedAt.addingTimeInterval(11 * 60)
let delayedStartEvent = RegenEvent.started(
    at: delayedFinishStartedAt,
    cloggingPercent: 91
)
let delayedFinishEvent = RegenEvent.finished(
    at: delayedFinishEndedAt,
    duration: 11 * 60
)

var delayedFinishGate = RegenFinishNotificationGate()
expect(
    delayedFinishGate.observe(delayedStartEvent) == delayedStartEvent,
    "regen finish gate: start notifications remain immediate"
)
expect(
    delayedFinishGate.observe(
        delayedFinishEvent,
        distanceBeforeFinishRaw: 2_300
    ) == nil
        && delayedFinishGate.isWaitingForDistanceReset,
    "regen finish gate: falling load stages finish with the pre-reset distance"
)
expect(
    delayedFinishGate.confirm(freshDistanceRaw: 27) == nil
        && delayedFinishGate.isWaitingForDistanceReset,
    "regen finish gate: nonzero distance cannot release finish"
)
expect(
    delayedFinishGate.isWaitingForDistanceReset,
    "regen finish gate: missing distance keeps finish pending without notifying"
)
expect(
    delayedFinishGate.confirm(freshDistanceRaw: 0x01_00_00_00) == nil
        && delayedFinishGate.isWaitingForDistanceReset,
    "regen finish gate: invalid UInt24 distance cannot release finish"
)
expect(
    delayedFinishGate.confirm(freshDistanceRaw: 1) == delayedFinishEvent
        && !delayedFinishGate.isWaitingForDistanceReset,
    "regen finish gate: first plausible post-reset sample releases even when zero was skipped"
)
expect(
    delayedFinishGate.confirm(freshDistanceRaw: 0) == nil
        && delayedFinishGate.confirm(freshDistanceRaw: 1) == nil,
    "regen finish gate: later reset-range updates never duplicate the notification"
)

var reorderedFinishGate = RegenFinishNotificationGate()
expect(
    reorderedFinishGate.confirm(freshDistanceRaw: 0) == nil,
    "regen finish gate: zero received before the finish edge is ignored"
)
expect(
    reorderedFinishGate.observe(
        delayedFinishEvent,
        distanceBeforeFinishRaw: 8
    ) == nil
        && reorderedFinishGate.confirm(freshDistanceRaw: 8) == nil
        && reorderedFinishGate.isWaitingForDistanceReset,
    "regen finish gate: a small value that did not decrease cannot notify prematurely"
)
expect(
    reorderedFinishGate.confirm(freshDistanceRaw: 0) == delayedFinishEvent
        && reorderedFinishGate.confirm(freshDistanceRaw: 0) == nil,
    "regen finish gate: a fresh post-edge zero releases exactly once"
)

var resetFinishGate = RegenFinishNotificationGate()
_ = resetFinishGate.observe(delayedFinishEvent)
resetFinishGate.reset()
expect(
    resetFinishGate.confirm(freshDistanceRaw: 0) == nil
        && !resetFinishGate.isWaitingForDistanceReset,
    "regen finish gate: reset cancels a pending finish"
)

// MARK: - Test Lab scenarios

let simulatedStart = DPFSimulationScenario.regenStarted.state(at: startedAt)
let simulatedEnd = DPFSimulationScenario.regenFinished.state(at: finishedAt)
var simulationTracker = RegenActivityTracker()
let simulatedStartEvent = simulationTracker.observe(
    progressPercent: simulatedStart.regenProgressPercent,
    at: simulatedStart.timestamp,
    cloggingPercent: simulatedStart.cloggingPercent
)
let simulatedEndEvent = simulationTracker.observe(
    progressPercent: simulatedEnd.regenProgressPercent,
    at: simulatedEnd.timestamp,
    cloggingPercent: simulatedEnd.cloggingPercent
)
expect(
    simulatedStartEvent == .started(at: startedAt, cloggingPercent: 96),
    "simulation: start scenario emits real start edge"
)
expect(
    simulatedEndEvent == .finished(at: finishedAt, duration: 12 * 60),
    "simulation: finish scenario emits real finish edge"
)
expect(
    DPFSimulationScenario.clean.state().cloggingPercent == 28 &&
    DPFSimulationScenario.clean.state().coolantTemperatureC == 88 &&
    DPFSimulationScenario.unavailable.state().cloggingPercent == nil &&
    DPFSimulationScenario.unavailable.state().coolantTemperatureC == nil,
    "simulation: clean and unavailable fixtures"
)

// MARK: - Mode 01 parser (not used by the live DPF session)

expectBytes("mode01: 11-bit header, no spaces",
            { try Mode01Reader.parseMode01("7E804410C1AF8", expectedPID: 0x0C) },
            prefix: [0x1A, 0xF8])

expectBytes("mode01: no header",
            { try Mode01Reader.parseMode01("410C1AF8", expectedPID: 0x0C) },
            prefix: [0x1A, 0xF8])

expectBytes("mode01: spaces",
            { try Mode01Reader.parseMode01("41 0C 1A F8", expectedPID: 0x0C) },
            prefix: [0x1A, 0xF8])

expectBytes("mode01: SEARCHING... line skipped",
            { try Mode01Reader.parseMode01("SEARCHING...\r\n7E804410C1AF8", expectedPID: 0x0C) },
            prefix: [0x1A, 0xF8])

expectBytes("mode01: coolant with header",
            { try Mode01Reader.parseMode01("7E803410578", expectedPID: 0x05) },
            prefix: [0x78])

// 29-bit single + multi-ECU frames as seen live on the Stelvio.
expectBytes("mode01: 29-bit header (Stelvio)",
            { try Mode01Reader.parseMode01("18DAF11004410C0C86", expectedPID: 0x0C) },
            prefix: [0x0C, 0x86])

expectBytes("mode01: 29-bit multi-ECU, first ECU wins",
            { try Mode01Reader.parseMode01("18DAF11004410C0C86\r18DAF10104410C0C86\r18DAF11804410C0C78", expectedPID: 0x0C) },
            prefix: [0x0C, 0x86])

expectThrows("mode01: NO DATA throws") {
    _ = try Mode01Reader.parseMode01("NO DATA", expectedPID: 0x0C)
}

do {
    let rpm = try Mode01Reader.decodeRPM([0x1A, 0xF8])
    expect(rpm == 1726.0, "decode: rpm 1726")
} catch {
    failures += 1
    print("FAIL: rpm decode threw \(error)")
}

do {
    expect(try Mode01Reader.decodeCoolant([0x80]) == 88,
           "decode: coolant 88 C")
    expect(try Mode01Reader.decodePressureKPa([0x96]) == 150,
           "decode: pressure 150 kPa")
    expect(Mode01Reader.turboBoostBar(
        manifoldAbsoluteKPa: 180,
        barometricKPa: 98
    ) == 0.82, "decode: turbo uses MAP minus barometric pressure")
    expect(Mode01Reader.turboBoostBar(
        manifoldAbsoluteKPa: 80,
        barometricKPa: 98
    ) == 0, "decode: turbo vacuum clamps to zero")
    expect(Mode01Reader.turboBoostBar(
        manifoldAbsoluteKPa: 100,
        barometricKPa: 0
    ) == nil, "decode: invalid barometric pressure is unavailable")
    expect(Mode01Reader.functionalRequestHeader(forPhysicalHeader: "7E0") == "7DF",
           "mode01: 11-bit physical header maps to functional header")
    expect(Mode01Reader.functionalRequestHeader(forPhysicalHeader: "18da10f1") == "18DB33F1",
           "mode01: 29-bit physical header maps to functional header")
    expect(Mode01Reader.functionalRequestHeader(forPhysicalHeader: "ABCDEF") == nil,
           "mode01: unknown header format is rejected")
} catch {
    failures += 1
    print("FAIL: engine telemetry decode threw \(error)")
}

// MARK: - BLE characteristic picking

// MARK: - Transport settings

expect(OBDTransportKind.load(from: UserDefaults(suiteName: UUID().uuidString)!) == .bluetooth,
       "transport: Bluetooth remains the default")
expect(WiFiAdapterEndpoint.parse(host: " 192.168.0.10 ", port: "35000")
        == .init(host: "192.168.0.10", port: 35000),
       "transport: Wi-Fi endpoint trims and parses")
expect(WiFiAdapterEndpoint.parse(host: "192.168.0.10", port: "0") == nil,
       "transport: Wi-Fi port zero is rejected")
expect(WiFiAdapterEndpoint.parse(host: "http://192.168.0.10", port: "35000") == nil,
       "transport: Wi-Fi endpoint rejects URL syntax")
expect(WiFiAdapterEndpoint.parse(host: "192.168.0.10/path", port: "35000") == nil,
       "transport: Wi-Fi endpoint rejects paths")

expect(ELM327.isAcceptedATResponse("OK"), "init: accepts OK")
expect(ELM327.isAcceptedATResponse("ELM327 v1.5"), "init: accepts version banner")
expect(!ELM327.isAcceptedATResponse("?"), "init: rejects unsupported AT command")
expect(!ELM327.isAcceptedATResponse("UNABLE TO CONNECT"),
       "init: rejects failed adapter response")

expect(ELMLineEngine.isSuccessfulATResponse("OK\r"),
       "header: accepts explicit OK")
expect(!ELMLineEngine.isSuccessfulATResponse("?"),
       "header: rejects unsupported command")
expect(!ELMLineEngine.isSuccessfulATResponse("NO DATA"),
       "header: rejects non-acknowledgement")
expect(!ELMLineEngine.isSuccessfulATResponse("ERROR\rOK"),
       "header: mixed error and OK is rejected")

let validInitialization = InitializationTestTransport(.valid)
do {
    _ = try await ELM327(connection: validInitialization).initializeSession()
    let commands = await validInitialization.commands()
    expect(!commands.contains(where: { $0.command.hasPrefix("01") }),
           "init: live bootstrap never sends Mode 01")
    expect(commands.contains(.init(command: "22380B", header: "18DA10F1")),
           "init: protocol search uses a DPF Mode 22 probe")
} catch {
    failures += 1
    print("FAIL: init: valid DPF-only bootstrap threw \(error)")
}

let rejectingInitialization = InitializationTestTransport(.rejectsEverything)
do {
    _ = try await ELM327(connection: rejectingInitialization).initializeSession()
    failures += 1
    print("FAIL: init: adapter rejecting every command was accepted")
} catch {
    print("PASS: init: adapter rejecting every command is rejected")
}

let legacyInitialization = InitializationTestTransport(.resetTimeoutThenLegacy)
do {
    _ = try await ELM327(connection: legacyInitialization).initializeSession()
    let commands = await legacyInitialization.commands()
    expect(commands.contains(where: { $0.command == "ATI" })
           && commands.contains(where: { $0.command == "22380B" }),
           "init: timed-out ATZ falls back to ATI and a DPF-only protocol probe")
} catch {
    failures += 1
    print("FAIL: init: legacy reset fallback threw \(error)")
}

// MARK: - Cached protocol fast path

/// Small mutable counter captured by a scripted transport to answer the first
/// probe differently from later ones (e.g. NO DATA then success).
final class TestCounter {
    var value = 0
}

/// Recorded, scripted OBD transport used to drive `ELM327.initializeSession`
/// through the cached/fallback/auto paths and to assert the exact command
/// sequence it sends.
actor ScriptedTestTransport: OBDTransport {
    struct Command: Equatable {
        var command: String
        var header: String?
    }

    private let identifier: String
    private let script: (Command) async throws -> String
    private var sent: [Command] = []

    init(identifier: String = "scripted:test",
         script: @escaping (Command) async throws -> String) {
        self.identifier = identifier
        self.script = script
    }

    func start() {}
    func stop() async {}
    func isReady() async throws {}
    func cacheIdentifier() -> String? { identifier }

    func send(_ command: String,
              header: String?,
              timeout: TimeInterval) async throws -> String {
        let entry = Command(command: command, header: header)
        sent.append(entry)
        return try await script(entry)
    }

    func commands() -> [Command] { sent }
}

func probeCount(_ commands: [ScriptedTestTransport.Command]) -> Int {
    commands.filter { $0.command == "22380B" }.count
}

expect(ELM327.parseProtocol(from: "A7") == 7,
       "protocol: parses auto-negotiated A7")
expect(ELM327.parseProtocol(from: "7") == 7,
       "protocol: parses bare number")
expect(ELM327.parseProtocol(from: "A6") == 6,
       "protocol: parses auto-negotiated A6")
expect(ELM327.parseProtocol(from: "  A7 ") == 7,
       "protocol: trims whitespace")
expect(ELM327.parseProtocol(from: "ATDPN\rA7") == 7,
       "protocol: skips echoed command line")
expect(ELM327.parseProtocol(from: "A0") == nil,
       "protocol: automatic marker is not cacheable")
expect(ELM327.parseProtocol(from: "0") == nil,
       "protocol: bare zero is not cacheable")
expect(ELM327.parseProtocol(from: "ISO 15765-4 (CAN 29/500)") == nil,
       "protocol: description is not cacheable")
expect(ELM327.parseProtocol(from: "?") == nil,
       "protocol: error reply is rejected")
expect(ELM327.parseProtocol(from: "") == nil,
       "protocol: empty reply is rejected")

expect(ELM327.isECUProvenDiagnosticProbe("18DAF110 06 62 38 0B 00 00"),
       "probe: positive 62 proves an ECU answered")
expect(ELM327.isECUProvenDiagnosticProbe("7F 22 31"),
       "probe: negative 7F22 proves an ECU answered")
expect(!ELM327.isECUProvenDiagnosticProbe("NO DATA"),
       "probe: NO DATA does not prove the protocol")
expect(!ELM327.isECUProvenDiagnosticProbe("?"),
       "probe: unsupported command is not ECU proof")

let protocolCacheSuite = "AlfaDPFTests.ProtocolCache.\(UUID().uuidString)"
let protocolCacheDefaults = UserDefaults(suiteName: protocolCacheSuite)!
let protocolCache = OBDProtocolCache(
    identifier: "ble:test-adapter",
    defaults: protocolCacheDefaults
)
expect(protocolCache.load() == nil,
       "protocol cache: empty for a new adapter")
protocolCache.save(7)
expect(protocolCache.load() == 7,
       "protocol cache: round-trips a normalized protocol")
protocolCache.save(9)
expect(protocolCache.load() == 9,
       "protocol cache: updates when the protocol renegotiates")
expect(OBDProtocolCache(identifier: "ble:other", defaults: protocolCacheDefaults).load() == nil,
       "protocol cache: does not leak to another adapter")
let invalidProtocolCache = OBDProtocolCache(
    identifier: "ble:invalid",
    defaults: protocolCacheDefaults
)
invalidProtocolCache.save(0)
invalidProtocolCache.save(12)
expect(invalidProtocolCache.load() == nil,
       "protocol cache: out-of-range values are rejected")
protocolCacheDefaults.removePersistentDomain(forName: protocolCacheSuite)

do {
    let transport = ScriptedTestTransport { command in
        if command.command == "ATZ" { return "ELM327 v1.5" }
        if command.command == "ATDPN" { return "A7" }
        if command.command == "22380B" { return "18DAF110 06 62 38 0B 00 00" }
        return "OK"
    }
    let negotiated = try await ELM327(connection: transport)
        .initializeSession(cachedProtocol: 7)
    let commands = await transport.commands()
    expect(commands.contains(.init(command: "ATSP7", header: nil)),
           "fast path: cached protocol is forced with ATSP7")
    expect(!commands.contains(where: { $0.command == "ATSP0" }),
           "fast path: automatic search is skipped on cache hit")
    expect(probeCount(commands) == 1,
           "fast path: exactly one probe on cache hit")
    expect(negotiated == 7,
           "fast path: negotiated protocol is returned for persistence")
} catch {
    failures += 1
    print("FAIL: fast path cache hit threw \(error)")
}

do {
    let transport = ScriptedTestTransport { command in
        if command.command == "ATZ" { return "ELM327 v1.5" }
        if command.command == "ATDPN" { return "A7" }
        if command.command == "22380B" { return "7F 22 31" }
        return "OK"
    }
    _ = try await ELM327(connection: transport)
        .initializeSession(cachedProtocol: 7)
    let commands = await transport.commands()
    expect(commands.contains(.init(command: "ATSP7", header: nil)),
           "fast path: 7F22 negative response keeps the cached protocol")
    expect(!commands.contains(where: { $0.command == "ATSP0" }),
           "fast path: no ATSP0 when an ECU answered negatively")
} catch {
    failures += 1
    print("FAIL: 7F22 fast path threw \(error)")
}

do {
    let transport = ScriptedTestTransport { command in
        if command.command == "ATZ" { return "ELM327 v1.5" }
        if command.command == "ATDPN" { return "A7" }
        if command.command == "22380B" { return "18DAF101 06 62 38 0B 00 00" }
        return "OK"
    }
    _ = try await ELM327(connection: transport)
        .initializeSession(cachedProtocol: 7, probeHeader: "18DA01F1")
    let commands = await transport.commands()
    expect(commands.contains(.init(command: "22380B", header: "18DA01F1")),
           "fast path: remembered ECU route is used for the probe")
} catch {
    failures += 1
    print("FAIL: remembered probe header threw \(error)")
}

do {
    let counter = TestCounter()
    let transport = ScriptedTestTransport { command in
        if command.command == "ATZ" { return "ELM327 v1.5" }
        if command.command == "ATDPN" { return "A7" }
        if command.command == "22380B" {
            counter.value += 1
            return counter.value == 1 ? "NO DATA" : "18DAF110 06 62 38 0B 00 00"
        }
        return "OK"
    }
    let negotiated = try await ELM327(connection: transport)
        .initializeSession(cachedProtocol: 7)
    let commands = await transport.commands()
    expect(commands.contains(.init(command: "ATSP7", header: nil)),
           "fallback: cached protocol is attempted first")
    expect(commands.contains(.init(command: "ATSP0", header: nil)),
           "fallback: NO DATA on the fast path triggers ATSP0")
    expect(probeCount(commands) == 2,
           "fallback: exactly one extra probe after ATSP0")
    let sp7 = commands.firstIndex { $0.command == "ATSP7" }
    let sp0 = commands.firstIndex { $0.command == "ATSP0" }
    let probe2 = commands.lastIndex { $0.command == "22380B" }
    expect(sp7 != nil && sp0 != nil && probe2 != nil
           && sp0! > sp7!
           && probe2! > sp0!,
           "fallback: ATSP0 probe runs after the failed cached probe")
    expect(negotiated == 7,
           "fallback: negotiated protocol is still returned")
} catch {
    failures += 1
    print("FAIL: NO DATA fallback threw \(error)")
}

do {
    let transport = ScriptedTestTransport { command in
        if command.command == "ATZ" { return "ELM327 v1.5" }
        if command.command == "ATSP7" { return "?" }
        if command.command == "ATDPN" { return "A7" }
        if command.command == "22380B" { return "18DAF110 06 62 38 0B 00 00" }
        return "OK"
    }
    _ = try await ELM327(connection: transport)
        .initializeSession(cachedProtocol: 7)
    let commands = await transport.commands()
    expect(commands.contains(.init(command: "ATSP0", header: nil)),
           "fallback: rejected ATSPx falls back to ATSP0")
} catch {
    failures += 1
    print("FAIL: rejected cached ATSP threw \(error)")
}

do {
    let transport = ScriptedTestTransport { command in
        if command.command == "ATZ" { return "ELM327 v1.5" }
        if command.command == "ATDPN" { return "A7" }
        if command.command == "22380B" { return "NO DATA" }
        return "OK"
    }
    _ = try await ELM327(connection: transport).initializeSession()
    let commands = await transport.commands()
    expect(commands.contains(.init(command: "ATSP0", header: nil)),
           "baseline: no cache keeps ATSP0 automatic search")
    expect(!commands.contains(where: { $0.command.hasPrefix("ATSP") && $0.command != "ATSP0" }),
           "baseline: no forced protocol without a cache")
    expect(probeCount(commands) == 1,
           "baseline: single probe with NO DATA is still accepted")
} catch {
    failures += 1
    print("FAIL: baseline auto bootstrap threw \(error)")
}

do {
    let transport = ScriptedTestTransport { command in
        if command.command == "ATZ" { return "ELM327 v1.5" }
        if command.command == "22380B" { return "?" }
        return "OK"
    }
    _ = try await ELM327(connection: transport)
        .initializeSession(cachedProtocol: 7)
    failures += 1
    print("FAIL: rejecting probe on fast path and fallback was accepted")
} catch {
    print("PASS: rejecting probe on fast path and fallback is terminal")
}

do {
    let transport = ScriptedTestTransport { command in
        if command.command == "ATZ" { return "ELM327 v1.5" }
        if command.command == "22380B" { throw OBDError.timeout }
        return "OK"
    }
    _ = try await ELM327(connection: transport)
        .initializeSession(cachedProtocol: 7)
    failures += 1
    print("FAIL: silent probe on fast path and fallback was accepted")
} catch {
    print("PASS: silent probe on fast path and fallback is terminal")
}

// MARK: - Connection timing benchmark (deterministic simulation)

// Phase costs measured on the slow real adapter (ELM327 v2.3, historical log
// 2026-08-05, connection_baselines.json): the automatic protocol search after
// ATSP0 cost 5.564 s of the 7.569 s to running (73.5%). The benchmark runs
// both bootstraps against the same scripted adapter model and measures the
// wall-clock saving — a comparable projection, not hardware measurement.
func makeTimedTransport(probeDelay: TimeInterval,
                        probeReply: String) -> ScriptedTestTransport {
    ScriptedTestTransport { command in
        switch command.command {
        case "ATZ":
            try await Task.sleep(for: .seconds(0.962))
            return "ELM327 v2.3"
        case "ATE0", "ATL0", "ATS0", "ATH1", "ATAT1":
            try await Task.sleep(for: .seconds(0.036))
            return "OK"
        case "ATSP0":
            try await Task.sleep(for: .seconds(0.010))
            return "OK"
        case "ATSP7":
            try await Task.sleep(for: .seconds(0.030))
            return "OK"
        case "22380B":
            try await Task.sleep(for: .seconds(probeDelay))
            return probeReply
        case "ATDPN":
            try await Task.sleep(for: .seconds(0.031))
            return "A7"
        default:
            return "OK"
        }
    }
}

do {
    let autoTransport = makeTimedTransport(
        probeDelay: 5.564, probeReply: "NO DATA"
    )
    let cachedTransport = makeTimedTransport(
        probeDelay: 0.25, probeReply: "18DAF110 06 62 38 0B 00 00"
    )

    let autoStart = Date()
    _ = try await ELM327(connection: autoTransport).initializeSession()
    let autoInit = Date().timeIntervalSince(autoStart)

    let cachedStart = Date()
    _ = try await ELM327(connection: cachedTransport)
        .initializeSession(cachedProtocol: 7)
    let cachedInit = Date().timeIntervalSince(cachedStart)

    let saving = autoInit - cachedInit
    print(String(
        format: "TIMING: ATSP0 init %.2f s vs cached ATSP7 init %.2f s — saving %.2f s (%.0f%%)",
        autoInit, cachedInit, saving, saving / autoInit * 100
    ))
    expect(cachedInit < autoInit,
           "timing: cached protocol path is faster than ATSP0")
    expect(cachedInit < autoInit * 0.5,
           "timing: cached path completes in under half the ATSP0 time")
    expect(saving > 4.5,
           "timing: saving exceeds 4.5 s (baseline automatic search was 5.564 s)")
} catch {
    failures += 1
    print("FAIL: timing benchmark threw \(error)")
}

typealias BLECandidate = BLECharacteristicPicker.Candidate
let svcVlink = CBUUID(string: "FFF0")
let chrNotifyVlink = CBUUID(string: "FFF1")
let chrWriteVlink = CBUUID(string: "FFF2")
let svcOther = CBUUID(string: "ABC0")
let chrOther1 = CBUUID(string: "ABC1")
let chrOther2 = CBUUID(string: "ABC2")
let svcKonnwei = CBUUID(string: "FFE0")
let chrKonnweiData = CBUUID(string: "FFE1")

let bleProfileSuite = "AlfaDPFTests.BLEGATTProfile.\(UUID().uuidString)"
let bleProfileDefaults = UserDefaults(suiteName: bleProfileSuite)!
let bleProfilePeripheralID = UUID()
let rememberedGATT = BLEGATTProfile(service: "FFF0", notify: "FFF1", write: "FFF2")
BLEGATTProfileCache.save(
    rememberedGATT,
    peripheralID: bleProfilePeripheralID,
    to: bleProfileDefaults
)
expect(
    BLEGATTProfileCache.load(
        peripheralID: bleProfilePeripheralID,
        from: bleProfileDefaults
    ) == rememberedGATT,
    "ble: validated GATT route persists per peripheral"
)
expect(
    BLEGATTProfileCache.load(peripheralID: UUID(), from: bleProfileDefaults) == nil,
    "ble: GATT route does not leak to another peripheral"
)
bleProfileDefaults.removePersistentDomain(forName: bleProfileSuite)

let ecuProfileSuite = "AlfaDPFTests.ECUProfile.\(UUID().uuidString)"
let ecuProfileDefaults = UserDefaults(suiteName: ecuProfileSuite)!
let ecuProfileStore = DPFECUProfileStore(
    identifier: "ble:test-adapter",
    defaults: ecuProfileDefaults
)
let rememberedECU = DPFECUProfile(
    headersByPID: ["380B": "18DA10F1", "18E4": "18DA18F1"],
    lastGoodHeader: "18DA10F1",
    preferredExhaustTemperaturePID: DPFPID.postDPFTempC.rawValue
)
ecuProfileStore.save(rememberedECU)
expect(ecuProfileStore.load() == rememberedECU,
       "dpf: validated ECU routes persist per adapter")
let rememberedECUWithIBS = DPFECUProfile(
    headersByPID: ["380B": "18DA10F1", "1005": "18DA40F1"],
    lastGoodHeader: "18DA10F1",
    preferredExhaustTemperaturePID: DPFPID.postDPFTempC.rawValue,
    preferredBatteryStateOfChargeSource: .ibsDirect
)
ecuProfileStore.save(rememberedECUWithIBS)
expect(ecuProfileStore.load() == rememberedECUWithIBS,
       "ibs: preferred battery source persists in the ECU profile")
expect(DPFECUProfileStore(identifier: "ble:other", defaults: ecuProfileDefaults).load() == nil,
       "dpf: ECU routes do not leak to another adapter")
ecuProfileDefaults.removePersistentDomain(forName: ecuProfileSuite)

expect(BLEAdvertisementClassifier.matches(name: "KONNWEI-KW903", advertisedServices: []),
       "ble: Konnwei brand name accepted")
expect(BLEAdvertisementClassifier.matches(name: "KW903", advertisedServices: []),
       "ble: confirmed Konnwei BLE model accepted")
expect(BLEAdvertisementClassifier.matches(name: "OBDPRO", advertisedServices: []),
       "ble: existing OBD name accepted")
expect(BLEAdvertisementClassifier.matches(name: nil, advertisedServices: [svcVlink]),
       "ble: existing advertised FFF0 accepted")
expect(!BLEAdvertisementClassifier.matches(name: "KW902", advertisedServices: []),
       "ble: Konnwei Classic-only model not claimed")
expect(!BLEAdvertisementClassifier.matches(name: "HMSoft", advertisedServices: [svcKonnwei]),
       "ble: unrelated HM-10 FFE0 peripheral rejected")
expect(!BLEAdvertisementClassifier.matches(name: nil, advertisedServices: []),
       "ble: anonymous unrelated peripheral rejected")

do {
    // Konnwei KW903 commonly exposes one duplex FFE1 characteristic.
    let picked = BLECharacteristicPicker.pick(from: [
        BLECandidate(service: svcOther, characteristic: chrOther1, canNotify: true, canWrite: true),
        BLECandidate(service: svcKonnwei, characteristic: chrKonnweiData, canNotify: true, canWrite: true),
    ])
    expect(picked?.service == svcKonnwei
           && picked?.notify == chrKonnweiData
           && picked?.write == chrKonnweiData,
           "ble: Konnwei FFE0/FFE1 duplex layout preferred")
}

do {
    // The known Vlink layout wins even when another usable pair exists.
    let picked = BLECharacteristicPicker.pick(from: [
        BLECandidate(service: svcOther, characteristic: chrOther1, canNotify: true, canWrite: true),
        BLECandidate(service: svcKonnwei, characteristic: chrKonnweiData, canNotify: true, canWrite: true),
        BLECandidate(service: svcVlink, characteristic: chrNotifyVlink, canNotify: true, canWrite: false),
        BLECandidate(service: svcVlink, characteristic: chrWriteVlink, canNotify: false, canWrite: true),
    ])
    expect(picked?.service == svcVlink
           && picked?.notify == chrNotifyVlink
           && picked?.write == chrWriteVlink,
           "ble: vlink FFF0/FFF1/FFF2 layout preferred")
}

do {
    // Unknown clone: fall back to a notify+write pair within one service.
    let picked = BLECharacteristicPicker.pick(from: [
        BLECandidate(service: svcOther, characteristic: chrOther1, canNotify: true, canWrite: false),
        BLECandidate(service: svcOther, characteristic: chrOther2, canNotify: false, canWrite: true),
    ])
    expect(picked?.service == svcOther
           && picked?.notify == chrOther1
           && picked?.write == chrOther2,
           "ble: generic notify+write pair fallback")
}

do {
    // Some clones expose a single duplex characteristic.
    let picked = BLECharacteristicPicker.pick(from: [
        BLECandidate(service: svcOther, characteristic: chrOther1, canNotify: true, canWrite: true),
    ])
    expect(picked?.notify == chrOther1 && picked?.write == chrOther1,
           "ble: single duplex characteristic")
}

do {
    // Notify and write in different services are not a usable pair.
    let picked = BLECharacteristicPicker.pick(from: [
        BLECandidate(service: svcVlink, characteristic: chrNotifyVlink, canNotify: true, canWrite: false),
        BLECandidate(service: svcOther, characteristic: chrOther2, canNotify: false, canWrite: true),
    ])
    expect(picked == nil, "ble: no cross-service pairing")
}

do {
    let picked = BLECharacteristicPicker.pick(from: [
        BLECandidate(service: svcOther, characteristic: chrOther1, canNotify: false, canWrite: false),
    ])
    expect(picked == nil, "ble: nothing usable returns nil")
}

// MARK: - Command recorder (for header-plumbing test)

final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func record(_ c: String) { lock.lock(); stored.append(c); lock.unlock() }
    var commands: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

// MARK: - Mock ELM server

final class MockELMServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "mock-elm-server")
    private var connections: [NWConnection] = []
    private let responder: @Sendable (String) -> String?

    init(port: UInt16, responder: @escaping @Sendable (String) -> String?) throws {
        self.responder = responder
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.queue.async { self.connections.append(conn) }
            conn.start(queue: self.queue)
            self.receive(on: conn, buffered: "")
        }
        listener.start(queue: queue)
    }

    private func receive(on conn: NWConnection, buffered: String) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, complete, error in
            guard let self, error == nil, !complete else { return }
            var buf = buffered
            if let data, let text = String(data: data, encoding: .ascii) {
                buf += text
            }
            while let idx = buf.firstIndex(of: "\r") {
                let cmd = String(buf[..<idx])
                buf.removeSubrange(...idx)
                if let reply = self.responder(cmd) {
                    conn.send(content: reply.data(using: .ascii)!, completion: .contentProcessed { _ in })
                }
            }
            self.receive(on: conn, buffered: buf)
        }
    }

    /// Sends unsolicited bytes on every open connection (simulates a reply
    /// arriving after the client gave up waiting).
    func broadcast(_ text: String) {
        queue.async {
            for conn in self.connections {
                conn.send(content: text.data(using: .ascii)!, completion: .contentProcessed { _ in })
            }
        }
    }

    /// Closes all client sockets but keeps listening (simulates a dongle
    /// dropping the TCP session).
    func dropAllConnections() {
        queue.sync {
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }
}

// MARK: - Connection tests

// Keep independent test processes from binding each other's mock servers
// (reviewers and local CI often run this executable in parallel).
let testPortBase = UInt16(20_000 + (ProcessInfo.processInfo.processIdentifier % 5_000) * 4)
let port = testPortBase
let server = try MockELMServer(port: port) { cmd in
    switch cmd {
    case "ATZ":    return "ATZ\rELM327 v1.5\r\r>"
    case "SILENT": return nil // never answers — forces a read timeout
    case "010C":   return "7E804410C1AF8\r>"
    default:       return "?\r>"
    }
}

let obd = OBDConnection(endpoint: .init(host: "127.0.0.1", port: port))
await obd.start()
do {
    try await obd.isReady()
} catch {
    failures += 1
    print("FAIL: conn readiness threw \(error)")
}

// Basic request/response with echo stripping.
do {
    let reply = try await obd.send("ATZ")
    expect(reply.contains("ELM327"), "conn: response body returned")
    expect(!reply.contains("ATZ"), "conn: echo stripped")
} catch {
    failures += 1
    print("FAIL: conn basic send threw \(error)")
}

// Read timeout fires when the adapter never answers.
do {
    _ = try await obd.send("SILENT", timeout: 0.5)
    failures += 1
    print("FAIL: conn: timeout expected, got response")
} catch {
    print("PASS: conn: timeout on silent command")
}

// A late reply to the timed-out command must NOT be served to the next one.
server.broadcast("STALE JUNK\r>")
try? await Task.sleep(nanoseconds: 300_000_000)
do {
    let reply = try await obd.send("010C", timeout: 2.0)
    expect(reply.contains("7E804410C1AF8") && !reply.contains("STALE"),
           "conn: stale rx dropped on next send")
} catch {
    failures += 1
    print("FAIL: conn stale-buffer send threw \(error)")
}

// A transparent TCP reconnect would resume polling without rerunning the ELM
// bootstrap. Treat a post-ready drop as terminal; the owning session restarts
// the transport and initializes the adapter from scratch.
server.dropAllConnections()
try? await Task.sleep(nanoseconds: 500_000_000)
var transparentlyReconnected = false
let deadline = Date().addingTimeInterval(4)
while Date() < deadline {
    if let reply = try? await obd.send("010C", timeout: 1.0), reply.contains("410C") {
        transparentlyReconnected = true
        break
    }
    try? await Task.sleep(nanoseconds: 500_000_000)
}
expect(!transparentlyReconnected,
       "conn: post-ready socket drop requires a fully reinitialized session")

await obd.stop()
await obd.start()
do {
    try await obd.isReady()
    let reply = try await obd.send("ATZ")
    expect(reply.contains("ELM327"),
           "conn: explicit transport restart recovers for a fresh ELM bootstrap")
} catch {
    failures += 1
    print("FAIL: conn: explicit transport restart threw \(error)")
}

await obd.stop()

// MARK: - Mode 22 physical addressing (header plumbing)

// Enhanced PIDs need the request addressed to a specific ECU via ATSH. Verify
// the header is sent, in the same critical section, before the 22 request.
let port2 = testPortBase + 1
let recorder = CommandRecorder()
let server2 = try MockELMServer(port: port2) { cmd in
    recorder.record(cmd)
    if cmd.hasPrefix("ATCP") { return "OK\r>" }
    if cmd.hasPrefix("ATSH") { return "OK\r>" }
    if cmd == "2218E4" { return "18DAF110056218E40CCD\r>" } // 29-bit positive reply
    if cmd == "010C" { return "18DAF11004410C0C86\r>" }
    return "NO DATA\r>"
}
_ = server2
let obd2 = OBDConnection(endpoint: .init(host: "127.0.0.1", port: port2))
await obd2.start()
do {
    try await obd2.isReady()
} catch {
    failures += 1
    print("FAIL: header connection readiness threw \(error)")
}
let elm2 = ELM327(connection: obd2)
do {
    let bytes = try await elm2.readMode22(pid: 0x18E4, header: "18DA10F1")
    expect(bytes == [0x0C, 0xCD], "header: mode22 with physical header parses")
    let cmds = recorder.commands
    if let atcp = cmds.firstIndex(of: "ATCP18"),
       let atsh = cmds.firstIndex(of: "ATSHDA10F1"),
       let req = cmds.firstIndex(of: "2218E4") {
        expect(atcp < atsh && atsh < req,
               "header: ELM327 v1.5 ATCP/ATSH precedes the 22 request")
    } else {
        failures += 1
        print("FAIL: header: ATCP18/ATSHDA10F1 not sent before 2218E4 — saw \(cmds)")
    }
} catch {
    failures += 1
    print("FAIL: header plumbing threw \(error)")
}

// A Mode 01 request may arrive concurrently with a header-scoped Mode 22
// request. It can run before or after, but never between ATSH and 22xxxx.
do {
    let commandOffset = recorder.commands.count
    async let dpfBytes = elm2.readMode22(pid: 0x18E4, header: "18DA18F1")
    async let liveReply = obd2.send("010C")
    let (bytes, reply) = try await (dpfBytes, liveReply)
    expect(bytes == [0x0C, 0xCD] && reply.contains("410C"),
           "header: concurrent Mode 01 and Mode 22 both complete")

    let concurrentCommands = Array(recorder.commands.dropFirst(commandOffset))
    if let atsh = concurrentCommands.firstIndex(of: "ATSHDA18F1"),
       let req = concurrentCommands.firstIndex(of: "2218E4") {
        expect(req == atsh + 1,
               "header: no Mode 01 interleaves between ATSH and Mode 22")
    } else {
        failures += 1
        print("FAIL: header: concurrent request sequence missing — saw \(concurrentCommands)")
    }
} catch {
    failures += 1
    print("FAIL: concurrent header test threw \(error)")
}

// Reproduce the real-device sequence: a physical Mode 22 read, a standard
// functional Mode 01 read, then the same physical Mode 22 read again. The ELM
// retains ATSH state, so both callers must provide their header explicitly.
do {
    let commandOffset = recorder.commands.count
    let mode01 = Mode01Reader(connection: obd2)
    let before = try await elm2.readMode22(pid: 0x18E4, header: "18DA01F1")
    let rpm = try await mode01.readRPM(header: "18DB33F1")
    let after = try await elm2.readMode22(pid: 0x18E4, header: "18DA01F1")
    expect(before == [0x0C, 0xCD] && rpm == 801.5 && after == [0x0C, 0xCD],
           "header: Mode 22 survives an interleaved functional Mode 01 read")

    let sequence = Array(recorder.commands.dropFirst(commandOffset))
    expect(
        sequence == [
            "ATSHDA01F1", "2218E4",
            "ATSHDB33F1", "010C",
            "ATSHDA01F1", "2218E4",
        ],
        "header: physical context is restored after functional Mode 01"
    )
} catch {
    failures += 1
    print("FAIL: sequential Mode 22/01/22 header test threw \(error)")
}
await obd2.stop()

// Newer clone firmware may reject legacy ATCP but accept a complete 29-bit
// identifier in ATSH. Validate that the fallback is bounded and observable.
let port3 = testPortBase + 2
let fallbackRecorder = CommandRecorder()
let server3 = try MockELMServer(port: port3) { cmd in
    fallbackRecorder.record(cmd)
    if cmd == "ATCP18" { return "?\r>" }
    if cmd == "ATSH18DA10F1" { return "OK\r>" }
    if cmd == "2218E4" { return "18DAF110056218E40CCD\r>" }
    return "NO DATA\r>"
}
_ = server3
let fallbackOBD = OBDConnection(endpoint: .init(host: "127.0.0.1", port: port3))
await fallbackOBD.start()
do {
    try await fallbackOBD.isReady()
    let bytes = try await ELM327(connection: fallbackOBD)
        .readMode22(pid: 0x18E4, header: "18DA10F1")
    expect(bytes == [0x0C, 0xCD],
           "header: four-byte ATSH fallback still reads Mode 22")
    expect(fallbackRecorder.commands == ["ATCP18", "ATSH18DA10F1", "2218E4"],
           "header: rejected ATCP triggers exactly one four-byte ATSH fallback")
} catch {
    failures += 1
    print("FAIL: four-byte ATSH fallback threw \(error)")
}
await fallbackOBD.stop()

// Never cache an unacknowledged header: a rejected legacy command followed by
// a rejected fallback must fail before any diagnostic request reaches the ECU.
let port4 = testPortBase + 3
let rejectionRecorder = CommandRecorder()
let server4 = try MockELMServer(port: port4) { cmd in
    rejectionRecorder.record(cmd)
    return "?\r>"
}
_ = server4
let rejectingOBD = OBDConnection(endpoint: .init(host: "127.0.0.1", port: port4))
await rejectingOBD.start()
do {
    try await rejectingOBD.isReady()
    _ = try await ELM327(connection: rejectingOBD)
        .readMode22(pid: 0x18E4, header: "18DA10F1")
    failures += 1
    print("FAIL: rejected header expected to throw")
} catch {
    expect(rejectionRecorder.commands == ["ATCP18", "ATSH18DA10F1"],
           "header: rejected header never sends the Mode 22 request")
}
await rejectingOBD.stop()

// An unreachable adapter must fail readiness instead of parking forever.
let unavailable = OBDConnection(
    endpoint: .init(host: "192.0.2.1", port: 1),
    readinessTimeout: 0.4
)
await unavailable.start()
do {
    try await unavailable.isReady()
    failures += 1
    print("FAIL: readiness timeout expected, got ready")
} catch let error as OBDError {
    expect(error == .wifiConnectionTimeout,
           "conn: readiness fails with typed overall timeout")
} catch {
    failures += 1
    print("FAIL: readiness timeout returned unexpected error \(error)")
}
await unavailable.stop()

// Stopping during setup must release every readiness waiter immediately.
let cancelled = OBDConnection(
    endpoint: .init(host: "192.0.2.1", port: 1),
    readinessTimeout: 5
)
await cancelled.start()
let readinessWaiter = Task { try await cancelled.isReady() }
try? await Task.sleep(for: .milliseconds(100))
await cancelled.stop()
do {
    try await readinessWaiter.value
    failures += 1
    print("FAIL: readiness cancellation expected, got ready")
} catch is CancellationError {
    print("PASS: conn: stop cancels pending readiness")
} catch {
    failures += 1
    print("FAIL: readiness cancellation returned unexpected error \(error)")
}

// A timeout task that wakes as stop runs must not overwrite the final idle
// state with a stale connectionTimeout failure.
var stoppedConnectionsStayedIdle = true
for _ in 0..<20 {
    let racingStop = OBDConnection(
        endpoint: .init(host: "192.0.2.1", port: 1),
        readinessTimeout: 0.01
    )
    await racingStop.start()
    try? await Task.sleep(for: .milliseconds(9))
    await racingStop.stop()
    try? await Task.sleep(for: .milliseconds(2))
    do {
        try await racingStop.isReady()
        stoppedConnectionsStayedIdle = false
    } catch let error as OBDError {
        if error != .notReady { stoppedConnectionsStayedIdle = false }
    } catch {
        stoppedConnectionsStayedIdle = false
    }
}
expect(stoppedConnectionsStayedIdle,
       "conn: cancelled readiness deadline cannot overwrite stopped state")

// MARK: - History store

let historyTestDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("AlphaDPFHistoryTests-\(UUID().uuidString)", isDirectory: true)
let historyTestURL = historyTestDirectory.appendingPathComponent("history.sqlite3")

let historyStoreResult = Result { try DPFHistoryStore(databaseURL: historyTestURL) }
switch historyStoreResult {
case .failure(let error):
    failures += 1
    print("FAIL: history — store init failed: \(error)")
case .success(let store):
    expect(store.samples().isEmpty, "history: isolated store starts without samples")
    expect(store.cycles().isEmpty, "history: isolated store starts without cycles")
    expect(!store.hasActiveRegen, "history: isolated store has no active regen")

    let now = Date()
    let recorded1 = store.recordSample(
        timestamp: now,
        cloggingPercent: 30.0,
        exhaustTempC: 180.0,
        regenActive: false,
        distanceSinceLastRegenKm: 50.0
    )
    expect(recorded1, "history: first sample is always recorded")

    let recorded2 = store.recordSample(
        timestamp: now.addingTimeInterval(10),
        cloggingPercent: 30.2,
        exhaustTempC: 182.0,
        regenActive: false,
        distanceSinceLastRegenKm: 51.0
    )
    expect(!recorded2, "history: sample skipped when delta < 1%")

    let recorded3 = store.recordSample(
        timestamp: now.addingTimeInterval(20),
        cloggingPercent: 31.5,
        exhaustTempC: 185.0,
        regenActive: false,
        distanceSinceLastRegenKm: 52.0
    )
    expect(recorded3, "history: sample recorded when delta ≥ 1%")
    let samples = store.samples()
    expect(samples.count == 2, "history: expected 2 isolated samples, got \(samples.count)")

    let asyncStoreURL = historyTestDirectory.appendingPathComponent("async.sqlite3")
    if let asyncStore = try? DPFHistoryStore(databaseURL: asyncStoreURL) {
        let asyncRecorded = await asyncStore.recordSampleAsync(
            timestamp: now,
            cloggingPercent: 42.0,
            exhaustTempC: 190.0,
            regenActive: false,
            distanceSinceLastRegenKm: 12.0
        )
        expect(asyncRecorded && asyncStore.samples().count == 1,
               "history: asynchronous recording preserves sample semantics")
    } else {
        failures += 1
        print("FAIL: history: async store init failed")
    }

    let rollingStoreURL = historyTestDirectory.appendingPathComponent("rolling.sqlite3")
    if let rollingStore = try? DPFHistoryStore(databaseURL: rollingStoreURL) {
        _ = rollingStore.recordSample(
            timestamp: now.addingTimeInterval(-(25 * 60 * 60)),
            cloggingPercent: 40.0,
            exhaustTempC: nil,
            regenActive: false,
            distanceSinceLastRegenKm: nil
        )
        let firstCurrentSample = rollingStore.recordSample(
            timestamp: now,
            cloggingPercent: 40.2,
            exhaustTempC: nil,
            regenActive: false,
            distanceSinceLastRegenKm: nil
        )
        expect(firstCurrentSample,
               "history: expired sample cannot suppress the first current-window sample")
        expect(rollingStore.samples(since: now.addingTimeInterval(-(24 * 60 * 60))).count == 1,
               "history: expired samples are pruned before the delta decision")
    } else {
        failures += 1
        print("FAIL: history: rolling-window store init failed")
    }

    expect(store.recordRegenStart(at: now.addingTimeInterval(30), load: 88.0),
           "history: first regen start inserts a cycle")
    expect(!store.recordRegenStart(at: now.addingTimeInterval(31), load: 87.5),
           "history: duplicate active edge is idempotent")
    expect(store.hasActiveRegen, "history: has active regen after start")
    let activeCycles = store.cycles()
    expect(activeCycles.count == 1, "history: one cycle after duplicate start")
    expect(activeCycles.first?.status == .active
           && activeCycles.first?.startingLoad == 88.0
           && activeCycles.first?.finishedAt == nil,
           "history: active cycle preserves its original start")

    expect(store.recordRegenFinish(at: now.addingTimeInterval(900), endingLoad: 32.0),
           "history: active cycle can be completed")
    expect(!store.recordRegenFinish(at: now.addingTimeInterval(901), endingLoad: 31.5),
           "history: duplicate finish is idempotent")
    expect(!store.hasActiveRegen, "history: no active regen after finish")
    let finishedCycles = store.cycles()
    expect(finishedCycles.count == 1
           && finishedCycles.first?.status == .completed
           && finishedCycles.first?.endingLoad == 32.0
           && finishedCycles.first?.finishedAt != nil,
           "history: completed cycle stores one truthful finish")

    _ = store.recordRegenStart(at: now.addingTimeInterval(2000), load: 85.0)
    expect(store.recordRegenInterrupted(at: now.addingTimeInterval(2100), endingLoad: 80.0),
           "history: confirmed engine-off can interrupt the active cycle")
    let allCycles = store.cycles()
    expect(allCycles.count == 2
           && allCycles[0].status == .interrupted
           && allCycles[1].status == .completed,
           "history: interrupted and completed cycles remain distinct")

    _ = store.recordRegenStart(at: now.addingTimeInterval(3000), load: 78.0)
    expect(store.recordActiveRegenUnconfirmed(),
           "history: lifecycle loss marks an unresolved cycle as unconfirmed")
    let reconciled = store.cycles()
    expect(reconciled.first?.status == .unconfirmed
           && reconciled.first?.finishedAt == nil,
           "history: unconfirmed cycle keeps an honest unknown end time")

    let insights = DPFHistoryInsights(cycles: reconciled)
    expect(insights.completedCycles == 1
           && insights.interruptedCycles == 1
           && insights.unconfirmedCycles == 1,
           "history insights: outcomes are counted without treating unknown as failure")
    expect(insights.completionRate == 0.5,
           "history insights: completion rate uses only observed outcomes")
    expect(insights.averageDuration.map { abs($0 - 870) < 0.001 } == true,
           "history insights: duration uses completed cycles only")
    expect(insights.averageLoadReduction == 56,
           "history insights: load reduction uses completed cycles only")

    let storedInsights = store.insights()
    expect(storedInsights == insights,
           "history insights: SQL aggregate matches the complete stored history")

    let manyCyclesURL = historyTestDirectory.appendingPathComponent("many-cycles.sqlite3")
    if let manyCyclesStore = try? DPFHistoryStore(databaseURL: manyCyclesURL) {
        for index in 0..<60 {
            let start = now.addingTimeInterval(Double(index * 1_000))
            _ = manyCyclesStore.recordRegenStart(at: start, load: 90)
            _ = manyCyclesStore.recordRegenFinish(
                at: start.addingTimeInterval(600),
                endingLoad: 30
            )
        }
        expect(manyCyclesStore.cycles().count == 50,
               "history: visible cycle list remains bounded")
        expect(manyCyclesStore.insights().completedCycles == 60,
               "history insights: aggregate covers cycles beyond the visible list limit")
    } else {
        failures += 1
        print("FAIL: history: many-cycle aggregate store init failed")
    }

    print("PASS: history — all store tests")
}
try? FileManager.default.removeItem(at: historyTestDirectory)

// MARK: - Summary

if failures == 0 {
    print("\nAll tests passed.")
    exit(0)
} else {
    print("\n\(failures) test(s) FAILED.")
    exit(1)
}
