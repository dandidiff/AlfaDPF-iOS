import CarPlay
import Foundation
import UIKit

private enum CarPlayDetailKind {
    case dpf
    case regeneration
    case distance
    case exhaust
    case regenerationCount
    case oil
    case battery
    case data
}

/// Native CarPlay driving-task scene. CarPlay and the phone share the same
/// `MonitorSession`, so every action controls one BLE adapter and one ECU poller.
@MainActor
@objc(CarPlaySceneDelegate)
final class CarPlaySceneDelegate: UIResponder,
    CPTemplateApplicationSceneDelegate,
    CPInterfaceControllerDelegate
{
    private weak var interfaceController: CPInterfaceController?
    private var dashboardTemplate: CPGridTemplate?
    private var detailsTemplate: CPInformationTemplate?
    private var detailKind: CarPlayDetailKind?
    private var refreshTask: Task<Void, Never>?
    private var regenerationAlertTracker = CarPlayRegenerationAlertTracker()
    private var isPresentingAlert = false

    private let session = MonitorSession.shared

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        interfaceController.prefersDarkUserInterfaceStyle = true

        let template = makeDashboardTemplate()
        dashboardTemplate = template
        interfaceController.setRootTemplate(template, animated: false) { success, error in
            if success {
                OBDLog.log("CarPlay: dashboard connected")
            } else {
                OBDLog.log("CarPlay: root template failed: \(error?.localizedDescription ?? "unknown error")")
            }
        }

        session.startAutomaticallyIfNeeded()
        startRefreshing()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        if interfaceController.delegate === self {
            interfaceController.delegate = nil
        }
        refreshTask?.cancel()
        refreshTask = nil
        dashboardTemplate = nil
        detailsTemplate = nil
        detailKind = nil
        self.interfaceController = nil
        regenerationAlertTracker = CarPlayRegenerationAlertTracker()
        isPresentingAlert = false
        OBDLog.log("CarPlay: dashboard disconnected; phone session preserved")
    }

    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        if let detailsTemplate, aTemplate === detailsTemplate {
            self.detailsTemplate = nil
            detailKind = nil
        }
        if aTemplate is CPAlertTemplate || aTemplate is CPActionSheetTemplate {
            isPresentingAlert = false
        }
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshDashboard()
                do {
                    try await Task.sleep(for: CarPlayRefreshPolicy.interval)
                } catch {
                    return
                }
            }
        }
    }

    private func makeDashboardTemplate() -> CPGridTemplate {
        let template = CPGridTemplate(
            title: String(localized: "Alpha DPF"),
            gridButtons: makeGridButtons()
        )
        configureNavigationButtons(on: template)
        return template
    }

    private func refreshDashboard() {
        guard let dashboardTemplate else { return }
        dashboardTemplate.updateGridButtons(makeGridButtons())
        configureNavigationButtons(on: dashboardTemplate)
        if let detailKind {
            detailsTemplate?.items = makeInformationItems(for: detailKind)
        }

        let telemetryIsLive = session.status == .running && session.hasLiveTelemetry
        let event = regenerationAlertTracker.observe(
            isRegenerating: session.dpf.regenActive,
            telemetryIsLive: telemetryIsLive
        )
        guard let event else { return }

        // Keep tracking edges while muted so enabling alerts mid-regeneration
        // cannot replay a stale start. Only presentation is suppressed.
        guard session.carPlayAlertsEnabled else { return }

        // When system CarPlay notifications are enabled, AlertService already
        // delivers the native time-sensitive notification. Present an in-app
        // CPAlert only as a fallback, avoiding a duplicate alert on the car.
        guard !systemCarPlayNotificationsAreAvailable else { return }
        presentRegenerationAlert(event)
    }

    private var systemCarPlayNotificationsAreAvailable: Bool {
        if #available(iOS 18.4, *) {
            return session.alertAuthorization.carPlayEnabled
        }
        return false
    }

    private func makeGridButtons() -> [CPGridButton] {
        let dpf = session.carPlayDPFState
        return [
            makeMetricGridButton(
                label: String(localized: "DPF"),
                value: formatted(dpf.cloggingPercent, fractionDigits: 0, unit: "%"),
                symbolName: "gauge",
                detailKind: .dpf
            ),
            makeMetricGridButton(
                label: String(localized: "Regen"),
                value: regenerationGridText(for: dpf),
                symbolName: "arrow.triangle.2.circlepath",
                detailKind: .regeneration
            ),
            makeMetricGridButton(
                label: String(localized: "Dall’ultima"),
                value: formatted(dpf.distanceSinceLastRegenKm, fractionDigits: 0, unit: "km"),
                symbolName: "road.lanes",
                detailKind: .distance
            ),
            makeMetricGridButton(
                label: String(localized: "Scarico"),
                value: formatted(dpf.exhaustTempC, fractionDigits: 0, unit: "°C"),
                symbolName: "thermometer.medium",
                detailKind: .exhaust
            ),
            makeMetricGridButton(
                label: String(localized: "Rigenerazioni"),
                value: formatted(dpf.totalRegenCount, fractionDigits: 0),
                symbolName: "number.circle",
                detailKind: .regenerationCount
            ),
            makeMetricGridButton(
                label: String(localized: "Olio"),
                value: dpf.oilPressureStatusText ?? "—",
                symbolName: "oilcan",
                detailKind: .oil
            ),
            makeMetricGridButton(
                label: String(localized: "Batteria"),
                value: formatted(dpf.batteryVoltage, fractionDigits: 1, unit: "V"),
                symbolName: "battery.100",
                detailKind: .battery
            ),
            makeMetricGridButton(
                label: String(localized: "Dati"),
                value: telemetryGridText(for: dpf),
                symbolName: "clock",
                detailKind: .data
            ),
        ]
    }

    private func makeMetricGridButton(
        label: String,
        value: String,
        symbolName: String,
        detailKind: CarPlayDetailKind
    ) -> CPGridButton {
        CPGridButton(
            titleVariants: ["\(label) \(value)", label],
            image: symbolImage(named: symbolName)
        ) { [weak self] _ in
            self?.showDetails(detailKind)
        }
    }

    private func symbolImage(named name: String) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: 42, weight: .medium)
        return UIImage(systemName: name, withConfiguration: configuration)
            ?? UIImage(systemName: "circle", withConfiguration: configuration)!
    }

    private func regenerationGridText(for dpf: DPFState) -> String {
        switch dpf.effectiveRegenerationMode {
        case .none:
            return String(localized: "Non attiva")
        case .passive:
            return String(localized: "Passiva")
        case .active:
            return formatted(dpf.regenProgressPercent, fractionDigits: 0, unit: "%")
        }
    }

    private func telemetryGridText(for dpf: DPFState) -> String {
        guard dpf.hasTelemetry else { return "—" }
        let time = dpf.timestamp.formatted(date: .omitted, time: .shortened)
        if session.status == .running && session.hasLiveTelemetry {
            return "\(String(localized: "Live")) \(time)"
        }
        return "\(String(localized: "Salvati")) \(time)"
    }

    private func makeInformationItems(for detailKind: CarPlayDetailKind) -> [CPInformationItem] {
        let dpf = session.carPlayDPFState
        let hasTimestamp = dpf.hasTelemetry
        let timestamp = hasTimestamp
            ? dpf.timestamp.formatted(date: .omitted, time: .standard)
            : "—"
        let updated = CPInformationItem(
            title: String(localized: "Ultimo aggiornamento"),
            detail: timestamp
        )

        switch detailKind {
        case .dpf:
            return [
                CPInformationItem(
                    title: String(localized: "Carico DPF"),
                    detail: formatted(dpf.cloggingPercent, fractionDigits: 0, unit: "%")
                ),
                CPInformationItem(
                    title: String(localized: "Distanza dall’ultima rigenerazione"),
                    detail: formatted(dpf.distanceSinceLastRegenKm, fractionDigits: 1, unit: "km")
                ),
                CPInformationItem(
                    title: String(localized: "Rigenerazioni totali"),
                    detail: formatted(dpf.totalRegenCount, fractionDigits: 0)
                ),
                updated,
            ]
        case .regeneration:
            return [
                CPInformationItem(
                    title: String(localized: "Rigenerazione"),
                    detail: regenerationStatusText(for: dpf)
                ),
                CPInformationItem(
                    title: String(localized: "Avanzamento rigenerazione"),
                    detail: formatted(dpf.regenProgressPercent, fractionDigits: 0, unit: "%")
                ),
                CPInformationItem(
                    title: String(localized: "Temperatura gas di scarico"),
                    detail: formatted(dpf.exhaustTempC, fractionDigits: 0, unit: "°C")
                ),
                updated,
            ]
        case .distance:
            return [
                CPInformationItem(
                    title: String(localized: "Distanza dall’ultima rigenerazione"),
                    detail: formatted(dpf.distanceSinceLastRegenKm, fractionDigits: 1, unit: "km")
                ),
                CPInformationItem(
                    title: String(localized: "Rigenerazioni totali"),
                    detail: formatted(dpf.totalRegenCount, fractionDigits: 0)
                ),
                updated,
            ]
        case .exhaust:
            return [
                CPInformationItem(
                    title: String(localized: "Temperatura gas di scarico"),
                    detail: formatted(dpf.exhaustTempC, fractionDigits: 0, unit: "°C")
                ),
                CPInformationItem(
                    title: String(localized: "Rigenerazione"),
                    detail: regenerationStatusText(for: dpf)
                ),
                updated,
            ]
        case .regenerationCount:
            return [
                CPInformationItem(
                    title: String(localized: "Rigenerazioni totali"),
                    detail: formatted(dpf.totalRegenCount, fractionDigits: 0)
                ),
                CPInformationItem(
                    title: String(localized: "Distanza dall’ultima rigenerazione"),
                    detail: formatted(dpf.distanceSinceLastRegenKm, fractionDigits: 1, unit: "km")
                ),
                updated,
            ]
        case .oil:
            return [
                CPInformationItem(
                    title: String(localized: "Stato pressione olio"),
                    detail: dpf.oilPressureStatusText ?? "—"
                ),
                updated,
            ]
        case .battery:
            return [
                CPInformationItem(
                    title: String(localized: "Tensione batteria"),
                    detail: formatted(dpf.batteryVoltage, fractionDigits: 1, unit: "V")
                ),
                updated,
            ]
        case .data:
            return [
                CPInformationItem(
                    title: String(localized: "Stato connessione"),
                    detail: connectionStatusText
                ),
                CPInformationItem(
                    title: String(localized: "Origine dati"),
                    detail: session.status == .running && session.hasLiveTelemetry
                        ? String(localized: "Live")
                        : (dpf.hasTelemetry ? String(localized: "Salvati") : "—")
                ),
                CPInformationItem(
                    title: String(localized: "Avvisi CarPlay"),
                    detail: session.carPlayAlertsEnabled
                        ? String(localized: "Attivi")
                        : String(localized: "Disattivati")
                ),
                updated,
            ]
        }
    }

    private func configureNavigationButtons(on template: CPGridTemplate) {
        template.leadingNavigationBarButtons = [makeConnectionBarButton()]
        template.trailingNavigationBarButtons = [
            makeAlertToggleBarButton(),
            makeNotificationTestBarButton(),
        ]
    }

    private func makeConnectionBarButton() -> CPBarButton {
        let action = session.status.carPlayConnectionAction
        let title: String

        switch action {
        case .connect:
            title = String(localized: "Connetti")
        case .cancel:
            title = String(localized: "Annulla")
        case .disconnect:
            title = String(localized: "Disconnetti")
        }

        let button = CPBarButton(title: title) { [weak self] _ in
            self?.performCurrentConnectionAction()
        }
        button.buttonStyle = .rounded
        return button
    }

    private func makeAlertToggleBarButton() -> CPBarButton {
        let symbol = session.carPlayAlertsEnabled ? "bell.fill" : "bell.slash.fill"
        let button = CPBarButton(image: symbolImage(named: symbol)) { [weak self] _ in
            self?.toggleCarPlayAlerts()
        }
        button.buttonStyle = .rounded
        return button
    }

    private func makeNotificationTestBarButton() -> CPBarButton {
        let symbol = session.alertAuthorization.carPlayNotificationIssues.isEmpty
            ? "ellipsis.circle"
            : "exclamationmark.triangle.fill"
        let button = CPBarButton(image: symbolImage(named: symbol)) { [weak self] _ in
            self?.showNotificationTestMenu()
        }
        button.buttonStyle = .rounded
        return button
    }

    private func toggleCarPlayAlerts() {
        Task { [weak self] in
            guard let self else { return }
            await session.toggleCarPlayAlerts()
            refreshDashboard()
        }
    }

    private func showDetails(_ kind: CarPlayDetailKind) {
        guard let interfaceController, detailsTemplate == nil else { return }
        let details = CPInformationTemplate(
            title: detailTitle(for: kind),
            layout: .twoColumn,
            items: makeInformationItems(for: kind),
            actions: []
        )
        detailKind = kind
        detailsTemplate = details
        interfaceController.pushTemplate(details, animated: true) { [weak self] success, error in
            if !success {
                self?.detailsTemplate = nil
                self?.detailKind = nil
                OBDLog.log("CarPlay: DPF details failed: \(error?.localizedDescription ?? "unknown error")")
            }
        }
    }

    private func detailTitle(for kind: CarPlayDetailKind) -> String {
        switch kind {
        case .dpf: return String(localized: "Carico DPF")
        case .regeneration: return String(localized: "Rigenerazione")
        case .distance: return String(localized: "Distanza dall’ultima rigenerazione")
        case .exhaust: return String(localized: "Temperatura gas di scarico")
        case .regenerationCount: return String(localized: "Rigenerazioni totali")
        case .oil: return String(localized: "Stato pressione olio")
        case .battery: return String(localized: "Tensione batteria")
        case .data: return String(localized: "Ultimo aggiornamento")
        }
    }

    private func showNotificationTestMenu() {
        Task { [weak self] in
            guard let self else { return }
            await session.refreshNotificationAuthorization()
            refreshDashboard()
            presentNotificationTestMenu()
        }
    }

    private func presentNotificationTestMenu() {
        guard let interfaceController, !isPresentingAlert else { return }

        var actions: [CPAlertAction] = []
        if #available(iOS 18.4, *),
           session.alertAuthorization.authorization == .authorized
        {
            actions.append(CPAlertAction(
                title: String(localized: "Test sistema · 10 s"),
                style: .default
            ) { [weak self] _ in
                guard let self else { return }
                dismissPresentedTemplate { [weak self] in
                    self?.queueCarPlaySystemTest()
                }
            })
        }
        actions.append(CPAlertAction(
            title: String(localized: "Test alert CarPlay"),
            style: .default
        ) { [weak self] _ in
            guard let self else { return }
            dismissPresentedTemplate { [weak self] in
                self?.presentInformationalAlert([
                    String(localized: "Alert CarPlay visibile correttamente."),
                    String(localized: "Alert CarPlay OK"),
                ])
            }
        })
        actions.append(CPAlertAction(
            title: String(localized: "Chiudi"),
            style: .cancel
        ) { [weak self] _ in
            self?.dismissPresentedTemplate {}
        })

        let sheet = CPActionSheetTemplate(
            title: String(localized: "Notifiche CarPlay"),
            message: notificationDiagnosticMessage,
            actions: actions
        )
        isPresentingAlert = true
        interfaceController.presentTemplate(sheet, animated: true) { [weak self] success, error in
            if !success {
                self?.isPresentingAlert = false
                OBDLog.log("CarPlay: notification test menu failed: \(error?.localizedDescription ?? "unknown error")")
            }
        }
    }

    private var notificationDiagnosticMessage: String {
        let localStatus = session.carPlayAlertsEnabled
            ? String(localized: "Avvisi Alpha su CarPlay attivi.")
            : String(localized: "Avvisi Alpha su CarPlay disattivati.")

        guard #available(iOS 18.4, *) else {
            return localStatus + "\n"
                + String(localized: "Le notifiche di sistema Driving Task richiedono iOS 18.4. Usa il test alert CarPlay.")
        }

        let issues = session.alertAuthorization.carPlayNotificationIssues
        let status: String
        if issues.isEmpty {
            status = String(localized: "Mostra in CarPlay, Time Sensitive e suoni sono attivi.")
                + " "
                + String(localized: "Full immersion Guida può comunque silenziare l’avviso.")
        } else {
            status = issues.map(notificationIssueText).joined(separator: " · ")
        }
        let instruction = session.alertAuthorization.authorization == .authorized
            ? String(localized: "Per il test sistema, tocca il pulsante e torna subito alla Home CarPlay.")
            : String(localized: "Concedi prima il permesso notifiche dall’iPhone.")
        return localStatus + "\n" + status + "\n" + instruction
    }

    private func notificationIssueText(_ issue: CarPlayNotificationIssue) -> String {
        switch issue {
        case .checking:
            return String(localized: "Verifica impostazioni in corso")
        case .permissionRequired:
            return String(localized: "Permesso notifiche non ancora concesso")
        case .permissionDenied:
            return String(localized: "Permesso notifiche negato")
        case .carPlayDisabled:
            return String(localized: "Mostra in CarPlay disattivato")
        case .alertsDisabled:
            return String(localized: "Banner notifiche disattivati")
        case .timeSensitiveDisabled:
            return String(localized: "Time Sensitive disattivate")
        case .soundDisabled:
            return String(localized: "Suoni disattivati")
        }
    }

    private func queueCarPlaySystemTest() {
        Task { [weak self] in
            guard let self else { return }
            let queued = await session.testCarPlaySystemNotification()
            refreshDashboard()
            guard !queued else {
                OBDLog.log("CarPlay: system notification test queued; return Home")
                return
            }
            presentInformationalAlert([
                String(localized: "Impossibile accodare la notifica di test."),
                String(localized: "Test notifica non riuscito"),
            ])
        }
    }

    private func dismissPresentedTemplate(then action: @escaping @MainActor () -> Void) {
        guard let interfaceController else {
            isPresentingAlert = false
            action()
            return
        }
        interfaceController.dismissTemplate(animated: true) { [weak self] success, error in
            self?.isPresentingAlert = false
            if !success {
                OBDLog.log("CarPlay: modal dismissal failed: \(error?.localizedDescription ?? "unknown error")")
                return
            }
            action()
        }
    }

    private func presentInformationalAlert(_ titleVariants: [String]) {
        guard let interfaceController, !isPresentingAlert else { return }
        let dismissAction = CPAlertAction(
            title: String(localized: "OK"),
            style: .default
        ) { [weak self] _ in
            self?.dismissPresentedTemplate {}
        }
        let alert = CPAlertTemplate(titleVariants: titleVariants, actions: [dismissAction])
        isPresentingAlert = true
        interfaceController.presentTemplate(alert, animated: true) { [weak self] success, error in
            if !success {
                self?.isPresentingAlert = false
                OBDLog.log("CarPlay: informational alert failed: \(error?.localizedDescription ?? "unknown error")")
            }
        }
    }

    /// Re-read the status at tap time. CarPlay may still be displaying a
    /// button created before an asynchronous connect/failure transition.
    private func performCurrentConnectionAction() {
        performConnectionAction(session.status.carPlayConnectionAction)
    }

    private func performConnectionAction(_ action: CarPlayConnectionAction) {
        switch action {
        case .connect:
            if session.status == .simulating {
                session.stop()
            }
            session.start()
            OBDLog.log("CarPlay: connection requested")
        case .cancel:
            session.stop()
            OBDLog.log("CarPlay: connection cancelled")
        case .disconnect:
            session.stop()
            OBDLog.log("CarPlay: session disconnected")
        }
        refreshDashboard()
    }

    private var connectionStatusText: String {
        switch session.status {
        case .idle:
            return session.carPlayDPFState.hasTelemetry
                ? String(localized: "Disconnesso · ultimo dato salvato")
                : String(localized: "Disconnesso")
        case .connecting:
            return String(localized: "Connessione all’adattatore…")
        case .running:
            return session.hasLiveTelemetry
                ? String(localized: "Connesso · dati live")
                : String(localized: "Connesso · attesa dati ECU")
        case .simulating:
            return String(localized: "Test disponibile solo su iPhone")
        case .failed:
            return String(localized: "Connessione interrotta · tocca Connetti")
        }
    }

    private func regenerationStatusText(for dpf: DPFState) -> String {
        switch dpf.effectiveRegenerationMode {
        case .none:
            return String(localized: "Non attiva")
        case .passive:
            return String(localized: "Passiva")
        case .active:
            return String(localized: "Attiva · non spegnere il motore")
        }
    }

    private func formatted(
        _ value: Double?,
        fractionDigits: Int,
        unit: String? = nil
    ) -> String {
        guard let value else { return "—" }
        let number = value.formatted(
            .number.precision(.fractionLength(fractionDigits))
        )
        guard let unit else { return number }
        return "\(number) \(unit)"
    }

    private func presentRegenerationAlert(_ event: CarPlayRegenerationAlertEvent) {
        guard let interfaceController, !isPresentingAlert else { return }

        let titleVariants: [String]
        switch event {
        case .started:
            titleVariants = [
                String(localized: "Rigenerazione DPF iniziata — non spegnere il motore."),
                String(localized: "Rigenerazione DPF iniziata"),
            ]
        case .finished:
            titleVariants = [
                String(localized: "Rigenerazione DPF completata."),
                String(localized: "Rigenerazione completata"),
            ]
        }

        let dismissAction = CPAlertAction(
            title: String(localized: "OK"),
            style: .default
        ) { [weak self] _ in
            guard let self else { return }
            self.interfaceController?.dismissTemplate(animated: true) { _, _ in
                self.isPresentingAlert = false
            }
        }
        let alert = CPAlertTemplate(titleVariants: titleVariants, actions: [dismissAction])
        isPresentingAlert = true
        interfaceController.presentTemplate(alert, animated: true) { [weak self] success, error in
            if !success {
                self?.isPresentingAlert = false
                OBDLog.log("CarPlay: regeneration alert failed: \(error?.localizedDescription ?? "unknown error")")
            }
        }
    }
}
