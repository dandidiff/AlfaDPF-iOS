import Foundation

/// Language used by the phone app and CarPlay presentation. Widgets remain a
/// separate process and continue to follow their own system locale.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case italian = "it"
    case english = "en"
    case french = "fr"
    case spanish = "es"

    static let defaultsKey = "appLanguage.v1"

    var id: String { rawValue }

    var localeIdentifier: String? {
        switch self {
        case .system: return nil
        case .italian: return "it"
        case .english: return "en"
        case .french: return "fr"
        case .spanish: return "es"
        }
    }

    var locale: Locale {
        localeIdentifier.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    /// Native language names stay recognizable even when the current UI is in
    /// another language. Only the system option is a localized catalog key.
    var displayNameKey: String {
        switch self {
        case .system: return "Sistema"
        case .italian: return "Italiano"
        case .english: return "English"
        case .french: return "Français"
        case .spanish: return "Español"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey)
            .flatMap(Self.init(rawValue:)) ?? .system
    }
}

/// Resolves strings created outside SwiftUI's `Text` hierarchy with the same
/// locale selected in-app. This uses public Foundation APIs and does not mutate
/// `AppleLanguages`, replace Bundle classes, or require a forced relaunch.
enum AppLocalization {
    static var language: AppLanguage {
        AppLanguage.load()
    }

    static func string(_ resource: LocalizedStringResource) -> String {
        guard language.localeIdentifier != nil else {
            return String(localized: resource)
        }
        var localized = resource
        localized.locale = language.locale
        return String(localized: localized)
    }

    /// Keep values already typed as localization keys on the same explicit-
    /// locale path without converting them through a plain runtime string.
    static func string(key: String.LocalizationValue) -> String {
        guard language.localeIdentifier != nil else {
            return String(localized: LocalizedStringResource(key, bundle: .main))
        }
        let resource = LocalizedStringResource(
            key,
            locale: language.locale,
            bundle: .main
        )
        return String(localized: resource)
    }
}

/// User-selected physical link to the ELM adapter. Both transports feed the
/// same ELM line engine; only discovery/socket plumbing differs.
enum OBDTransportKind: String, CaseIterable, Identifiable, Sendable {
    case bluetooth
    case wifi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bluetooth: return "Bluetooth LE"
        case .wifi: return "Wi-Fi"
        }
    }

    private static let defaultsKey = "obdTransportKind.v1"

    static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: defaultsKey)
            .flatMap(Self.init(rawValue:)) ?? .bluetooth
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Manually configured TCP endpoint used by common Wi-Fi ELM327 adapters.
/// Manual configuration is deliberate: adapters use several private subnets,
/// and blind local-network scans are both unreliable and intrusive.
struct WiFiAdapterEndpoint: Equatable, Sendable {
    var host: String
    var port: UInt16

    static let commonDefault = WiFiAdapterEndpoint(host: "192.168.0.10", port: 35000)

    static func parse(host: String, port: String) -> Self? {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty,
              !cleanHost.contains(where: { $0.isWhitespace || $0.isNewline }),
              !cleanHost.contains("://"),
              !cleanHost.contains("/"),
              let parsedPort = UInt16(cleanPort),
              parsedPort > 0
        else { return nil }
        return WiFiAdapterEndpoint(host: cleanHost, port: parsedPort)
    }
}

/// Lifecycle of the phone-side monitor session. Declared outside
/// `MonitorSession` so the pure UI policy below (idle timer) is testable
/// without UIKit.
enum SessionStatus: Equatable, Sendable {
    case idle
    case connecting
    case running
    case simulating
    case failed(String)

    /// Whether the screen must stay awake while this status is current.
    /// Connecting/running poll the ECU continuously and the dashboard must
    /// stay live; every other state — including failures and telemetry
    /// interruption — must release the idle timer so the display can sleep.
    var keepsScreenAwake: Bool {
        switch self {
        case .connecting, .running: return true
        case .idle, .simulating, .failed: return false
        }
    }

    /// The single safe connection action exposed by the CarPlay dashboard.
    /// A simulation is phone-only, so selecting Connect replaces it with a
    /// real OBD session rather than displaying synthetic data in the vehicle.
    var carPlayConnectionAction: CarPlayConnectionAction {
        switch self {
        case .idle, .simulating, .failed: return .connect
        case .connecting: return .cancel
        case .running: return .disconnect
        }
    }
}

/// Conservative evidence that the engine stopped while a regeneration was
/// active. A single low ATRV sample is not enough: smart alternators can run
/// below 13 V, and a stale voltage says nothing about a later telemetry loss.
/// Confirmation therefore requires a live running-voltage baseline followed
/// by three low samples spanning at least five seconds while core DPF traffic
/// is unavailable.
struct RegenEngineOffDetector: Equatable, Sendable {
    private static let runningVoltage = 13.5
    private static let engineOffVoltage = 12.8
    private static let minimumVoltageDrop = 0.8
    private static let minimumLowSamples = 3
    private static let minimumLowDuration: TimeInterval = 5

    private var runningBaseline: Double?
    private var lowVoltageStartedAt: Date?
    private var lowSampleCount = 0

    mutating func observe(
        voltage: Double?,
        at timestamp: Date,
        coreTelemetryAvailable: Bool
    ) -> Bool {
        if coreTelemetryAvailable {
            clearLowEvidence()
            guard let voltage, voltage.isFinite, (0...100).contains(voltage) else {
                runningBaseline = nil
                return false
            }
            // Only the most recent live voltage can arm a later shutdown
            // decision. A historical alternator peak is stale evidence if the
            // last live sample had already dropped into the ambiguous range.
            runningBaseline = voltage >= Self.runningVoltage ? voltage : nil
            return false
        }

        guard let voltage, voltage.isFinite, (0...100).contains(voltage) else {
            return false
        }
        guard let runningBaseline else { return false }
        let lowThreshold = min(
            Self.engineOffVoltage,
            runningBaseline - Self.minimumVoltageDrop
        )
        guard voltage <= lowThreshold else {
            if voltage >= Self.runningVoltage {
                clearLowEvidence()
            }
            return false
        }

        if lowVoltageStartedAt == nil {
            lowVoltageStartedAt = timestamp
        }
        lowSampleCount += 1
        guard let lowVoltageStartedAt else { return false }
        return lowSampleCount >= Self.minimumLowSamples
            && timestamp.timeIntervalSince(lowVoltageStartedAt) >= Self.minimumLowDuration
    }

