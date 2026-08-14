import SwiftUI
import UIKit
import UserNotifications
import Charts
import Accessibility

/// iOS normally hides local notifications while the app is open. Presenting
/// them explicitly is essential here: a regeneration must still create a
/// visible banner and an audible system alert while the dashboard is visible.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

@main
struct AlfaDPFApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = MonitorSession.shared

    var body: some Scene {
        WindowGroup {
            PhoneRootView(session: session)
                .preferredColorScheme(.dark)
                .environment(\.locale, session.appLanguage.locale)
                .environment(\.appAccent, session.appAccent.color)
                .tint(session.appAccent.color)
        }
    }
}

// MARK: - Visual language

private enum Brand {
    /// Semantic red used only for dangerous/high-load states.
    static let redBright = Color(red: 1.00, green: 0.27, blue: 0.31)
    static let ink = Color(red: 0.025, green: 0.025, blue: 0.035)
    static let panel = Color(red: 0.10, green: 0.10, blue: 0.13)
    static let textDim = Color.white.opacity(0.55)
    static let hairline = Color.white.opacity(0.12)
}

private struct AppAccentKey: EnvironmentKey {
    static let defaultValue = StelvioAccent.rossoAlfa.color
}

private extension EnvironmentValues {
    var appAccent: Color {
        get { self[AppAccentKey.self] }
        set { self[AppAccentKey.self] = newValue }
    }
}

private extension StelvioAccent {
    var color: Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    var brightColor: Color {
        Color(
            red: min(rgb.red * 1.18 + 0.04, 1),
            green: min(rgb.green * 1.18 + 0.04, 1),
            blue: min(rgb.blue * 1.18 + 0.04, 1)
        )
    }
}

private enum AppLinks {
    static let privacy = URL(string: "https://dpf-monitor-support.etamburi.chatgpt.site/privacy")!
    static let support = URL(string: "https://dpf-monitor-support.etamburi.chatgpt.site/support")!
    static let email = URL(string: "mailto:tamburiukeddy+alfadpf@gmail.com")!
}

private extension View {
    /// A restrained Liquid Glass-inspired surface that remains compatible
    /// with the iOS 17 deployment target. On newer iOS versions the system
    /// material automatically adopts the current glass rendering language.
    func glassPanel(cornerRadius: CGFloat = 26) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.025))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.035)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
    }

    /// Static dashboard surfaces avoid the per-frame backdrop sampling of
    /// Material. Repeated cards use this cheaper treatment so scrolling stays
    /// smooth while the hero and connection controls retain the glass accent.
    func dashboardTile(cornerRadius: CGFloat = 22) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(red: 0.105, green: 0.115, blue: 0.145).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.white.opacity(0.045)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: .black.opacity(0.14), radius: 5, y: 3)
    }
}

// MARK: - Root

struct PhoneRootView: View {
    @Bindable var session: MonitorSession
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showSettings = false
    @State private var showTestLab = false
    @State private var showAbout = false
    @State private var showNotificationSetup = false
    @State private var showProjectSupportPrompt = false
    @State private var projectSupportPromptPending = false
    @State private var preparedLaunch = false
    @State private var appliedDebugLaunchScenario = false
    @State private var showHistory = false

