import CarPlay
import Foundation
import UIKit

/// Native CarPlay driving-task scene. CarPlay and the phone share the same
/// `MonitorSession`, so every action controls one BLE adapter and one ECU poller.
@MainActor
@objc(CarPlaySceneDelegate)
final class CarPlaySceneDelegate: UIResponder,
    CPTemplateApplicationSceneDelegate,
    CPInterfaceControllerDelegate
{
    private weak var interfaceController: CPInterfaceController?
    private var dashboardTemplate: CPInformationTemplate?
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
        self.interfaceController = nil
        regenerationAlertTracker = CarPlayRegenerationAlertTracker()
        isPresentingAlert = false
        OBDLog.log("CarPlay: dashboard disconnected; phone session preserved")
    }

    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        if aTemplate is CPAlertTemplate {
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

    private func makeDashboardTemplate() -> CPInformationTemplate {
        CPInformationTemplate(
            title: String(localized: "Alpha DPF Monitor"),
            layout: .twoColumn,
            items: makeInformationItems(),
            actions: [makeConnectionButton()]
        )
    }

    private func refreshDashboard() {
        guard let dashboardTemplate else { return }
        dashboardTemplate.items = makeInformationItems()
        dashboardTemplate.actions = [makeConnectionButton()]

        let telemetryIsLive = session.status == .running && session.hasLiveTelemetry
        let event = regenerationAlertTracker.observe(
            isRegenerating: session.dpf.regenActive,
            telemetryIsLive: telemetryIsLive
        )
        guard let event else { return }

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

    private func makeInformationItems() -> [CPInformationItem] {
        let dpf = session.carPlayDPFState
        let hasTimestamp = dpf.hasTelemetry

        return [
            CPInformationItem(
                title: String(localized: "Stato connessione"),
                detail: connectionStatusText
            ),
            CPInformationItem(
                title: String(localized: "Carico DPF"),
                detail: formatted(dpf.cloggingPercent, fractionDigits: 0, unit: "%")
            ),
            CPInformationItem(
                title: String(localized: "Avanzamento rigenerazione"),
                detail: formatted(dpf.regenProgressPercent, fractionDigits: 0, unit: "%")
            ),
            CPInformationItem(
                title: String(localized: "Distanza dall’ultima rigenerazione"),
                detail: formatted(dpf.distanceSinceLastRegenKm, fractionDigits: 1, unit: "km")
            ),
            CPInformationItem(
                title: String(localized: "Temperatura gas di scarico"),
                detail: formatted(dpf.exhaustTempC, fractionDigits: 0, unit: "°C")
            ),
            CPInformationItem(
                title: String(localized: "Rigenerazioni totali"),
                detail: formatted(dpf.totalRegenCount, fractionDigits: 0)
            ),
            CPInformationItem(
                title: String(localized: "Stato pressione olio"),
                detail: dpf.oilPressureStatusText ?? "—"
            ),
            CPInformationItem(
                title: String(localized: "Tensione batteria"),
                detail: formatted(dpf.batteryVoltage, fractionDigits: 1, unit: "V")
            ),
            CPInformationItem(
                title: String(localized: "Rigenerazione"),
                detail: regenerationStatusText(for: dpf)
            ),
            CPInformationItem(
                title: String(localized: "Ultimo aggiornamento"),
                detail: hasTimestamp
                    ? dpf.timestamp.formatted(date: .omitted, time: .standard)
                    : "—"
            ),
        ]
    }

    private func makeConnectionButton() -> CPTextButton {
        let action = session.status.carPlayConnectionAction
        let title: String
        let style: CPTextButtonStyle

        switch action {
        case .connect:
            title = String(localized: "Connetti")
            style = .confirm
        case .cancel:
            title = String(localized: "Annulla connessione")
            style = .cancel
        case .disconnect:
            title = String(localized: "Disconnetti")
            style = .normal
        }

        return CPTextButton(title: title, textStyle: style) { [weak self] _ in
            self?.performCurrentConnectionAction()
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