    mutating func reset() {
        runningBaseline = nil
        clearLowEvidence()
    }

    private mutating func clearLowEvidence() {
        lowVoltageStartedAt = nil
        lowSampleCount = 0
    }
}

enum CarPlayConnectionAction: Equatable, Sendable {
    case connect
    case cancel
    case disconnect
}

/// Apple limits periodic data-item refreshes in Driving Task apps to no more
/// than once every ten seconds. Keep this policy shared with tests so a future
/// UI change cannot silently reintroduce a non-compliant real-time refresh.
enum CarPlayRefreshPolicy {
    static let interval: Duration = .seconds(10)
}

enum CarPlayNotificationTestPolicy {
    /// Gives the driver time to leave the app and return to CarPlay Home. A
    /// system notification tested while its own app is foreground may be
    /// visually suppressed by the system.
    static let systemDeliveryDelay: TimeInterval = 10
}

enum CarPlayAlertPreference {
    static let defaultsKey = "carPlayAlertsEnabled.v1"

    static func load(from defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else { return true }
        return defaults.bool(forKey: defaultsKey)
    }
}

enum DrivingFocusGuidancePreference {
    static let defaultsKey = "drivingFocusGuidanceAcknowledged.v1"

    static func needsPresentation(from defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: defaultsKey)
    }

    static func acknowledge(in defaults: UserDefaults) {
        defaults.set(true, forKey: defaultsKey)
    }
}

enum CarPlayNotificationRoute: Equatable, Sendable {
    case carPlay
    case phoneOnly

    static func production(carPlayAlertsEnabled: Bool) -> Self {
        carPlayAlertsEnabled ? .carPlay : .phoneOnly
    }

    /// Explicit tests bypass the local mute because the user requested this
    /// one delivery specifically to verify the CarPlay notification path.
    static let explicitTest: Self = .carPlay
}

enum CarPlayNotificationIssue: Equatable, Sendable {
    case checking
    case permissionRequired
    case permissionDenied
    case carPlayDisabled
    case alertsDisabled
    case timeSensitiveDisabled
    case soundDisabled
}

struct AlertAuthorizationState: Equatable, Sendable {
    enum Authorization: Equatable, Sendable {
        case checking
        case notDetermined
        case denied
        case authorized
    }

    var authorization: Authorization
    var timeSensitiveEnabled: Bool
    var siriAnnouncementsEnabled: Bool
    var carPlayEnabled: Bool
    var alertEnabled: Bool
    var lockScreenEnabled: Bool
    var soundEnabled: Bool

    static let checking = AlertAuthorizationState(
        authorization: .checking,
        timeSensitiveEnabled: false,
        siriAnnouncementsEnabled: false,
        carPlayEnabled: false,
        alertEnabled: false,
        lockScreenEnabled: false,
        soundEnabled: false
    )

    var canSendTimeSensitiveAlerts: Bool {
        authorization == .authorized
            && timeSensitiveEnabled
            && alertEnabled
            && lockScreenEnabled
            && soundEnabled
    }

    /// Whether a queued system notification can replace the in-app CPAlert.
    /// `carPlayEnabled` alone is insufficient: iOS can accept the request while
    /// suppressing its presentation when authorization or alerts are disabled.
    var canPresentSystemCarPlayAlert: Bool {
        authorization == .authorized
            && carPlayEnabled
            && alertEnabled
    }

    var needsSettingsAttention: Bool {
        switch authorization {
        case .denied:
            return true
        case .authorized:
            return !timeSensitiveEnabled
                || !siriAnnouncementsEnabled
                || !alertEnabled
                || !lockScreenEnabled
                || !soundEnabled
        case .checking, .notDetermined:
            return false
        }
    }

    /// Exact CarPlay delivery problems. Time Sensitive and sound settings are
    /// warnings rather than authorization blockers, but explain a quiet test.
    var carPlayNotificationIssues: [CarPlayNotificationIssue] {
        switch authorization {
        case .checking:
            return [.checking]
        case .notDetermined:
            return [.permissionRequired]
        case .denied:
            return [.permissionDenied]
        case .authorized:
            var issues: [CarPlayNotificationIssue] = []
            if !carPlayEnabled { issues.append(.carPlayDisabled) }
            if !alertEnabled { issues.append(.alertsDisabled) }
            if !timeSensitiveEnabled { issues.append(.timeSensitiveDisabled) }
            if !soundEnabled { issues.append(.soundDisabled) }
            return issues
        }
    }
}

enum CarPlayTelemetryPolicy {
    static func displayState(
        current: DPFState,
        lastPersisted: DPFState?,
        status: SessionStatus,
        hasLiveTelemetry: Bool
    ) -> DPFState {
        isLive(status: status, hasLiveTelemetry: hasLiveTelemetry)
            ? current
            : (lastPersisted ?? DPFState())
    }

    /// A transport that is ready is not necessarily producing fresh ECU data.
    /// CarPlay presentation is live only after the shared phone session has
    /// accepted a recent core DPF sample while it is running.
    static func isLive(
        status: SessionStatus,
        hasLiveTelemetry: Bool
    ) -> Bool {
        status == .running && hasLiveTelemetry
    }
}

/// The eight glanceable CarPlay tiles. Each tile pushes one compact
/// `CPInformationTemplate` detail surface; this type stays Foundation-only so
/// the hierarchy can be tested without UIKit/CarPlay.
enum CarPlayDashboardMetric: CaseIterable, Equatable, Sendable {
    case dpf
    case regeneration
    case distance
    case exhaust
    case progress
    case totalRegenerations
    case oil
    case battery
}

enum CarPlayDashboardPolicy {
    static let maximumTileCount = 8
    static let maximumInformationItemCount = 4
}

enum CarPlayDashboardIconTone: Equatable, Sendable {
    case neutral
    case accent
    case dpfSemantic(DPFLoadAlertLevel)
    case regenerationSemantic(DPFRegenerationMode)
}

/// Presentation policy for dashboard artwork. Cached or disconnected values
/// may remain readable in the detail template, but every dashboard icon is
/// deliberately neutral until the shared OBD session is live again.
enum CarPlayDashboardIconPolicy {
    static func tone(
        for metric: CarPlayDashboardMetric,
        state: DPFState,
        isLive: Bool
    ) -> CarPlayDashboardIconTone {
        guard isLive else { return .neutral }

        switch metric {
        case .dpf:
            return .dpfSemantic(state.loadAlertLevel)
        case .regeneration:
            switch state.effectiveRegenerationMode {
            case .none:
                // A live, idle tile uses the user's accent rather than the
                // neutral cached-data treatment.
                return .accent
            case .passive, .active:
                return .regenerationSemantic(state.effectiveRegenerationMode)
            }
        case .distance, .exhaust, .progress, .totalRegenerations, .oil, .battery:
            return .accent
        }
    }
}