    var body: some View {
        ZStack {
            DashboardBackground()

            ScrollView {
                VStack(spacing: 18) {
                    HeaderBar(
                        status: session.status,
                        onSettings: { showSettings = true },
                        onAbout: { showAbout = true }
                    )

                    if dynamicTypeSize.isAccessibilitySize,
                       !embedsConnectionDock {
                        ConnectionDock(session: session)
                    }

                    if session.alertAuthorization.needsSettingsAttention {
                        NotificationGuidanceCard(state: session.alertAuthorization)
                    }

                    if session.isShowingCachedTelemetry {
                        CachedStateStrip(updatedAt: session.dpf.timestamp)
                    }

                    if session.isAwaitingTelemetry {
                        TelemetryLoadingStrip(isConnected: session.status == .running)
                    }

                    HeroGauge(
                        dpf: session.dpf,
                        isCached: session.isShowingCachedTelemetry,
                        isSessionActive: session.status == .running || session.status == .simulating,
                        isAwaitingTelemetry: session.isAwaitingTelemetry,
                        estimatedTimeRemaining: session.isShowingCachedTelemetry
                            ? nil
                            : session.estimatedRegenerationTimeRemaining
                    )

                    if session.dpf.hasTelemetry {
                        DPFDetailGrid(
                            dpf: session.dpf,
                            isCached: session.isShowingCachedTelemetry,
                            visibleMetrics: session.visibleDashboardMetrics
                        )
                    } else if !session.isAwaitingTelemetry {
                        DashboardEmptyCard(
                            isSimulation: session.status == .simulating,
                            onOpenLab: { showTestLab = true }
                        )
                    }

                    if session.historyStore != nil {
                        HistoryNavigationRow(
                            action: { showHistory = true },
                            store: session.historyStore
                        )
                    }

                    if let event = session.lastRegenEvent {
                        EventStrip(text: event, simulated: session.status == .simulating)
                    }

                    if embedsConnectionDock {
                        ConnectionDock(session: session)
                    }

                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !dynamicTypeSize.isAccessibilitySize,
               !embedsConnectionDock {
                ConnectionDock(session: session)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(session: session)
        }
        .sheet(isPresented: $showTestLab) {
            TestLabView(session: session)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAbout) {
            AboutSafetyView()
        }
        .fullScreenCover(isPresented: $showNotificationSetup) {
            NotificationSetupView(session: session) {
                showNotificationSetup = false
                session.startAutomaticallyIfNeeded()
            }
        }
        .fullScreenCover(isPresented: $showHistory) {
            DPFHistoryView(store: session.historyStore)
        }
        .alert("Ti piace Alpha DPF Monitor?", isPresented: $showProjectSupportPrompt) {
            Button("Sostieni con €4,99") {
                openURL(ProjectSupport.donationURL)
            }
            Button("No, grazie", role: .cancel) {}
        } message: {
            Text("L’app è gratuita e resterà gratuita. Un contributo facoltativo di €4,99 aiuta a coprire i costi annuali e a mantenere vivo il progetto. Non sblocca funzioni e non cambia l’esperienza.")
        }
        .task {
            guard !preparedLaunch else { return }
            preparedLaunch = true
            let shouldShowSupportPrompt = ProjectSupportPromptPolicy.registerLaunch()
            if await session.prepareNotificationAuthorizationAtLaunch() {
                projectSupportPromptPending = shouldShowSupportPrompt
                showNotificationSetup = true
            } else {
                session.startAutomaticallyIfNeeded()
                if shouldShowSupportPrompt {
                    presentProjectSupportPrompt()
                }
            }
        }
        .onChange(of: showNotificationSetup) { _, isPresented in
            guard !isPresented, projectSupportPromptPending else { return }
            projectSupportPromptPending = false
            presentProjectSupportPrompt()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await session.refreshNotificationAuthorization() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            session.persistCurrentState()
        }
        .onOpenURL { url in
            guard AppDeepLink.parse(url) == .monitor else { return }
            session.start()
        }
        .onAppear(perform: applyDebugLaunchScenarioIfNeeded)
        .sensoryFeedback(.success, trigger: session.status) { _, newStatus in
            newStatus == .running
        }
        .sensoryFeedback(.warning, trigger: session.isRegenerationInProgress) { wasActive, isActive in
            !wasActive && isActive
        }
    }

    private func presentProjectSupportPrompt() {
        ProjectSupportPromptPolicy.markPresented()
        showProjectSupportPrompt = true
    }

    private var embedsConnectionDock: Bool {
        session.status == .running || session.status == .simulating
    }

    private func applyDebugLaunchScenarioIfNeeded() {
#if DEBUG
        guard !appliedDebugLaunchScenario else { return }
        appliedDebugLaunchScenario = true
        let environment = ProcessInfo.processInfo.environment
        if environment["ALFADPF_AUTORUN_TEST"] == "1" {
            session.runSimulationSequence()
        } else if let raw = environment["ALFADPF_SCENARIO"],
                  let scenario = DPFSimulationScenario(rawValue: raw) {
            session.applySimulation(scenario)
        }
        switch environment["ALFADPF_SCREEN"] {
        case "testLab":
            showTestLab = true
        case "settings":
            showSettings = true
        case "about":
            showAbout = true
        case "history":
            showHistory = true
        default:
            break
        }
#endif
    }
}

private enum NotificationSetupPage {
    case permission
    case notificationSettings
    case drivingFocus
}

private struct NotificationSetupView: View {
    @Bindable var session: MonitorSession
    let onComplete: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var isRequesting = false
    @State private var page: NotificationSetupPage
    @Environment(\.appAccent) private var appAccent

    init(session: MonitorSession, onComplete: @escaping () -> Void) {
        self.session = session
        self.onComplete = onComplete

        let initialPage: NotificationSetupPage
        if session.alertAuthorization.authorization == .notDetermined {
            initialPage = .permission
        } else if !session.alertAuthorization.canSendTimeSensitiveAlerts {
            initialPage = .notificationSettings
        } else {
            initialPage = .drivingFocus
        }
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        ZStack {
            DashboardBackground()

            ScrollView {
                VStack(spacing: 24) {
                Image(systemName: setupIcon)
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(setupTint)
                    .frame(width: 112, height: 112)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.18)))

                VStack(spacing: 12) {
                    Text(title)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .multilineTextAlignment(.center)

                    Text(explanation)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 13) {
                    if page == .drivingFocus {
                        setupRow(
                            symbol: "shield.checkered",
                            title: "Mantieni attiva Full immersion Guida",
                            enabled: true
                        )
                        setupRow(
                            symbol: "bell.badge.fill",
                            title: "Gli avvisi urgenti restano soggetti alle impostazioni di iOS",
                            enabled: false
                        )
                        Text("Non modificare queste impostazioni durante la guida.")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        setupRow(
                            symbol: "bell.fill",
                            title: "Nel messaggio di iOS tocca “Consenti”",
                            enabled: session.alertAuthorization.authorization == .authorized
                        )
                        setupRow(
                            symbol: "exclamationmark.bubble.fill",
                            title: "Mantieni attive le “Notifiche urgenti”",
                            enabled: session.alertAuthorization.timeSensitiveEnabled
                        )
                        setupRow(
                            symbol: "car.fill",
                            title: "Per consentire gli annunci Siri quando supportati, attiva “Annuncia notifiche”",
                            enabled: session.alertAuthorization.siriAnnouncementsEnabled
                        )
                    }
                }
                .padding(18)
                .glassPanel(cornerRadius: 22)

                switch page {
                case .notificationSettings:
                    Button {
                        openNotificationSettings()
                    } label: {
                        Label("Apri Impostazioni", systemImage: "gear")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button("Continua nell’app") {
                        page = .drivingFocus
                    }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                case .permission:
                    Button {
                        isRequesting = true
                        Task {
                            await session.requestNotificationAuthorization()
                            isRequesting = false
                            if session.alertAuthorization.canSendTimeSensitiveAlerts {
                                page = .drivingFocus
                            } else {
                                page = .notificationSettings
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if isRequesting {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "bell.badge.fill")
                            }
                            Text("Attiva gli avvisi")
                        }
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(appAccent)
                    .disabled(isRequesting)

                    Button("Non ora") {
                        page = .drivingFocus
                    }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                case .drivingFocus:
                    Button {
                        session.acknowledgeDrivingFocusGuidance()
                        onComplete()
                    } label: {
                        Label("Ho capito, continua", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(appAccent)
                }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var explanation: LocalizedStringKey {
        switch page {
        case .permission:
            return "Gli avvisi di rigenerazione sono informazioni sensibili al tempo. Ti guidiamo una volta sola; poi l’app tenterà automaticamente la connessione all’OBD."
        case .notificationSettings:
            return "iOS non permette ad Alpha DPF Monitor di cambiare queste preferenze al posto tuo."
        case .drivingFocus:
            return "Full immersion Guida riduce le distrazioni. Mantienila attiva: gli avvisi di Alpha DPF Monitor sono solo un supporto e possono essere limitati da iOS."
        }
    }

    private var title: LocalizedStringKey {
        switch page {
        case .permission: return "Non perdere una rigenerazione"
        case .notificationSettings: return "Completa gli avvisi"
        case .drivingFocus: return "Full immersion Guida"
        }
    }

    private var setupIcon: String {
        switch page {
        case .permission: return "bell.and.waves.left.and.right.fill"
        case .notificationSettings: return "gear.badge"
        case .drivingFocus: return "car.side.fill"
        }
    }

    private var setupTint: Color {
        switch page {
        case .permission: return appAccent
        case .notificationSettings: return .orange
        case .drivingFocus: return .cyan
        }
    }

    private func setupRow(
        symbol: String,
        title: LocalizedStringKey,
        enabled: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: enabled ? "checkmark.circle.fill" : symbol)
                .foregroundStyle(enabled ? .green : .white.opacity(0.72))
                .frame(width: 24)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.82))
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        openURL(url)
    }
}

private struct NotificationGuidanceCard: View {
    let state: AlertAuthorizationState
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
            openURL(url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(LocalizedStringKey(detail))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.45))
            }
            .foregroundStyle(.white)
            .padding(15)
            .glassPanel(cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        if state.authorization == .denied { return "Notifiche disattivate" }
        if !state.alertEnabled || !state.lockScreenEnabled || !state.soundEnabled {
            return "Completa gli avvisi di iOS"
        }
        if !state.timeSensitiveEnabled { return "Attiva le notifiche urgenti" }
        return "Attiva la lettura con Siri"
    }

    private var detail: String {
        if state.authorization == .denied {
            return "Apri Impostazioni e consenti gli avvisi di rigenerazione."
        }
        if !state.alertEnabled || !state.lockScreenEnabled || !state.soundEnabled {
            return "Abilita avvisi, schermo bloccato e suoni per Alpha DPF Monitor."
        }
        if !state.timeSensitiveEnabled {
            return "In Impostazioni › Notifiche › Alpha DPF Monitor, abilita “Notifiche urgenti”."
        }
        return "Abilita “Annuncia notifiche” per Alpha DPF Monitor; l’app non può forzare la lettura."
    }
}

private struct CachedStateStrip: View {
    let updatedAt: Date

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
            VStack(alignment: .leading, spacing: 2) {
                Text("ULTIMO STATO SALVATO")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.4)
                Text(updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            Spacer()
            Text("NON LIVE")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .tracking(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.09), in: Capsule())
        }
        .foregroundStyle(.white.opacity(0.58))
        .padding(14)
        .glassPanel(cornerRadius: 18)
    }
}

private struct TelemetryLoadingStrip: View {
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(isConnected ? "Lettura dati DPF…" : "Connessione all’adattatore…"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(LocalizedStringKey(isConnected ? "Attendo i primi valori dalla centralina" : "Ricerca dell’ELM327 in corso"))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Brand.textDim)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white.opacity(0.86))
        .padding(14)
        .glassPanel(cornerRadius: 18)
        .accessibilityElement(children: .combine)
    }
}

