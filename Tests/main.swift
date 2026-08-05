import Foundation
import Network
import CoreBluetooth

// Standalone test runner for the pure protocol logic + OBDConnection.
// Runs on macOS without Xcode:
//   swiftc Sources/Models.swift Sources/OBDLog.swift Sources/OBDTransport.swift \
//          Sources/OBDConnection.swift Sources/BLEConnection.swift Sources/ELM327.swift \
//          Sources/Mode01.swift Tests/main.swift -o /tmp/alfadpf_tests && /tmp/alfadpf_tests

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
expect(CarPlayNotificationTestPolicy.systemDeliveryDelay >= 10,
       "carplay notifications: system test leaves enough time to return Home")

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

let carPlayAlertDefaults = UserDefaults(suiteName: "AlphaDPF.CarPlayAlertPreferenceTests")!
carPlayAlertDefaults.removePersistentDomain(forName: "AlphaDPF.CarPlayAlertPreferenceTests")
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
carPlayAlertDefaults.removePersistentDomain(forName: "AlphaDPF.CarPlayAlertPreferenceTests")

var carPlayCurrentState = DPFState()
carPlayCurrentState.cloggingPercent = 88
var carPlayPersistedState = DPFState()
carPlayPersistedState.cloggingPercent = 42
expect(CarPlayTelemetryPolicy.displayState(
    current: carPlayCurrentState,
    lastPersisted: carPlayPersistedState,
    hasLiveTelemetry: true
).cloggingPercent == 88,
       "carplay telemetry: fresh real sample wins")
expect(CarPlayTelemetryPolicy.displayState(
    current: carPlayCurrentState,
    lastPersisted: carPlayPersistedState,
    hasLiveTelemetry: false
).cloggingPercent == 42,
       "carplay telemetry: cached real state hides non-live fixture")
expect(!CarPlayTelemetryPolicy.displayState(
    current: carPlayCurrentState,
    lastPersisted: nil,
    hasLiveTelemetry: false
).hasTelemetry,
       "carplay telemetry: no real state displays unavailable values")

var carPlayAlertTracker = CarPlayRegenerationAlertTracker()
expect(carPlayAlertTracker.observe(isRegenerating: false, telemetryIsLive: false) == nil,
       "carplay alert: cached telemetry never creates an event")
expect(carPlayAlertTracker.observe(isRegenerating: false, telemetryIsLive: true) == nil,
       "carplay alert: first live sample arms without a false event")
expect(carPlayAlertTracker.observe(isRegenerating: true, telemetryIsLive: true) == .started,
       "carplay alert: inactive-to-active edge starts regeneration")
expect(carPlayAlertTracker.observe(isRegenerating: true, telemetryIsLive: true) == nil,
       "carplay alert: stable active state does not repeat")
expect(carPlayAlertTracker.observe(isRegenerating: nil, telemetryIsLive: true) == nil,
       "carplay alert: unknown regeneration sample does not emit a false finish")
expect(carPlayAlertTracker.observe(isRegenerating: true, telemetryIsLive: true) == nil,
       "carplay alert: recovery from unknown preserves the active edge")
expect(carPlayAlertTracker.observe(isRegenerating: false, telemetryIsLive: true) == .finished,
       "carplay alert: active-to-inactive edge finishes regeneration")
expect(carPlayAlertTracker.observe(isRegenerating: true, telemetryIsLive: false) == nil
       && carPlayAlertTracker.observe(isRegenerating: true, telemetryIsLive: true) == nil,
       "carplay alert: telemetry interruption rearms without a false event")

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

// MARK: - Last real DPF snapshot

let snapshotSuite = "AlfaDPF.Tests.\(UUID().uuidString)"
let snapshotDefaults = UserDefaults(suiteName: snapshotSuite)!
let savedAt = Date(timeIntervalSince1970: 1_750_000_000)
let savedSnapshot = DPFState(
    cloggingPercent: 67,
    exhaustTempC: 412,
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
newSignals.exhaustTemperaturePID = DPFPID.postDPFTempC.rawValue
let mergedNewSignals = mergedSnapshot.mergingFreshTelemetry(from: newSignals)
expect(
    mergedNewSignals.effectiveRegenerationMode == .passive
        && mergedNewSignals.isRegenerating
        && mergedNewSignals.oilPressureStatusText == "Normale"
        && mergedNewSignals.batteryVoltage == savedSnapshot.batteryVoltage
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
    DPFSimulationScenario.unavailable.state().cloggingPercent == nil,
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

typealias BLECandidate = BLECharacteristicPicker.Candidate
let svcVlink = CBUUID(string: "FFF0")
let chrNotifyVlink = CBUUID(string: "FFF1")
let chrWriteVlink = CBUUID(string: "FFF2")
let svcOther = CBUUID(string: "ABC0")
let chrOther1 = CBUUID(string: "ABC1")
let chrOther2 = CBUUID(string: "ABC2")
let svcKonnwei = CBUUID(string: "FFE0")
let chrKonnweiData = CBUUID(string: "FFE1")

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
    expect(picked?.notify == chrKonnweiData && picked?.write == chrKonnweiData,
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
    expect(picked?.notify == chrNotifyVlink && picked?.write == chrWriteVlink,
           "ble: vlink FFF0/FFF1/FFF2 layout preferred")
}

do {
    // Unknown clone: fall back to a notify+write pair within one service.
    let picked = BLECharacteristicPicker.pick(from: [
        BLECandidate(service: svcOther, characteristic: chrOther1, canNotify: true, canWrite: false),
        BLECandidate(service: svcOther, characteristic: chrOther2, canNotify: false, canWrite: true),
    ])
    expect(picked?.notify == chrOther1 && picked?.write == chrOther2,
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

// After the dongle drops the socket, the client must reconnect by itself.
server.dropAllConnections()
try? await Task.sleep(nanoseconds: 500_000_000)
var reconnected = false
let deadline = Date().addingTimeInterval(12)
while Date() < deadline {
    if let reply = try? await obd.send("010C", timeout: 1.0), reply.contains("410C") {
        reconnected = true
        break
    }
    try? await Task.sleep(nanoseconds: 500_000_000)
}
expect(reconnected, "conn: reconnects after socket drop")

await obd.stop()

// MARK: - Mode 22 physical addressing (header plumbing)

// Enhanced PIDs need the request addressed to a specific ECU via ATSH. Verify
// the header is sent, in the same critical section, before the 22 request.
let port2 = testPortBase + 1
let recorder = CommandRecorder()
let server2 = try MockELMServer(port: port2) { cmd in
    recorder.record(cmd)
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
    if let atsh = cmds.firstIndex(of: "ATSH18DA10F1"),
       let req = cmds.firstIndex(of: "2218E4") {
        expect(atsh < req, "header: ATSH precedes the 22 request")
    } else {
        failures += 1
        print("FAIL: header: ATSH18DA10F1 not sent before 2218E4 — saw \(cmds)")
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
    if let atsh = concurrentCommands.firstIndex(of: "ATSH18DA18F1"),
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
            "ATSH18DA01F1", "2218E4",
            "ATSH18DB33F1", "010C",
            "ATSH18DA01F1", "2218E4",
        ],
        "header: physical context is restored after functional Mode 01"
    )
} catch {
    failures += 1
    print("FAIL: sequential Mode 22/01/22 header test threw \(error)")
}
await obd2.stop()

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
    expect(error == .connectionTimeout,
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

// MARK: - Summary

if failures == 0 {
    print("\nAll tests passed.")
    exit(0)
} else {
    print("\n\(failures) test(s) FAILED.")
    exit(1)
}