enum CarPlayRegenerationAlertEvent: Equatable, Sendable {
    case started
    case finished
}

/// Emits CarPlay modal alerts only on known edges observed while telemetry is
/// live. A temporarily unknown regen state preserves the previous edge; a full
/// telemetry interruption resets it so reconnection cannot replay stale data.
struct CarPlayRegenerationAlertTracker: Equatable, Sendable {
    private var previousIsRegenerating: Bool?

    mutating func observe(
        isRegenerating: Bool?,
        telemetryIsLive: Bool
    ) -> CarPlayRegenerationAlertEvent? {
        guard telemetryIsLive else {
            previousIsRegenerating = nil
            return nil
        }

        // A failed progress read is not a completed regeneration. Keep the
        // last known edge so recovery cannot emit a duplicate start either.
        guard let isRegenerating else { return nil }

        guard let previousIsRegenerating else {
            self.previousIsRegenerating = isRegenerating
            return nil
        }

        self.previousIsRegenerating = isRegenerating
        guard previousIsRegenerating != isRegenerating else { return nil }
        return isRegenerating ? .started : .finished
    }
}

/// Canonical deep-link destinations. The Live Activity widget opens
/// `alfadpf://monitor` when tapped; the root view maps every handled link to
/// the single `.monitor` action so tapping a (possibly stale) activity always
/// starts or reconnects the session.
enum AppDeepLink: Equatable, Sendable {
    case monitor

    static let scheme = "alfadpf"
    /// The one canonical destination, also referenced by the widget.
    static let monitorURL = URL(string: "\(scheme)://monitor")!

    /// Accepts the canonical `alfadpf://monitor` URL, the legacy
    /// `alfadpf://connect` link and bare `alfadpf://` URLs. Unknown hosts and
    /// foreign schemes are not handled.
    static func parse(_ url: URL) -> AppDeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        switch url.host?.lowercased() {
        case "monitor", "connect":
            return .monitor
        case nil, "":
            let path = url.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased()
            return path.isEmpty || path == "monitor" || path == "connect" ? .monitor : nil
        default:
            return nil
        }
    }
}

/// Regeneration state used by the UI and simulator. Real OBD sessions derive
/// active regeneration from progress/temperature: 2218EC is documented as a
/// forced-regeneration command state and the on-road logs prove it stays zero
/// throughout a normal active regeneration.
enum DPFRegenerationMode: Int, Codable, Equatable, Sendable {
    case none = 0
    case passive = 1
    case active = 2
}

/// Shared warning bands for the FCA DPF load index. Keeping the thresholds in
/// the model prevents CarPlay artwork and future dashboard surfaces from
/// silently assigning different meanings to the same ECU value.
enum DPFLoadAlertLevel: Equatable, Sendable {
    case unavailable
    case low
    case nearRegeneration
    case regenerationImminent
    case activeRegeneration

    static func resolve(
        loadPercent: Double?,
        regenerationMode: DPFRegenerationMode
    ) -> Self {
        if regenerationMode == .active { return .activeRegeneration }
        guard let loadPercent else { return .unavailable }
        if loadPercent > 95 { return .regenerationImminent }
        if loadPercent >= 85 { return .nearRegeneration }
        return .low
    }
}

/// Factory paint names offered on Stelvio across its model years. RGB values
/// are screen-friendly approximations for the app accent, not paint formulas.
enum StelvioAccent: String, CaseIterable, Codable, Identifiable, Sendable {
    case rossoAlfa
    case biancoAlfa
    case neroVulcano
    case grigioVesuvio
    case grigioStromboli
    case grigioSilverstone
    case titanioImola
    case bluMontecarlo
    case rossoCompetizione
    case biancoTrofeo
    case bluMisano
    case bluAnodizzato
    case biancoLunare
    case ocraGTJunior
    case rossoVillaDEste
    case verdeMontreal
    case verdeVisconti
    case rossoEtna
    case grigioMoonlight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rossoAlfa: return "Rosso Alfa"
        case .biancoAlfa: return "Bianco Alfa"
        case .neroVulcano: return "Nero Vulcano"
        case .grigioVesuvio: return "Grigio Vesuvio"
        case .grigioStromboli: return "Grigio Stromboli"
        case .grigioSilverstone: return "Grigio Silverstone"
        case .titanioImola: return "Titanio Imola"
        case .bluMontecarlo: return "Blu Montecarlo"
        case .rossoCompetizione: return "Rosso Competizione"
        case .biancoTrofeo: return "Bianco Trofeo"
        case .bluMisano: return "Blu Misano"
        case .bluAnodizzato: return "Blu Anodizzato"
        case .biancoLunare: return "Bianco Lunare"
        case .ocraGTJunior: return "Ocra GT Junior"
        case .rossoVillaDEste: return "Rosso Villa d’Este"
        case .verdeMontreal: return "Verde Montreal"
        case .verdeVisconti: return "Verde Visconti"
        case .rossoEtna: return "Rosso Etna"
        case .grigioMoonlight: return "Grigio Moonlight"
        }
    }

    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .rossoAlfa:          return (0.93, 0.11, 0.16)
        case .biancoAlfa:         return (0.84, 0.84, 0.80)
        case .neroVulcano:        return (0.36, 0.38, 0.42)
        case .grigioVesuvio:      return (0.43, 0.46, 0.48)
        case .grigioStromboli:    return (0.55, 0.56, 0.54)
        case .grigioSilverstone:  return (0.68, 0.69, 0.67)
        case .titanioImola:       return (0.67, 0.62, 0.52)
        case .bluMontecarlo:      return (0.08, 0.30, 0.65)
        case .rossoCompetizione:  return (0.76, 0.03, 0.07)
        case .biancoTrofeo:       return (0.92, 0.91, 0.85)
        case .bluMisano:          return (0.04, 0.45, 0.86)
        case .bluAnodizzato:      return (0.13, 0.31, 0.43)
        case .biancoLunare:       return (0.73, 0.73, 0.69)
        case .ocraGTJunior:       return (0.78, 0.48, 0.06)
        case .rossoVillaDEste:    return (0.48, 0.04, 0.06)
        case .verdeMontreal:      return (0.05, 0.45, 0.30)
        case .verdeVisconti:      return (0.12, 0.38, 0.22)
        case .rossoEtna:          return (0.59, 0.05, 0.04)
        case .grigioMoonlight:    return (0.39, 0.41, 0.43)
        }
    }
}