private struct DashboardEmptyCard: View {
    let isSimulation: Bool
    let onOpenLab: () -> Void
    @Environment(\.appAccent) private var appAccent

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "gauge.with.dots.needle.0percent")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(appAccent)
                .frame(width: 54, height: 54)
                .background(appAccent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text(LocalizedStringKey(title))
                    .font(.headline.weight(.semibold))
                Text(LocalizedStringKey(detail))
                    .font(.subheadline)
                    .foregroundStyle(Brand.textDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onOpenLab) {
                Label(LocalizedStringKey(buttonTitle), systemImage: "testtube.2")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(appAccent)
        }
        .foregroundStyle(.white)
        .padding(18)
        .glassPanel(cornerRadius: 22)
    }

    private var title: String {
        isSimulation ? "Scenario dati assenti" : "Pronto per la prima lettura"
    }

    private var detail: String {
        isSimulation
            ? "Questo scenario verifica come l’app gestisce PID non disponibili. Scegli un altro stato per continuare la demo."
            : "Connetti l’adattatore dal comando qui sotto oppure esplora una rigenerazione simulata."
    }

    private var buttonTitle: String {
        isSimulation ? "Scegli un altro scenario" : "Esplora la demo"
    }
}

private struct DashboardBackground: View {
    @Environment(\.appAccent) private var appAccent

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.08, blue: 0.11), Brand.ink, .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [appAccent.opacity(0.12), appAccent.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: 165
            )
                .frame(width: 330, height: 330)
                .offset(x: -170, y: -330)
            RadialGradient(
                colors: [Color.orange.opacity(0.12), Color.orange.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: 140
            )
                .frame(width: 280, height: 280)
                .offset(x: 190, y: 330)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Header

private struct HeaderBar: View {
    let status: MonitorSession.Status
    let onSettings: () -> Void
    let onAbout: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(verbatim: "Alpha DPF")
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        controls
                    }
                    StatusBadge(status: status)
                }
            } else {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Alpha DPF Monitor")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        StatusBadge(status: status)
                    }

                    Spacer(minLength: 8)
                    controls
                }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        Group {
            RoundGlassButton(symbol: "gearshape.fill", action: onSettings)
                .accessibilityLabel("Impostazioni")
            RoundGlassButton(symbol: "info.circle", action: onAbout)
                .accessibilityLabel("Informazioni, sicurezza e privacy")
        }
    }
}

private struct RoundGlassButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().stroke(Brand.hairline, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }
}

private struct StatusBadge: View {
    let status: MonitorSession.Status

    var body: some View {
        let info = display
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(info.color.opacity(0.24))
                    .frame(width: 14, height: 14)
                Circle().fill(info.color).frame(width: 7, height: 7)
            }
            Text(LocalizedStringKey(info.label))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.9))
        .accessibilityElement(children: .combine)
    }

    private var display: (label: String, color: Color) {
        switch status {
        case .idle:       return ("Pronto", .gray)
        case .connecting: return ("Connessione", .orange)
        case .running:    return ("Live", .green)
        case .simulating: return ("Test", .cyan)
        case .failed:     return ("Errore", .red)
        }
    }

}

// MARK: - Main DPF gauge

private struct HeroGauge: View {
    let dpf: DPFState
    let isCached: Bool
    let isSessionActive: Bool
    let isAwaitingTelemetry: Bool
    let estimatedTimeRemaining: TimeInterval?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var scaledGaugeSize = 172.0

    private var load: Double { dpf.cloggingPercent ?? 0 }
    private var hasData: Bool { dpf.cloggingPercent != nil }
    private var gaugeSize: CGFloat { min(scaledGaugeSize, 210) }

    private var tint: Color {
        guard hasData else { return .gray }
        if isCached { return .gray }
        switch dpf.loadAlertLevel {
        case .unavailable: return .gray
        case .low: return .green
        case .nearRegeneration: return .orange
        case .regenerationImminent: return Brand.redBright
        case .activeRegeneration: return .orange
        }
    }

    private var loadLabel: String {
        switch dpf.loadAlertLevel {
        case .unavailable: return "Dati non disponibili"
        case .low: return "DPF pulito"
        case .nearRegeneration: return "Carico elevato"
        case .regenerationImminent: return "Rigenerazione imminente"
        case .activeRegeneration: return "Rigenerazione in corso"
        }
    }

    private var guidance: String {
        guard hasData else {
            guard isSessionActive else {
                return "Connetti l'adattatore oppure usa il laboratorio test."
            }
            return isAwaitingTelemetry
                ? "Attendo i primi valori dalla centralina"
                : "Il PID carico DPF non è disponibile su questa centralina."
        }
        if isCached { return "Valore dell’ultima connessione, non in tempo reale." }
        if dpf.effectiveRegenerationMode == .active {
            return "Continua a guidare e non spegnere il motore."
        }
        if dpf.effectiveRegenerationMode == .passive {
            return "Il filtro si sta rigenerando in modo passivo."
        }
        switch dpf.loadAlertLevel {
        case .regenerationImminent:
            return "La rigenerazione può iniziare a breve."
        case .nearRegeneration:
            return "Il carico è alto: continua a monitorare il filtro."
        default:
            return "Il filtro è nella normale zona di utilizzo."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if dynamicTypeSize.isAccessibilitySize {
                verticalHero
            } else {
                ViewThatFits(in: .horizontal) {
                    horizontalHero
                    verticalHero
                }
            }

            Divider().overlay(Color.white.opacity(0.09))
            RegenStatusRow(
                dpf: dpf,
                isCached: isCached,
                estimatedTimeRemaining: estimatedTimeRemaining
            )
        }
        .padding(20)
        .glassPanel(cornerRadius: 30)
    }

    private var horizontalHero: some View {
        HStack(alignment: .center, spacing: 18) {
            gauge
                .frame(width: gaugeSize, height: gaugeSize)
            heroCopy(centered: false)
        }
    }

    private var verticalHero: some View {
        VStack(spacing: 18) {
            gauge
                .frame(width: gaugeSize, height: gaugeSize)
            heroCopy(centered: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func heroCopy(centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 8) {
            Text("DPF LOAD")
                .font(.caption.weight(.heavy))
                .tracking(2.3)
                .foregroundStyle(Brand.textDim)

            Text(LocalizedStringKey(loadLabel))
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(tint)
                .multilineTextAlignment(centered ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(LocalizedStringKey(guidance))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(centered ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    private var gauge: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: 18)

            // Solid tint fixes the visible AngularGradient seam and the
            // accidental two-tone red ring seen at high load.
            Circle()
                .trim(from: 0, to: CGFloat(min(max(load, 0), 100) / 100))
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 18, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.38), radius: 10)
                .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: load)

            VStack(spacing: -2) {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(hasData ? String(format: "%.1f", load) : "—")
                        .font(.system(size: 49, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: load)
                    if hasData {
                        Text("%")
                            .font(.system(size: 21, weight: .semibold, design: .rounded))
                            .foregroundStyle(Brand.textDim)
                    }
                }
                Text("SATURAZIONE")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(Brand.textDim)
            }
            .foregroundStyle(.white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Carico DPF")
        .accessibilityValue(
            hasData
                ? Text(verbatim: String(format: "%.1f%%", load))
                : Text("Dati non disponibili")
        )
        .accessibilityHint(Text(LocalizedStringKey(guidance)))
    }
}

private struct RegenStatusRow: View {
    let dpf: DPFState
    let isCached: Bool
    let estimatedTimeRemaining: TimeInterval?

    var body: some View {
        let mode = dpf.effectiveRegenerationMode
        let active = mode != .none
        HStack(spacing: 12) {
            Image(systemName: active ? "flame.fill" : "flame")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(active ? .orange : Brand.textDim)
                .frame(width: 38, height: 38)
                .background((active ? Color.orange : Color.white).opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(regenTitle))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(active ? .orange : .white.opacity(0.82))
                Text(LocalizedStringKey(statusDetail))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Brand.textDim)
                if let estimateText {
                    Text(verbatim: estimateText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange.opacity(0.9))
                }
            }

            Spacer()

            if let progress = dpf.regenProgressPercent, mode == .active {
                Text(String(format: "%.0f%%", progress))
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(regenTitle)))
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(Text(LocalizedStringKey(statusDetail)))
    }

    private var regenTitle: String {
        switch dpf.effectiveRegenerationMode {
        case .active: return "Rigenerazione attiva"
        case .passive: return "Rigenerazione passiva"
        case .none:
            return dpf.regenActive == nil && dpf.regenerationMode == nil
                ? "Stato rigenerazione sconosciuto"
                : "Rigenerazione non attiva"
        }
    }

    private var statusDetail: String {
        if isCached { return "Ultimo stato salvato, non in tempo reale" }
        if dpf.regenerationMode == dpf.effectiveRegenerationMode {
            return "Stato reale letto dal PID di rigenerazione"
        }
        return "Stato stimato dai dati disponibili"
    }

    private var estimateText: String? {
        guard dpf.effectiveRegenerationMode == .active,
              let estimatedTimeRemaining
        else { return nil }
        let minutes = max(1, Int((estimatedTimeRemaining / 60).rounded()))
        return String(
            format: AppLocalization.string("Circa %d min rimanenti"),
            minutes
        )
    }

    private var accessibilityValue: Text {
        if let progress = dpf.regenProgressPercent,
           dpf.effectiveRegenerationMode == .active {
            let progressText = String(format: "%.0f%%", progress)
            if let estimateText {
                return Text(verbatim: "\(progressText), \(estimateText)")
            }
            return Text(verbatim: progressText)
        }
        if let estimateText {
            return Text(verbatim: estimateText)
        }
        return Text(LocalizedStringKey(statusDetail))
    }
}

// MARK: - Details

private struct DPFDetailGrid: View {
    let dpf: DPFState
    let isCached: Bool
    let visibleMetrics: Set<DashboardMetric>
    @Environment(\.appAccent) private var appAccent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    var body: some View {
        if !visibleMetrics.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                SectionLabel(text: "DATI VEICOLO", icon: "car.side.fill")
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(DashboardMetric.allCases.filter(visibleMetrics.contains)) { metric in
                        card(for: metric)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func card(for metric: DashboardMetric) -> some View {
        switch metric {
        case .distanceSinceRegeneration:
            MetricCard(
                icon: "road.lanes",
                title: "DALL'ULTIMA REGEN",
                value: dpf.distanceSinceLastRegenKm.map { String(format: "%.0f", $0) },
                unit: "km",
                accent: isCached ? .gray : .cyan
            )
        case .exhaustTemperature:
            MetricCard(
                icon: "thermometer.high",
                title: "SCARICO",
                value: dpf.exhaustTempC.map { String(format: "%.0f", $0) },
                unit: "°C",
                accent: isCached ? .gray : .orange
            )
        case .regenerationProgress:
            MetricCard(
                icon: "arrow.triangle.2.circlepath",
                title: "AVANZAMENTO",
                value: dpf.regenProgressPercent.map { String(format: "%.1f", $0) },
                unit: "%",
                accent: isCached ? .gray : (dpf.effectiveRegenerationMode == .active ? .orange : .gray)
            )
        case .totalRegenerations:
            MetricCard(
                icon: "number.square",
                title: "RIGENERAZIONI",
                value: dpf.totalRegenCount.map { String(format: "%.0f", $0) },
                unit: "totali",
                accent: isCached ? .gray : appAccent
            )
        case .oilPressure:
            MetricCard(
                icon: "oilcan.fill",
                title: "STATO PRESSIONE OLIO",
                value: dpf.oilPressureStatusText,
                unit: "",
                accent: oilPressureAccent
            )
        case .batteryVoltage:
            BatteryMetricCard(
                dpf: dpf,
                isCached: isCached,
                accent: batteryVoltageAccent
            )
        }
    }

    private var batteryVoltageAccent: Color {
        let voltage = dpf.batteryVoltage
        guard !isCached else { return .gray }
        if let voltage {
            if voltage < 11.8 { return Brand.redBright }
            if voltage < 12.2 { return .orange }
            return .green
        }
        return dpf.freshBatteryStateOfChargePercent() != nil ? .green : .gray
    }

    private var oilPressureAccent: Color {
        if isCached { return .gray }
        switch dpf.oilPressureStatusRaw {
        case 1: return .orange
        case 2: return .green
        default: return .gray
        }
    }

}

private struct SectionLabel: View {
    let text: String
    let icon: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(LocalizedStringKey(text)).tracking(2)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(Brand.textDim)
        .padding(.leading, 3)
    }
}

/// Battery tile showing the IBS state of charge as the headline value when
/// fresh, with the adapter voltage as a compact detail. Voltage alone remains
/// fully supported on vehicles without an IBS reply.
private struct BatteryMetricCard: View {
    let dpf: DPFState
    let isCached: Bool
    let accent: Color
    @ScaledMetric(relativeTo: .body) private var cardHeight = 112.0

    private var presentation: BatteryMetricPresentation {
        .resolve(state: dpf, isLive: !isCached)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "battery.75percent")
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey("BATTERIA"))
                    .lineLimit(2)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(Brand.textDim)

            Spacer(minLength: 4)

            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text(valueText)
                    .font(.system(.title2, design: .rounded, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if !unitText.isEmpty {
                    Text(unitText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Brand.textDim)
                        .lineLimit(1)
                }
            }

            if let voltage = presentation.voltageDetail {
                Text(String(format: "%.1f V", voltage))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Brand.textDim)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(16)
        .frame(
            maxWidth: .infinity,
            minHeight: cardHeight,
            maxHeight: cardHeight,
            alignment: .leading
        )
        .dashboardTile(cornerRadius: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Batteria"))
        .accessibilityValue(accessibilityValue)
    }

    private var valueText: String {
        switch presentation.headline {
        case .stateOfChargePercent(let percent):
            return String(format: "%.0f", percent)
        case .voltage(let voltage):
            return String(format: "%.1f", voltage)
        case .unavailable:
            return "—"
        }
    }

    private var unitText: String {
        switch presentation.headline {
        case .stateOfChargePercent: return "%"
        case .voltage: return "V"
        case .unavailable: return ""
        }
    }

    private var accessibilityValue: Text {
        switch presentation.headline {
        case .stateOfChargePercent(let percent):
            let voltage = presentation.voltageDetail.map { String(format: "%.1f V", $0) }
                ?? AppLocalization.string("Dati non disponibili")
            return Text(verbatim: String(format: "%.0f%% · %@", percent, voltage))
        case .voltage(let voltage):
            return Text(verbatim: String(format: "%.1f V", voltage))
        case .unavailable:
            return Text("Dati non disponibili")
        }
    }
}

private struct MetricCard: View {
    let icon: String
    let title: String
    let value: String?
    let unit: String
    let accent: Color
    @ScaledMetric(relativeTo: .body) private var cardHeight = 112.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(title))
                    .lineLimit(2)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(Brand.textDim)