/// Telemetry cards that the driver can choose to show on the main page.
enum DashboardMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case distanceSinceRegeneration
    case exhaustTemperature
    case coolantTemperature
    case regenerationProgress
    case totalRegenerations
    case oilPressure
    case batteryVoltage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .distanceSinceRegeneration: return AppLocalization.string("Distanza dall’ultima rigenerazione")
        case .exhaustTemperature: return AppLocalization.string("Temperatura gas di scarico")
        case .coolantTemperature: return AppLocalization.string("Temperatura liquido motore")
        case .regenerationProgress: return AppLocalization.string("Avanzamento rigenerazione")
        case .totalRegenerations: return AppLocalization.string("Rigenerazioni totali")
        case .oilPressure: return AppLocalization.string("Stato pressione olio")
        case .batteryVoltage: return AppLocalization.string("Batteria")
        }
    }
}

/// FCA source that supplied the IBS state of charge. The direct IBS ECU is
/// preferred; the engine-ECU mirror exists as a compatibility fallback.
enum BatteryStateOfChargeSource: String, Codable, Equatable, Sendable {
    case ibsDirect
    case engineECUMirror

    var pid: DPFPID {
        switch self {
        case .ibsDirect: return .batteryStateOfChargeDirect
        case .engineECUMirror: return .batteryStateOfChargeMirror
        }
    }

    var requestHeader: String {
        switch self {
        case .ibsDirect: return "18DA40F1"
        case .engineECUMirror: return "18DA10F1"
        }
    }
}

/// Live DPF state derived from the ECU. All fields optional — not every ECU
/// exposes every signal, and we never fabricate values.
struct DPFState: Codable, Equatable, Sendable {
    /// FCA's proprietary calculated DPF-load index. Community definitions
    /// expose it as a percentage, but it is not a universal physical
    /// saturation measurement and must not be compared blindly across apps.
    var cloggingPercent: Double?
    var exhaustTempC: Double?
    var coolantTemperatureC: Double?
    var distanceSinceLastRegenKm: Double?
    var regenProgressPercent: Double?     // 0 when idle, >0 while a regen is running
    var totalRegenCount: Double?
    var regenActive: Bool?                // derived: progress > hysteresis
    var regenerationMode: DPFRegenerationMode?
    /// EDC17C69 exposes a pressure state, not a trustworthy pressure in bar.
    var oilPressureStatusRaw: UInt8?
    /// Supply voltage reported by the ELM327 (`ATRV`). This is the adapter's
    /// measured vehicle voltage, not an Alfa-specific ECU PID.
    var batteryVoltage: Double?
    /// Battery state of charge reported by the IBS, in the inclusive 0...100
    /// percent range. Unsupported, malformed and out-of-range replies stay nil.
    var batteryStateOfChargePercent: Double?
    var batteryStateOfChargeSource: BatteryStateOfChargeSource?
    var batteryStateOfChargeUpdatedAt: Date?
    /// PID that supplied `exhaustTempC`, retained for diagnostics.
    var exhaustTemperaturePID: UInt16?
    /// Audit data for the load value. Persisting it makes an on-road
    /// comparison diagnosable later without Xcode attached.
    var cloggingRaw: UInt32?
    var cloggingECUHeader: String?
    var cloggingSourceVerified: Bool?
    var timestamp: Date = .init()
}

extension DPFState {
    /// True when at least one real ECU value can be shown. The timestamp alone
    /// never turns an empty state into a cached dashboard.
    var hasTelemetry: Bool {
        cloggingPercent != nil
            || exhaustTempC != nil
            || coolantTemperatureC != nil
            || distanceSinceLastRegenKm != nil
            || regenProgressPercent != nil
            || totalRegenCount != nil
            || regenerationMode != nil
            || oilPressureStatusRaw != nil
            || batteryVoltage != nil
            || batteryStateOfChargePercent != nil
    }

    /// Prefer the dedicated ECU state when it reports a regeneration, while
    /// preserving the existing detector as a fallback if the PID says idle or
    /// is unsupported on a specific ECU.
    var effectiveRegenerationMode: DPFRegenerationMode {
        if regenActive == true { return .active }
        if regenerationMode == .passive { return .passive }
        if regenerationMode == .active { return .active }
        return .none
    }

    var isRegenerating: Bool {
        effectiveRegenerationMode != .none
    }

    var loadAlertLevel: DPFLoadAlertLevel {
        .resolve(
            loadPercent: cloggingPercent,
            regenerationMode: effectiveRegenerationMode
        )
    }

    /// The diesel ECU's public diagnostic value is categorical. Showing a
    /// made-up number in bar would be less useful than reporting its real
    /// state and leaving unknown variants explicit.
    var oilPressureStatusText: String? {
        guard let oilPressureStatusRaw else { return nil }
        switch oilPressureStatusRaw {
        case 0: return AppLocalization.string("Assente")
        case 1: return AppLocalization.string("Non significativa")
        case 2: return AppLocalization.string("Normale")
        default:
            return String(
                format: AppLocalization.string("Stato %@"),
                String(oilPressureStatusRaw)
            )
        }
    }

    /// Prevents an old optional IBS sample from being presented beside live
    /// core telemetry. The cached value remains serializable for diagnostics.
    func freshBatteryStateOfChargePercent(
        at now: Date = .init(),
        maximumAge: TimeInterval = 30
    ) -> Double? {
        guard let value = batteryStateOfChargePercent,
              let updatedAt = batteryStateOfChargeUpdatedAt,
              now.timeIntervalSince(updatedAt) <= maximumAge,
              updatedAt.timeIntervalSince(now) <= 1,
              (0...100).contains(value)
        else { return nil }
        return value
    }