            Spacer(minLength: 4)

            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text(value ?? "—")
                    .font(.system(.title2, design: .rounded, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if value != nil, !unit.isEmpty {
                    Text(unit)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Brand.textDim)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(16)
        .frame(
            maxWidth: .infinity,
            minHeight: cardHeight,
            maxHeight: cardHeight,
            alignment: .leading
        )
        .dashboardTile(cornerRadius: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(title)))
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: Text {
        guard let value else { return Text("Dati non disponibili") }
        return Text(verbatim: unit.isEmpty ? value : "\(value) \(unit)")
    }
}

private struct EventStrip: View {
    let text: String
    let simulated: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: simulated ? "testtube.2" : "bell.badge.fill")
                .foregroundStyle(simulated ? .cyan : .orange)
            Text(LocalizedStringKey(text))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 0)
        }
        .padding(14)
        .dashboardTile(cornerRadius: 18)
    }
}

// MARK: - Connection

private struct ConnectionDock: View {
    @Bindable var session: MonitorSession
    @Environment(\.appAccent) private var appAccent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showDisconnectConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        statusIcon
                        statusCopy
                        Spacer(minLength: 0)
                    }
                    actionButton
                        .frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 12) {
                    statusIcon
                    statusCopy
                    Spacer(minLength: 4)
                    actionButton
                }
            }

            if isStopped {
                Label(
                    "Configura la connessione da fermo. Non usare iPhone durante la guida.",
                    systemImage: "steeringwheel"
                )
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .glassPanel(cornerRadius: 24)
        .alert("Rigenerazione attiva", isPresented: $showDisconnectConfirmation) {
            Button("Continua il monitoraggio", role: .cancel) {}
            Button("Disconnetti", role: .destructive) { session.stop() }
        } message: {
            Text("Disconnettendo ora lo storico non potrà verificare la conclusione del ciclo.")
        }
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.15))
                .frame(width: 42, height: 42)
            if session.status == .connecting {
                ProgressView().tint(statusColor)
            } else {
                Image(systemName: statusSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
        }
        .accessibilityHidden(true)
    }

    private var statusCopy: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(statusTitle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text(verbatim: statusDetail)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Brand.textDim)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var actionButton: some View {
        Button(action: requestToggle) {
            Label(LocalizedStringKey(buttonTitle), systemImage: buttonSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(buttonGradient, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .accessibilityHint(
            session.isRegenerationInProgress
                ? Text("Una rigenerazione è attiva; verrà richiesta conferma.")
                : Text(verbatim: "")
        )
    }

    private var isStopped: Bool {
        session.status == .idle || {
            if case .failed = session.status { return true }
            return false
        }()
    }

    private var buttonTitle: String {
        switch session.status {
        case .idle:       return "Connetti"
        case .connecting: return "Annulla"
        case .running:    return "Disconnetti"
        case .simulating: return "Termina"
        case .failed:     return "Riprova"
        }
    }

    private var buttonSymbol: String {
        switch session.status {
        case .idle, .failed: return "bolt.fill"
        case .connecting:    return "xmark"
        case .running:       return "bolt.slash.fill"
        case .simulating:    return "stop.fill"
        }
    }

    private var statusTitle: String {
        switch session.status {
        case .idle: return "Pronto"
        case .connecting: return "Connessione"
        case .running: return "Live"
        case .simulating: return "Test"
        case .failed: return "Errore"
        }
    }

    private var statusDetail: String {
        switch session.status {
        case .idle:
            return session.transportKind.title
        case .connecting:
            return AppLocalization.string("Ricerca dell’adattatore in corso")
        case .running:
            return AppLocalization.string("Dati DPF in tempo reale")
        case .simulating:
            return AppLocalization.string("OBD disattivato durante il test")
        case .failed(let message):
            return message
        }
    }

    private var statusSymbol: String {
        switch session.status {
        case .idle: return "bolt.horizontal.circle"
        case .connecting: return "dot.radiowaves.left.and.right"
        case .running: return "checkmark.circle.fill"
        case .simulating: return "testtube.2"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .idle: return appAccent
        case .connecting: return .orange
        case .running: return .green
        case .simulating: return .cyan
        case .failed: return Brand.redBright
        }
    }

    private var buttonGradient: LinearGradient {
        let colors: [Color]
        switch session.status {
        case .idle, .failed:
            colors = [session.appAccent.brightColor, appAccent, appAccent.opacity(0.42)]
        case .simulating:    colors = [.cyan.opacity(0.8), .blue.opacity(0.6)]
        default:             colors = [Color.white.opacity(0.22), Color.white.opacity(0.10)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func requestToggle() {
        if session.status == .running && session.isRegenerationInProgress {
            showDisconnectConfirmation = true
            return
        }
        toggle()
    }

    private func toggle() {
        switch session.status {
        case .running, .connecting, .simulating:
            session.stop()
        case .idle, .failed:
            session.start()
        }
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Bindable var session: MonitorSession
    @State private var showDiagnostics = false
    @State private var showTestLab = false
    @Environment(\.appAccent) private var appAccent

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settingsSection(title: "CONNESSIONE", icon: "cable.connector") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Tipo di adattatore", selection: $session.transportKind) {
                                ForEach(OBDTransportKind.allCases) { kind in
                                    Text(LocalizedStringKey(kind.title)).tag(kind)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(connectionSettingsLocked)

                            if session.transportKind == .wifi {
                                VStack(alignment: .leading, spacing: 8) {
                                    TextField("Indirizzo IP o host", text: $session.wifiHost)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .keyboardType(.URL)
                                    TextField("Porta TCP", text: $session.wifiPort)
                                        .keyboardType(.numberPad)
                                    Text("Connettiti prima alla rete Wi-Fi creata dall’adattatore. È normale che iOS indichi “Nessuna connessione Internet”.")
                                        .font(.system(size: 10, design: .rounded))
                                        .foregroundStyle(Brand.textDim)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .textFieldStyle(.roundedBorder)
                                .disabled(connectionSettingsLocked)
                            }

                            Divider().overlay(Brand.hairline)

                            Toggle(isOn: $session.autoConnectEnabled) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Connessione automatica")
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    Text("Tenta la connessione all’apertura dell’app")
                                        .font(.system(size: 11, design: .rounded))
                                        .foregroundStyle(Brand.textDim)
                                }
                            }
                            .tint(appAccent)
                        }
                    }

                    settingsSection(title: "COLORE ACCENT", icon: "paintpalette.fill") {
                        Menu {
                            ForEach(StelvioAccent.allCases) { option in
                                Button {
                                    session.appAccent = option
                                } label: {
                                    if session.appAccent == option {
                                        Label(option.title, systemImage: "checkmark")
                                    } else {
                                        Text(LocalizedStringKey(option.title))
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(session.appAccent.color)
                                    .frame(width: 25, height: 25)
                                    .overlay(
                                        Circle().stroke(
                                            Color.white.opacity(0.34),
                                            lineWidth: 0.8
                                        )
                                    )
                                Text(LocalizedStringKey(session.appAccent.title))
                                    .font(.system(
                                        size: 14,
                                        weight: .semibold,
                                        design: .rounded
                                    ))
                                    .foregroundStyle(.white)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Brand.textDim)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    settingsSection(title: "LINGUA", icon: "globe") {
                        Menu {
                            ForEach(AppLanguage.allCases) { option in
                                Button {
                                    session.appLanguage = option
                                } label: {
                                    if session.appLanguage == option {
                                        Label(
                                            LocalizedStringKey(option.displayNameKey),
                                            systemImage: "checkmark"
                                        )
                                    } else {
                                        Text(LocalizedStringKey(option.displayNameKey))
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "globe")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(appAccent)
                                    .frame(width: 25, height: 25)
                                Text(LocalizedStringKey(session.appLanguage.displayNameKey))
                                    .font(.system(
                                        size: 14,
                                        weight: .semibold,
                                        design: .rounded
                                    ))
                                    .foregroundStyle(.white)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Brand.textDim)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    settingsSection(title: "PAGINA PRINCIPALE", icon: "rectangle.grid.2x2") {
                        VStack(spacing: 0) {
                            ForEach(DashboardMetric.allCases) { metric in
                                Toggle(
                                    metric.title,
                                    isOn: Binding(
                                        get: {
                                            session.visibleDashboardMetrics.contains(metric)
                                        },
                                        set: {
                                            session.setDashboardMetric(metric, isVisible: $0)
                                        }
                                    )
                                )
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .tint(appAccent)
                                .padding(.vertical, 8)

                                if metric != DashboardMetric.allCases.last {
                                    Divider().overlay(Brand.hairline)
                                }
                            }
                        }
                    }

                    settingsSection(title: "STRUMENTI", icon: "wrench.and.screwdriver") {
                        VStack(spacing: 0) {
                            SettingsToolButton(
                                title: "Diagnostica OBD",
                                symbol: "waveform.badge.magnifyingglass"
                            ) {
                                showDiagnostics = true
                            }
                            Divider().overlay(Brand.hairline)
                            SettingsToolButton(
                                title: "Laboratorio DPF",
                                symbol: "testtube.2"
                            ) {
                                showTestLab = true
                            }
                        }
                    }

                    settingsSection(title: "SOSTIENI IL PROGETTO", icon: "heart.fill") {
                        VStack(alignment: .leading, spacing: 0) {
                            SettingsToolButton(
                                title: "Contributo facoltativo · €4,99",
                                symbol: "heart.circle.fill"
                            ) {
                                openURL(ProjectSupport.donationURL)
                            }
                            Divider().overlay(Brand.hairline)
                            Text("L’app è gratuita e resterà gratuita. Un contributo facoltativo di €4,99 aiuta a coprire i costi annuali e a mantenere vivo il progetto. Non sblocca funzioni e non cambia l’esperienza.")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Brand.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 2)
                                .padding(.vertical, 12)
                        }
                    }
                }
                .padding(18)
            }
            .background(DashboardBackground())
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fine") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(
                dpf: session.dpf,
                onTestNotification: session.testNotification
            )
        }
        .sheet(isPresented: $showTestLab) {
            TestLabView(session: session)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var connectionSettingsLocked: Bool {
        switch session.status {
        case .connecting, .running: return true
        case .idle, .simulating, .failed: return false
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(text: title, icon: icon)
            content()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassPanel(cornerRadius: 22)
        }
    }
}

private struct SettingsToolButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.appAccent) private var appAccent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(appAccent)
                    .frame(width: 22)
                Text(LocalizedStringKey(title))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.textDim)
            }
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Safety, privacy and support

private struct AboutSafetyView: View {
    @Environment(\.dismiss) private var dismiss

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Versione \(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Prima la sicurezza", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                        Text("Configura l’adattatore e consulta i dati soltanto a veicolo fermo. Non interagire con iPhone durante la guida e rispetta sempre il codice della strada.")
                            .font(.system(size: 14, design: .rounded))
                            .foregroundStyle(.white.opacity(0.76))
                    }
                    .padding(18)
                    .glassPanel(cornerRadius: 22)

                    informationSection(
                        title: "Uso informativo",
                        symbol: "wrench.and.screwdriver",
                        text: "Le letture dipendono dall’adattatore e dalla centralina del veicolo. Alpha DPF Monitor non sostituisce strumenti professionali, manutenzione, diagnosi o indicazioni del costruttore."
                    )

                    informationSection(
                        title: "App indipendente",
                        symbol: "checkmark.shield",
                        text: "Alpha DPF Monitor è un prodotto indipendente e non è affiliato, sponsorizzato o approvato da Alfa Romeo, Stellantis o dai costruttori dei veicoli compatibili. I marchi citati appartengono ai rispettivi titolari."
                    )

                    VStack(spacing: 0) {
                        AboutLinkRow(title: "Informativa privacy", symbol: "hand.raised.fill", destination: AppLinks.privacy)
                        Divider().overlay(Brand.hairline)
                        AboutLinkRow(title: "Supporto", symbol: "questionmark.circle.fill", destination: AppLinks.support)
                        Divider().overlay(Brand.hairline)
                        AboutLinkRow(title: "Contatta l’assistenza", symbol: "envelope.fill", destination: AppLinks.email)
                    }
                    .padding(.horizontal, 16)
                    .glassPanel(cornerRadius: 22)

                    Text(versionText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Brand.textDim)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .padding(18)
            }
            .background(DashboardBackground())
            .navigationTitle("Informazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fine") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func informationSection(title: String, symbol: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(LocalizedStringKey(text))
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassPanel(cornerRadius: 22)
    }
}

private struct AboutLinkRow: View {
    let title: String
    let symbol: String
    let destination: URL
    @Environment(\.appAccent) private var appAccent

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(appAccent)
                    .frame(width: 22)
                Text(LocalizedStringKey(title))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.textDim)
            }
            .padding(.vertical, 15)
        }
    }
}