    /// Applies only values that were actually read in the new sample.
    /// `nil` means “not refreshed”, never “replace the last valid value”.
    func mergingFreshTelemetry(from fresh: DPFState) -> DPFState {
        var merged = self
        merged.cloggingPercent = fresh.cloggingPercent ?? cloggingPercent
        merged.exhaustTempC = fresh.exhaustTempC ?? exhaustTempC
        merged.coolantTemperatureC = fresh.coolantTemperatureC ?? coolantTemperatureC
        merged.distanceSinceLastRegenKm =
            fresh.distanceSinceLastRegenKm ?? distanceSinceLastRegenKm
        merged.regenProgressPercent =
            fresh.regenProgressPercent ?? regenProgressPercent
        merged.totalRegenCount = fresh.totalRegenCount ?? totalRegenCount
        merged.regenerationMode = fresh.regenerationMode ?? regenerationMode
        merged.oilPressureStatusRaw =
            fresh.oilPressureStatusRaw ?? oilPressureStatusRaw
        merged.batteryVoltage = fresh.batteryVoltage ?? batteryVoltage
        if fresh.batteryStateOfChargePercent != nil {
            merged.batteryStateOfChargePercent = fresh.batteryStateOfChargePercent
            merged.batteryStateOfChargeSource = fresh.batteryStateOfChargeSource
            merged.batteryStateOfChargeUpdatedAt = fresh.batteryStateOfChargeUpdatedAt
        }
        if fresh.exhaustTempC != nil {
            merged.exhaustTemperaturePID = fresh.exhaustTemperaturePID
        }
        if fresh.cloggingPercent != nil {
            merged.cloggingRaw = fresh.cloggingRaw
            merged.cloggingECUHeader = fresh.cloggingECUHeader
            merged.cloggingSourceVerified = fresh.cloggingSourceVerified
        }
        if fresh.regenActive != nil {
            merged.regenActive = fresh.regenActive
        }
        if fresh.hasTelemetry {
            merged.timestamp = fresh.timestamp
        }
        return merged
    }
}

/// Pure presentation policy shared by the iPhone and CarPlay battery tiles.
/// A valid, fresh IBS reading wins only while telemetry is live; otherwise the
/// adapter voltage remains the truthful fallback instead of exposing stale or
/// malformed state of charge as a percentage.
enum BatteryMetricHeadline: Equatable, Sendable {
    case stateOfChargePercent(Double)
    case voltage(Double)
    case unavailable
}

struct BatteryMetricPresentation: Equatable, Sendable {
    var headline: BatteryMetricHeadline
    var voltageDetail: Double?

    static func resolve(
        state: DPFState,
        isLive: Bool,
        at now: Date = .init()
    ) -> BatteryMetricPresentation {
        if isLive, let percent = state.freshBatteryStateOfChargePercent(at: now) {
            return .init(
                headline: .stateOfChargePercent(percent),
                voltageDetail: state.batteryVoltage
            )
        }
        if let voltage = state.batteryVoltage {
            return .init(headline: .voltage(voltage), voltageDetail: nil)
        }
        return .init(headline: .unavailable, voltageDetail: nil)
    }
}

/// Coolant samples are optional, plausibility checked and short-lived. Keeping
/// this policy pure makes missing/invalid/expired behavior testable.
enum CoolantTelemetryPolicy {
    static let validRangeCelsius = -40.0...215.0
    static let liveTTL: TimeInterval = 30

    static func validated(_ value: Double) throws -> Double {
        guard value.isFinite, validRangeCelsius.contains(value) else {
            throw OBDError.protocolError("invalid coolant temperature")
        }
        return value
    }

    static func isExpired(lastValidSampleAt: Date?, now: Date) -> Bool {
        guard let lastValidSampleAt else { return false }
        return now.timeIntervalSince(lastValidSampleAt) >= liveTTL
    }
}

/// One-shot dashboard migration: existing users see a newly introduced card
/// once, while a later manual opt-out remains respected.
enum DashboardMetricPreference {
    static func load(
        stored: [String]?,
        migrated: Bool,
        adding metric: DashboardMetric
    ) -> (visible: Set<DashboardMetric>, didMigrate: Bool) {
        guard let stored else { return (Set(DashboardMetric.allCases), true) }
        var visible = Set(stored.compactMap(DashboardMetric.init(rawValue:)))
        if !migrated { visible.insert(metric) }
        return (visible, !migrated)
    }
}

/// Public destination for voluntary project support. The contribution never
/// unlocks app content or functionality.
enum ProjectSupport {
    static let donationURL = URL(string: "https://ko-fi.com/eddytamburi")!
}

/// Persists the cold-launch threshold for the optional project-support prompt.
/// Presentation is marked separately so a first-run system permission flow can
/// delay the prompt without losing it.
enum ProjectSupportPromptPolicy {
    static let launchThreshold = 10
    private static let launchCountKey = "projectSupportLaunchCount.v1"
    private static let promptPresentedKey = "projectSupportPromptPresented.v1"

    static func registerLaunch(in defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: promptPresentedKey) else { return false }

        let launchCount = defaults.integer(forKey: launchCountKey) + 1
        defaults.set(launchCount, forKey: launchCountKey)
        return launchCount >= launchThreshold
    }

    static func markPresented(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: promptPresentedKey)
    }
}

/// Small local cache used only to restore the last real ECU snapshot. No
/// simulated values are written and nothing leaves the device.
enum DPFStateStore {
    private static let defaultsKey = "lastRealDPFState.v1"

    static func load(from defaults: UserDefaults = .standard) -> DPFState? {
        guard let data = defaults.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(DPFState.self, from: data),
              state.hasTelemetry
        else { return nil }
        return state
    }

    static func save(_ state: DPFState, to defaults: UserDefaults = .standard) {
        guard state.hasTelemetry, let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

/// Repeatable data sets used by the in-app Test Lab. They deliberately feed
/// the same `DPFState` and regeneration state machine used by the real ECU, so
/// the UI, Live Activity and notifications can be exercised without a car.
enum DPFSimulationScenario: String, CaseIterable, Identifiable {
    case clean
    case loaded
    case regenStarted
    case regenInProgress
    case regenFinished
    case unavailable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean:           return "DPF pulito"
        case .loaded:          return "Carico elevato"
        case .regenStarted:    return "Inizio rigenerazione"
        case .regenInProgress: return "Rigenerazione al 52%"
        case .regenFinished:   return "Fine rigenerazione"
        case .unavailable:     return "Dati assenti"
        }
    }

    var detail: String {
        switch self {
        case .clean:           return "28% · temperatura normale"
        case .loaded:          return "88% · rigenerazione vicina"
        case .regenStarted:    return "96% · deve suonare l'avviso"
        case .regenInProgress: return "72% · scarico caldo"
        case .regenFinished:   return "32% · deve suonare la fine"
        case .unavailable:     return "Verifica trattini e stato sconosciuto"
        }
    }

    var symbol: String {
        switch self {
        case .clean:           return "checkmark.circle.fill"
        case .loaded:          return "exclamationmark.triangle.fill"
        case .regenStarted:    return "flame.fill"
        case .regenInProgress: return "arrow.triangle.2.circlepath"
        case .regenFinished:   return "flag.checkered"
        case .unavailable:     return "questionmark.circle"
        }
    }

    func state(at timestamp: Date = .init()) -> DPFState {
        switch self {
        case .clean:
            return DPFState(
                cloggingPercent: 28,
                exhaustTempC: 168,
                coolantTemperatureC: 88,
                distanceSinceLastRegenKm: 35,
                regenProgressPercent: 0,
                totalRegenCount: 291,
                regenActive: false,
                regenerationMode: DPFRegenerationMode.none,
                oilPressureStatusRaw: 2,
                batteryVoltage: 12.6,
                batteryStateOfChargePercent: 82,
                batteryStateOfChargeSource: .ibsDirect,
                batteryStateOfChargeUpdatedAt: timestamp,
                timestamp: timestamp
            )
        case .loaded:
            return DPFState(
                cloggingPercent: 88,
                exhaustTempC: 238,
                coolantTemperatureC: 94,
                distanceSinceLastRegenKm: 410,
                regenProgressPercent: 0,
                totalRegenCount: 291,
                regenActive: false,
                regenerationMode: DPFRegenerationMode.none,
                oilPressureStatusRaw: 2,
                batteryVoltage: 14.2,
                batteryStateOfChargePercent: 74,
                batteryStateOfChargeSource: .ibsDirect,
                batteryStateOfChargeUpdatedAt: timestamp,
                timestamp: timestamp
            )
        case .regenStarted:
            return DPFState(
                cloggingPercent: 96,
                exhaustTempC: 575,
                coolantTemperatureC: 96,
                distanceSinceLastRegenKm: 414,
                regenProgressPercent: 1.5,
                totalRegenCount: 291,
                regenActive: true,
                regenerationMode: .active,
                oilPressureStatusRaw: 2,
                batteryVoltage: 14.1,
                batteryStateOfChargePercent: 71,
                batteryStateOfChargeSource: .ibsDirect,
                batteryStateOfChargeUpdatedAt: timestamp,
                timestamp: timestamp
            )
        case .regenInProgress:
            return DPFState(
                cloggingPercent: 72,
                exhaustTempC: 648,
                coolantTemperatureC: 98,
                distanceSinceLastRegenKm: 419,
                regenProgressPercent: 52,
                totalRegenCount: 291,
                regenActive: true,
                regenerationMode: .active,
                oilPressureStatusRaw: 2,
                batteryVoltage: 14.0,
                batteryStateOfChargePercent: 70,
                batteryStateOfChargeSource: .ibsDirect,
                batteryStateOfChargeUpdatedAt: timestamp,
                timestamp: timestamp
            )
        case .regenFinished:
            return DPFState(
                cloggingPercent: 32,
                exhaustTempC: 408,
                coolantTemperatureC: 97,
                distanceSinceLastRegenKm: 0.3,
                regenProgressPercent: 0,
                totalRegenCount: 292,
                regenActive: false,
                regenerationMode: DPFRegenerationMode.none,
                oilPressureStatusRaw: 2,
                batteryVoltage: 13.9,
                batteryStateOfChargePercent: 69,
                batteryStateOfChargeSource: .ibsDirect,
                batteryStateOfChargeUpdatedAt: timestamp,
                timestamp: timestamp
            )
        case .unavailable:
            return DPFState(timestamp: timestamp)
        }
    }
}

enum RegenEvent: Equatable {
    case started(at: Date, cloggingPercent: Double?)
    case finished(at: Date, duration: TimeInterval)
}

/// Conservative remaining-time estimate for an active regeneration. The ECU
/// exposes progress, not an ETA, so this estimator only publishes a value
/// after observing a meaningful increase over time. Missing samples preserve
/// the last estimate; an inactive mode or a new progress cycle clears it.
struct RegenTimeEstimator: Equatable, Sendable {
    private struct Sample: Equatable, Sendable {
        let progress: Double
        let timestamp: Date
    }

    private static let minimumProgressDelta = 2.0
    private static let minimumObservationDuration: TimeInterval = 30
    private static let maximumSampleGap: TimeInterval = 10 * 60
    private static let minimumPublishedETA: TimeInterval = 60
    private static let maximumPublishedETA: TimeInterval = 60 * 60
    // Keep enough history for fast adapters too: at one fresh sample per
    // second, eight samples could never satisfy the 30-second observation
    // window and the ETA would remain permanently hidden.
    private static let maximumSamples = 120

    private var samples: [Sample] = []
    private(set) var estimatedTimeRemaining: TimeInterval?

    @discardableResult
    mutating func observe(
        progressPercent: Double?,
        regenerationMode: DPFRegenerationMode,
        at timestamp: Date
    ) -> TimeInterval? {
        guard regenerationMode == .active else {
            reset()
            return nil
        }

        guard let progressPercent,
              progressPercent.isFinite,
              (0...100).contains(progressPercent)
        else {
            if let last = samples.last {
                let gap = timestamp.timeIntervalSince(last.timestamp)
                if gap < 0 || gap > Self.maximumSampleGap {
                    reset()
                }
            }
            return estimatedTimeRemaining
        }

        if progressPercent >= 99.5 {
            estimatedTimeRemaining = nil
            return nil
        }

        if let last = samples.last {
            let gap = timestamp.timeIntervalSince(last.timestamp)
            if gap < 0 || gap > Self.maximumSampleGap || progressPercent < last.progress - 2 {
                reset()
            } else if progressPercent <= last.progress + 0.05 {
                return estimatedTimeRemaining
            }
        }

        samples.append(Sample(progress: progressPercent, timestamp: timestamp))
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }

        guard let first = samples.first, let last = samples.last else { return nil }
        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        let progressDelta = last.progress - first.progress
        guard duration >= Self.minimumObservationDuration,
              progressDelta >= Self.minimumProgressDelta
        else {
            return nil
        }

        let progressPerSecond = progressDelta / duration
        let rawETA = (100 - last.progress) / progressPerSecond
        guard rawETA >= Self.minimumPublishedETA,
              rawETA <= Self.maximumPublishedETA
        else {
            estimatedTimeRemaining = nil
            return nil
        }

        if let previous = estimatedTimeRemaining {
            estimatedTimeRemaining = previous * 0.65 + rawETA * 0.35
        } else {
            estimatedTimeRemaining = rawETA
        }
        return estimatedTimeRemaining
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        estimatedTimeRemaining = nil
    }
}