// MARK: - Test Lab

private struct TestLabView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: MonitorSession

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Test senza automobile", systemImage: "car.side.fill")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("Gli scenari usano la stessa logica della connessione reale: interfaccia, Live Activity e notifiche di inizio/fine rigenerazione.")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(Brand.textDim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: session.runSimulationSequence) {
                        Label("Esegui ciclo completo (8 secondi)", systemImage: "play.fill")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(
                                LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: session.testNotification) {
                        Label("Test tra 5 s: blocca lo schermo", systemImage: "bell.badge.fill")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.hairline))
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 9) {
                        ForEach(DPFSimulationScenario.allCases) { scenario in
                            ScenarioButton(
                                scenario: scenario,
                                selected: session.activeScenario == scenario,
                                action: { session.applySimulation(scenario) }
                            )
                        }
                    }

                    Text("Per testare manualmente entrambe le notifiche, tocca prima “Inizio rigenerazione” e poi “Fine rigenerazione”.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Brand.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18)
            }
            .background(DashboardBackground())
            .navigationTitle("Laboratorio DPF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if session.status == .simulating {
                        Button("Termina test") { session.stop() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fine") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct ScenarioButton: View {
    let scenario: DPFSimulationScenario
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: scenario.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(selected ? .cyan : .white.opacity(0.65))
                    .frame(width: 35, height: 35)
                    .background((selected ? Color.cyan : Color.white).opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(scenario.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(scenario.detail)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Brand.textDim)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17))
            .overlay(
                RoundedRectangle(cornerRadius: 17)
                    .stroke(selected ? Color.cyan.opacity(0.6) : Brand.hairline, lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Diagnostics

private struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    private let log = OBDLog.shared
    let dpf: DPFState
    let onTestNotification: () -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if dpf.exhaustTemperaturePID != nil
                            || dpf.regenerationMode != nil
                            || dpf.oilPressureStatusRaw != nil
                            || dpf.batteryStateOfChargePercent != nil {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("TELEMETRIA ECU")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.cyan)
                                if let pid = dpf.exhaustTemperaturePID {
                                    Text("Temperatura scarico: PID \(String(format: "22%04X", pid)) · \(dpf.exhaustTempC.map { String(format: "%.1f °C", $0) } ?? "—")")
                                }
                                Text("Rigenerazione: \(regenerationModeText)")
                                Text("Stato pressione olio 22194D: \(oilPressureDiagnosticText)")
                                Text("SOC batteria: \(batteryStateOfChargeDiagnosticText)")
                            }
                            .font(.system(.caption2, design: .monospaced))
                            .padding(12)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                        }

                        if let raw = dpf.cloggingRaw {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("ULTIMA LETTURA CARICO DPF")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.cyan)
                                Text("PID 2218E4 · ECU \(dpf.cloggingECUHeader ?? "—")")
                                Text("raw \(raw) (0x\(String(raw, radix: 16, uppercase: true)))")
                                Text("formula raw×1000/65535 = \(dpf.cloggingPercent.map { String(format: "%.3f%%", $0) } ?? "—")")
                                Text("Modello veicolo non identificato automaticamente")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(.caption2, design: .monospaced))
                            .padding(12)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                        }

                        Text(log.lines.isEmpty
                             ? "Nessun comando ancora.\nConnetti l'OBD e torna qui."
                             : log.text)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(14)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: log.lines.count) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .background(Brand.ink)
            .navigationTitle("Diagnostica OBD")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copia") { UIPasteboard.general.string = log.text }
                        .disabled(log.lines.isEmpty)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: onTestNotification) {
                        Label("Test avviso", systemImage: "bell.badge")
                    }
                    Button("Fine") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var regenerationModeText: String {
        guard let mode = dpf.regenerationMode else {
            return AppLocalization.string("PID non disponibile")
        }
        switch mode {
        case .none: return AppLocalization.string("0 · nessuna")
        case .passive: return AppLocalization.string("1 · passiva")
        case .active: return AppLocalization.string("2 · attiva")
        }
    }

    private var oilPressureDiagnosticText: String {
        guard let raw = dpf.oilPressureStatusRaw else {
            return AppLocalization.string("PID non disponibile")
        }
        return "\(raw) · \(dpf.oilPressureStatusText ?? AppLocalization.string("Sconosciuto"))"
    }

    private var batteryStateOfChargeDiagnosticText: String {
        guard let percent = dpf.batteryStateOfChargePercent else {
            return AppLocalization.string("PID non disponibile")
        }
        let source = dpf.batteryStateOfChargeSource == .engineECUMirror
            ? "2219BD/18DA10F1"
            : "221005/18DA40F1"
        let updated = dpf.batteryStateOfChargeUpdatedAt.map {
            $0.formatted(.dateTime.hour().minute().second())
        } ?? "—"
        return String(format: "%.0f%% · %@ · %@", percent, source, updated)
    }
}