/// Keeps the history layer tri-state. `nil` means the latest poll could not
/// prove either active or inactive and must never be converted into a finish
/// edge. This is intentionally separate from UI presentation, where unknown
/// may still use neutral styling.
struct RegenHistoryTransition: Equatable, Sendable {
    let previousKnownState: Bool?
    let nextKnownState: Bool?
    let didStart: Bool
    let didFinish: Bool
    let confirmedInitialInactivity: Bool

    static func resolve(previous: Bool?, observed: Bool?) -> Self {
        guard let observed else {
            return Self(
                previousKnownState: previous,
                nextKnownState: previous,
                didStart: false,
                didFinish: false,
                confirmedInitialInactivity: false
            )
        }

        return Self(
            previousKnownState: previous,
            nextKnownState: observed,
            didStart: observed && previous != true,
            didFinish: !observed && previous == true,
            confirmedInitialInactivity: !observed && previous == nil
        )
    }
}

/// Converts the continuous ECU "regen process" percentage into stable
/// start/finish edges. It deliberately keeps its state across missing samples:
/// a transient OBD timeout must not create a second start alert when data
/// resumes. A first valid active sample does emit `.started`, so connecting a
/// few seconds after the ECU began regenerating still warns the driver.
struct RegenActivityTracker {
    private static let startThresholdPercent = 0.01
    private static let stopThresholdPercent = 0.001
    /// FCA variants that don't expose a useful progress PID can still be
    /// identified conservatively: during an active burn the exhaust is hot
    /// while the calculated soot load falls steadily.
    private static let inferredStartTemperatureC = 500.0
    private static let inferredStopTemperatureC = 460.0
    /// A just-completed regeneration remains above 500 °C while the soot index
    /// sits near 20 and may keep falling. Requiring a loaded-filter baseline
    /// prevents that cool-down tail (or a reconnect during it) from becoming
    /// a second, false start notification.
    private static let inferredMinimumStartingLoad = 80.0
    private static let inferredMinimumLoadDrop = 1.0
    private static let inferredDeclineSamples = 3
    private static let inferredCoolSamplesToFinish = 3
    private static let maximumCandidateGap: TimeInterval = 90

    private enum Evidence {
        case modePID
        case progressPID
        case thermalLoadTrend
    }

    private(set) var isActive: Bool?
    private var startedAt: Date?
    private var evidence: Evidence?
    private var hotCandidateStartedAt: Date?
    private var hotCandidatePeakLoad: Double?
    private var hotCandidatePreviousLoad: Double?
    private var hotCandidateDeclineCount = 0
    private var hotCandidateLastSampleAt: Date?
    private var consecutiveCoolSamples = 0

    mutating func observe(progressPercent: Double?,
                          at timestamp: Date,
                          cloggingPercent: Double?,
                          exhaustTemperatureC: Double? = nil,
                          regenerationMode: DPFRegenerationMode? = nil) -> RegenEvent? {
        let validProgress = progressPercent.flatMap { $0.isFinite ? $0 : nil }

        if isActive == true {
            if validProgress.map({ $0 >= Self.startThresholdPercent }) == true {
                // An inferred transition can later be confirmed by the
                // dedicated PID; from that point its zero edge is definitive.
                evidence = .progressPID
                consecutiveCoolSamples = 0
                return nil
            }

            if regenerationMode == .active {
                evidence = .modePID
                consecutiveCoolSamples = 0
                return nil
            }

            switch evidence {
            case .modePID:
                // A missing optional PID must not manufacture a finish edge.
                if regenerationMode == nil {
                    guard inferredBurnHasFinished(
                        exhaustTemperatureC: exhaustTemperatureC
                    ) else { return nil }
                } else {
                    guard regenerationMode == DPFRegenerationMode.none
                            || regenerationMode == .passive
                    else {
                        return nil
                    }
                }
            case .progressPID:
                guard validProgress.map({ $0 <= Self.stopThresholdPercent }) == true else {
                    return nil
                }
            case .thermalLoadTrend:
                guard inferredBurnHasFinished(exhaustTemperatureC: exhaustTemperatureC) else {
                    return nil
                }
            case nil:
                return nil
            }

            isActive = false
            guard let startedAt else { return nil }
            self.startedAt = nil
            evidence = nil
            resetHotCandidate()
            return .finished(
                at: timestamp,
                duration: timestamp.timeIntervalSince(startedAt)
            )
        }

        if validProgress.map({ $0 >= Self.startThresholdPercent }) == true {
            isActive = true
            startedAt = timestamp
            evidence = .progressPID
            consecutiveCoolSamples = 0
            resetHotCandidate()
            return .started(at: timestamp, cloggingPercent: cloggingPercent)
        }

        if regenerationMode == .active {
            isActive = true
            startedAt = timestamp
            evidence = .modePID
            consecutiveCoolSamples = 0
            resetHotCandidate()
            return .started(at: timestamp, cloggingPercent: cloggingPercent)
        }

        if let inferredStart = observeHotLoadTrend(
            cloggingPercent: cloggingPercent,
            exhaustTemperatureC: exhaustTemperatureC,
            at: timestamp
        ) {
            isActive = true
            startedAt = inferredStart
            evidence = .thermalLoadTrend
            consecutiveCoolSamples = 0
            return .started(at: inferredStart, cloggingPercent: cloggingPercent)
        }

        // Preserve unknown when no trustworthy input exists. A missing sample
        // must not fabricate an idle edge or erase an in-progress candidate.
        guard validProgress != nil
                || exhaustTemperatureC != nil
                || cloggingPercent != nil
                || regenerationMode != nil
        else {
            return nil
        }
        isActive = false
        return nil
    }

    private mutating func observeHotLoadTrend(
        cloggingPercent: Double?,
        exhaustTemperatureC: Double?,
        at timestamp: Date
    ) -> Date? {
        guard let temperature = exhaustTemperatureC,
              temperature.isFinite,
              let load = cloggingPercent,
              load.isFinite
        else { return nil }

        guard temperature >= Self.inferredStartTemperatureC else {
            resetHotCandidate()
            return nil
        }

        if let last = hotCandidateLastSampleAt,
           timestamp.timeIntervalSince(last) > Self.maximumCandidateGap {
            resetHotCandidate()
        }

        if hotCandidateStartedAt == nil {
            guard load >= Self.inferredMinimumStartingLoad else {
                resetHotCandidate()
                return nil
            }
            hotCandidateStartedAt = timestamp
            hotCandidatePeakLoad = load
            hotCandidatePreviousLoad = load
            hotCandidateLastSampleAt = timestamp
            return nil
        }

        hotCandidatePeakLoad = max(hotCandidatePeakLoad ?? load, load)
        if let previous = hotCandidatePreviousLoad, load < previous - 0.02 {
            hotCandidateDeclineCount += 1
        } else if let previous = hotCandidatePreviousLoad, load > previous + 0.10 {
            hotCandidateDeclineCount = 0
        }
        hotCandidatePreviousLoad = load
        hotCandidateLastSampleAt = timestamp

        let totalDrop = (hotCandidatePeakLoad ?? load) - load
        guard totalDrop >= Self.inferredMinimumLoadDrop,
              hotCandidateDeclineCount >= Self.inferredDeclineSamples
        else { return nil }

        return hotCandidateStartedAt
    }

    private mutating func inferredBurnHasFinished(
        exhaustTemperatureC: Double?
    ) -> Bool {
        guard let temperature = exhaustTemperatureC, temperature.isFinite else {
            return false
        }
        if temperature <= Self.inferredStopTemperatureC {
            consecutiveCoolSamples += 1
        } else {
            consecutiveCoolSamples = 0
        }
        return consecutiveCoolSamples >= Self.inferredCoolSamplesToFinish
    }

    private mutating func resetHotCandidate() {
        hotCandidateStartedAt = nil
        hotCandidatePeakLoad = nil
        hotCandidatePreviousLoad = nil
        hotCandidateDeclineCount = 0
        hotCandidateLastSampleAt = nil
    }
}

/// Alfa / FCA Mode 22 PIDs used for DPF monitoring.
///
/// The definitions below are community-validated on Giulia/Stelvio EDC17C69.
/// Optional signals are probed independently: `NO DATA` means unsupported on
/// that ECU and must never invalidate the established core telemetry.
///
/// Sources:
/// - https://github.com/danardi78/Alfaromeo-Giulia-Stelvio-PIDs
enum DPFPID: UInt16, Hashable, Sendable {
    case cloggingPercent      = 0x18E4
    case exhaustTempC         = 0x18DE
    case postDPFTempC         = 0x3915
    case totalRegenCount      = 0x18A4
    case regenProgressPercent = 0x380B
    case distanceSinceRegenKm = 0x3807
    case oilPressureStatus    = 0x194D
    case batteryStateOfChargeDirect = 0x1005
    case batteryStateOfChargeMirror = 0x19BD
    case coolantTemperatureC  = 0x1003

    var mode: UInt8 { 0x22 }

    var command: String {
        String(format: "22%04X", rawValue)
    }

    var formulaDescription: String {
        switch self {
        case .cloggingPercent:
            return "raw×1000/65535"
        case .exhaustTempC, .postDPFTempC, .coolantTemperatureC:
            return "raw×0.02−40 °C"
        case .totalRegenCount:
            return "raw"
        case .regenProgressPercent:
            return "raw×100/65535"
        case .distanceSinceRegenKm:
            return "raw24×0.1 km"
        case .oilPressureStatus:
            return "stato ECU"
        case .batteryStateOfChargeDirect:
            return "byte B, 0...100%"
        case .batteryStateOfChargeMirror:
            return "byte A, 0...100%"
        }
    }

    func integerRawValue(bytes: [UInt8]) throws -> UInt32 {
        if self == .distanceSinceRegenKm {
            guard bytes.count >= 3 else {
                throw OBDError.protocolError("\(self) needs at least 3 bytes")
            }
            return UInt32(bytes[0]) << 16 |
                UInt32(bytes[1]) << 8 |
                UInt32(bytes[2])
        }

        if self == .oilPressureStatus {
            guard let first = bytes.first else {
                throw OBDError.protocolError("\(self) needs at least 1 byte")
            }
            return UInt32(first)
        }

        if self == .batteryStateOfChargeDirect {
            guard bytes.count >= 2 else {
                throw OBDError.protocolError("\(self) needs at least 2 bytes")
            }
            return UInt32(bytes[1])
        }

        if self == .batteryStateOfChargeMirror {
            guard let first = bytes.first else {
                throw OBDError.protocolError("\(self) needs at least 1 byte")
            }
            return UInt32(first)
        }

        guard bytes.count >= 2 else {
            throw OBDError.protocolError("\(self) needs at least 2 bytes")
        }
        return UInt32(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
    }

    /// Decodes a positive response payload (bytes after mode+pid echo) into
    /// a physical value. Distance is a three-byte value; the other signals
    /// are big-endian uint16 values.
    func decode(bytes: [UInt8]) throws -> Double {
        let raw = Double(try integerRawValue(bytes: bytes))
        switch self {
        // Exact published FCA/Torque equation. Keep the factor expressed as
        // a ratio: the rounded 0.01526 obscured provenance during comparisons.
        case .cloggingPercent:      return raw * (1000.0 / 65_535.0)
        case .exhaustTempC,
             .postDPFTempC:         return raw * 0.02 - 40.0
        case .coolantTemperatureC:
            return try CoolantTelemetryPolicy.validated(raw * 0.02 - 40.0)
        case .totalRegenCount:      return raw
        case .regenProgressPercent: return raw * (100.0 / 65_535.0)
        case .distanceSinceRegenKm: return raw * 0.1
        case .oilPressureStatus:    return raw
        case .batteryStateOfChargeDirect,
             .batteryStateOfChargeMirror:
            guard raw <= 100 else {
                throw OBDError.protocolError("invalid IBS state of charge \(Int(raw))%")
            }
            return raw
        }
    }
}

/// Validated ECU routing hints for one adapter endpoint. These are performance
/// hints, never trusted data: DPFMonitor retries the full FCA header list when
/// a remembered route does not answer on the current vehicle.
struct DPFECUProfile: Codable, Equatable, Sendable {
    var headersByPID: [String: String] = [:]
    var lastGoodHeader: String?
    var preferredExhaustTemperaturePID: UInt16?
    var preferredBatteryStateOfChargeSource: BatteryStateOfChargeSource?
}

final class DPFECUProfileStore: @unchecked Sendable {
    private static let keyPrefix = "dpfECUProfile.v1."
    private let defaults: UserDefaults
    private let key: String

    init(identifier: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = Self.keyPrefix + identifier
    }

    func load() -> DPFECUProfile? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DPFECUProfile.self, from: data)
    }

    func save(_ profile: DPFECUProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: key)
    }
}