// MARK: - History

private struct HistoryNavigationRow: View {
    let action: () -> Void
    let store: DPFHistoryStore?
    @State private var sampleCount = 0
    @State private var cycleCount = 0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 44, height: 44)
                    .background(Color.cyan.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Storico DPF")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(summary)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Brand.textDim)
                }

                Spacer()

                if sampleCount > 0 || cycleCount > 0 {
                    HStack(spacing: 10) {
                        if sampleCount > 0 {
                            Label("\(sampleCount)", systemImage: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.cyan)
                        }
                        if cycleCount > 0 {
                            Label("\(cycleCount)", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.trailing, 4)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.textDim)
            }
            .padding(16)
            .glassPanel(cornerRadius: 22)
        }
        .buttonStyle(.plain)
        .onAppear { refreshCounts() }
    }

    private var summary: String {
        if sampleCount == 0 && cycleCount == 0 {
            return AppLocalization.string("Nessun dato registrato")
        }
        var parts: [String] = []
        if sampleCount > 0 {
            parts.append(AppLocalization.string("Campioni: \(sampleCount)"))
        }
        if cycleCount > 0 {
            parts.append(AppLocalization.string("Cicli: \(cycleCount)"))
        }
        return parts.joined(separator: " · ")
    }

    private func refreshCounts() {
        guard let store else { return }
        sampleCount = store.samples().count
        cycleCount = store.cycles().count
    }
}

private struct DPFHistoryChartAccessibility: AXChartDescriptorRepresentable {
    let samples: [DPFHistorySample]

    func makeChartDescriptor() -> AXChartDescriptor {
        let timestamps = samples.map { $0.timestamp.timeIntervalSince1970 }
        let lowerBound = timestamps.min() ?? 0
        let upperBound = max(timestamps.max() ?? lowerBound, lowerBound + 1)
        let timeFormatter = DateFormatter()
        timeFormatter.locale = AppLocalization.language.locale
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short

        let xAxis = AXNumericDataAxisDescriptor(
            title: AppLocalization.string("Ora"),
            range: lowerBound...upperBound,
            gridlinePositions: [lowerBound, upperBound]
        ) { value in
            timeFormatter.string(from: Date(timeIntervalSince1970: value))
        }
        let yAxis = AXNumericDataAxisDescriptor(
            title: AppLocalization.string("Carico"),
            range: 0...100,
            gridlinePositions: [0, 50, 85, 95, 100]
        ) { value in
            String(format: "%.0f%%", value)
        }
        let points = samples.map { sample in
            AXDataPoint(
                x: sample.timestamp.timeIntervalSince1970,
                y: sample.cloggingPercent,
                label: sample.regenActive
                    ? AppLocalization.string("Rigenerazione attiva")
                    : nil
            )
        }
        let series = AXDataSeriesDescriptor(
            name: AppLocalization.string("Carico DPF"),
            isContinuous: true,
            dataPoints: points
        )
        return AXChartDescriptor(
            title: AppLocalization.string("Andamento carico DPF"),
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            series: [series]
        )
    }
}

private struct DPFHistoryView: View {
    let store: DPFHistoryStore?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var samples: [DPFHistorySample] = []
    @State private var cycles: [DPFRegenCycle] = []
    @State private var insights = DPFHistoryInsights(cycles: [])
    @State private var selectedTime: Date?

    var body: some View {
        NavigationStack {
            ZStack {
                DashboardBackground()

                if samples.isEmpty && cycles.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            insightsSection
                            chartSection
                            cyclesSection
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                        .padding(.bottom, 30)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .navigationTitle("Storico")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fine") { dismiss() }
                }
            }
            .task { loadData() }
            .onAppear { loadData() }
        }
        .preferredColorScheme(.dark)
    }

    private var selectedSample: DPFHistorySample? {
        guard let selectedTime else { return nil }
        return samples.min { lhs, rhs in
            abs(lhs.timestamp.timeIntervalSince(selectedTime))
                < abs(rhs.timestamp.timeIntervalSince(selectedTime))
        }
    }

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(text: "PANORAMICA CICLI", icon: "sparkles")
                .padding(.leading, 3)

            LazyVGrid(
                columns: insightColumns,
                spacing: 10
            ) {
                HistoryInsightCard(
                    title: "DURATA MEDIA",
                    value: averageDurationText,
                    symbol: "clock.fill",
                    accent: .cyan
                )
                HistoryInsightCard(
                    title: "CALO MEDIO",
                    value: averageReductionText,
                    symbol: "arrow.down.right",
                    accent: .green
                )
                HistoryInsightCard(
                    title: "COMPLETATE",
                    value: completionRateText,
                    symbol: "checkmark.circle.fill",
                    accent: .orange
                )
            }
        }
    }

    private var averageDurationText: String {
        guard let duration = insights.averageDuration else { return "—" }
        return "\(max(1, Int((duration / 60).rounded()))) min"
    }

    private var insightColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 3
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: count)
    }

    private var averageReductionText: String {
        guard let reduction = insights.averageLoadReduction else { return "—" }
        return String(format: "−%.0f%%", reduction)
    }

    private var completionRateText: String {
        guard let rate = insights.completionRate else { return "—" }
        return String(format: "%.0f%%", rate * 100)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Brand.textDim)
            Text("Nessun dato storico")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("Connetti l'adattatore OBD per iniziare a registrare l'andamento del carico DPF e la cronologia delle rigenerazioni.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Brand.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(text: "ANDAMENTO CARICO", icon: "chart.line.uptrend.xyaxis")
                .padding(.leading, 3)

            VStack(spacing: 4) {
                if samples.count < 2 {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "chart.line.downtrend.xyaxis")
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(Brand.textDim)
                            Text("Almeno due campioni per il grafico")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Brand.textDim)
                        }
                        .padding(.vertical, 40)
                        Spacer()
                    }
                } else {
                    Chart {
                        ForEach(samples, id: \.timestamp) { sample in
                            LineMark(
                                x: .value("Ora", sample.timestamp),
                                y: .value("Carico", sample.cloggingPercent)
                            )
                            .foregroundStyle(.cyan)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))

                            AreaMark(
                                x: .value("Ora", sample.timestamp),
                                y: .value("Carico", sample.cloggingPercent)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        .cyan.opacity(0.35),
                                        .cyan.opacity(0.05),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                            if sample.regenActive {
                                PointMark(
                                    x: .value("Ora", sample.timestamp),
                                    y: .value("Carico", sample.cloggingPercent)
                                )
                                .foregroundStyle(.orange)
                                .symbolSize(26)
                            }
                        }

                        RuleMark(y: .value("Carico elevato", 85))
                            .foregroundStyle(Color.orange.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))

                        RuleMark(y: .value("Rigenerazione imminente", 95))
                            .foregroundStyle(Brand.redBright.opacity(0.65))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))

                        if let selectedSample {
                            RuleMark(x: .value("Selezione", selectedSample.timestamp))
                                .foregroundStyle(Color.white.opacity(0.45))
                            PointMark(
                                x: .value("Selezione", selectedSample.timestamp),
                                y: .value("Carico", selectedSample.cloggingPercent)
                            )
                            .foregroundStyle(.white)
                            .symbolSize(70)
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel(format: .dateTime.hour().minute())
                                .foregroundStyle(Brand.textDim)
                            AxisTick()
                                .foregroundStyle(Brand.hairline)
                            AxisGridLine()
                                .foregroundStyle(Brand.hairline)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { value in
                            AxisValueLabel {
                                if let pct = value.as(Double.self) {
                                    Text("\(Int(pct))%")
                                        .foregroundStyle(Brand.textDim)
                                }
                            }
                            AxisGridLine()
                                .foregroundStyle(Brand.hairline)
                        }
                    }
                    .frame(height: 220)
                    .chartXSelection(value: $selectedTime)
                    .accessibilityChartDescriptor(
                        DPFHistoryChartAccessibility(samples: samples)
                    )

                    if let selectedSample {
                        historySampleDetail(selectedSample)
                            .transition(.opacity)
                    } else {
                        Label("Tocca e trascina il grafico per esplorare i dati", systemImage: "hand.draw")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Brand.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }

                    chartLegend
                }
            }
            .padding(16)
            .glassPanel(cornerRadius: 22)
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(LocalizedStringKey(label))
                .foregroundStyle(Brand.textDim)
        }
    }

    private var chartLegend: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                verticalLegend
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        legendItems
                    }
                    verticalLegend
                }
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.top, 6)
    }

    private var verticalLegend: some View {
        VStack(alignment: .leading, spacing: 7) {
            legendItems
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var legendItems: some View {
        legendItem(color: .green, label: "Normale (<85%)")
        legendItem(color: .orange, label: "Elevato (85–95%)")
        legendItem(color: Brand.redBright, label: "Imminente (>95%)")
    }

    private func historySampleDetail(_ sample: DPFHistorySample) -> some View {
        HStack(spacing: 12) {
            Text(sample.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)

            Divider().frame(height: 24).overlay(Brand.hairline)

            Label(
                String(format: "%.1f%%", sample.cloggingPercent),
                systemImage: "gauge.with.dots.needle.50percent"
            )
            .foregroundStyle(.cyan)

            if let temperature = sample.exhaustTempC {
                Label(
                    String(format: "%.0f °C", temperature),
                    systemImage: "thermometer.high"
                )
                .foregroundStyle(.orange)
            }

            Spacer(minLength: 0)

            if sample.regenActive {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Rigenerazione attiva")
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(10)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var cyclesSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(text: "CICLI RIGENERAZIONE", icon: "arrow.triangle.2.circlepath")
                .padding(.leading, 3)

            VStack(spacing: 0) {
                if cycles.isEmpty {
                    HStack {
                        Spacer()
                        Text("Nessun ciclo registrato")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Brand.textDim)
                            .padding(.vertical, 24)
                        Spacer()
                    }
                } else {
                    ForEach(Array(cycles.enumerated()), id: \.element.id) { index, cycle in
                        RegenCycleRow(cycle: cycle)
                        if index < cycles.count - 1 {
                            Divider()
                                .overlay(Brand.hairline)
                                .padding(.leading, 52)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .glassPanel(cornerRadius: 22)
        }
    }

    private func loadData() {
        guard let store else { return }
        samples = store.samples()
        cycles = store.cycles()
        insights = store.insights()
    }
}

private struct HistoryInsightCard: View {
    let title: String
    let value: String
    let symbol: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(verbatim: value)
                .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(LocalizedStringKey(title))
                .font(.caption2.weight(.bold))
                .foregroundStyle(Brand.textDim)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .padding(12)
        .dashboardTile(cornerRadius: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(title)))
        .accessibilityValue(Text(verbatim: value))
    }
}

private struct RegenCycleRow: View {
    let cycle: DPFRegenCycle

    private var icon: String {
        switch cycle.status {
        case .completed: return "checkmark.circle.fill"
        case .interrupted: return "xmark.circle.fill"
        case .unconfirmed: return "questionmark.circle.fill"
        case .active: return "flame.fill"
        }
    }

    private var iconColor: Color {
        switch cycle.status {
        case .completed: return .green
        case .interrupted: return .orange
        case .unconfirmed: return Brand.textDim
        case .active: return .cyan
        }
    }

    private var statusLabel: String {
        switch cycle.status {
        case .completed: return AppLocalization.string("Completata")
        case .interrupted: return AppLocalization.string("Interrotta")
        case .unconfirmed: return AppLocalization.string("Esito non verificato")
        case .active: return AppLocalization.string("In corso")
        }
    }

    private var durationText: String? {
        guard let finished = cycle.finishedAt else { return nil }
        let seconds = finished.timeIntervalSince(cycle.startedAt)
        let minutes = Int(seconds / 60)
        let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
        return AppLocalization.string("\(minutes) min \(secs) s")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 36, height: 36)
                .background(iconColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(statusLabel)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Circle()
                        .fill(iconColor)
                        .frame(width: 5, height: 5)
                }
                HStack(spacing: 4) {
                    Text(cycle.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if let duration = durationText {
                        Text("· \(duration)")
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Brand.textDim)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 3) {
                    Text("\(Int(cycle.startingLoad))%")
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.orange)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Brand.textDim)
                    if let end = cycle.endingLoad {
                        Text("\(Int(end))%")
                            .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.green)
                    } else {
                        Text("—")
                            .foregroundStyle(Brand.textDim)
                    }
                }
            }
        }
        .padding(.vertical, 12)
    }
}
