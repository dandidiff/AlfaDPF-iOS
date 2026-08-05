import CarPlay
import Foundation
import UIKit

private enum CarPlayDetailKind {
    case dpf
    case regeneration
    case distance
    case exhaust
    case oil
    case battery
}

private enum CarPlayDashboardIcon {
    case dpf
    case regeneration
    case distance
    case exhaust
    case oil
    case battery

    var symbolName: String? {
        switch self {
        case .dpf: return nil
        case .regeneration: return "arrow.triangle.2.circlepath"
        case .distance: return "road.lanes"
        case .exhaust: return "thermometer.high"
        case .oil: return "oilcan.fill"
        case .battery: return "battery.75percent"
        }
    }
}

/// Draws every metric into the same square canvas. CarPlay otherwise scales
/// each SF Symbol from its own intrinsic aspect ratio, which makes wide symbols
/// look stretched and narrow symbols look much larger than their neighbours.
/// The bezels and simple line work intentionally echo warning lamps and gauges
/// from late-80s/90s instrument clusters while staying inside native templates.
private enum CarPlayDashboardArtwork {
    static let neutral = UIColor(white: 0.78, alpha: 1)
    static let green = UIColor(red: 0.18, green: 0.88, blue: 0.38, alpha: 1)
    static let yellow = UIColor(red: 1.00, green: 0.78, blue: 0.08, alpha: 1)
    static let red = UIColor(red: 1.00, green: 0.20, blue: 0.18, alpha: 1)
    static let blue = UIColor(red: 0.08, green: 0.58, blue: 1.00, alpha: 1)

    static func dpfColor(for level: DPFLoadAlertLevel, isLive: Bool) -> UIColor {
        let color: UIColor
        switch level {
        case .unavailable: color = neutral
        case .low: color = green
        case .nearRegeneration: color = yellow
        case .regenerationImminent: color = red
        case .activeRegeneration: color = blue
        }
        return color.withAlphaComponent(isLive ? 1 : 0.58)
    }

    static func regenerationColor(
        for mode: DPFRegenerationMode,
        isLive: Bool
    ) -> UIColor {
        let color: UIColor
        switch mode {
        case .active: color = blue
        case .passive: color = yellow
        case .none: color = neutral
        }
        let alpha: CGFloat = mode == .none ? 0.72 : (isLive ? 1 : 0.58)
        return color.withAlphaComponent(alpha)
    }

    static func gridImage(
        icon: CarPlayDashboardIcon,
        accent: UIColor,
        illuminated: Bool,
        displayScale: CGFloat
    ) -> UIImage {
        // Compile with the project's Xcode 16 / iOS 18 SDK as well as newer
        // SDKs. Referencing iOS 26's maximumGridButtonImageSize behind an
        // availability check still fails name lookup on an older SDK. The
        // 80-point square is the established CarPlay grid slot used by the
        // app and keeps every symbol consistently aspect-fitted.
        let side: CGFloat = 80
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = max(displayScale, 1)

        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let bounds = CGRect(origin: .zero, size: size)
            switch icon {
            case .dpf:
                drawDPFLamp(in: bounds, color: accent, illuminated: illuminated)
            case .regeneration:
                drawRegenerationLamp(in: bounds, color: accent, illuminated: illuminated)
            default:
                drawMetricLamp(
                    in: bounds,
                    symbolName: icon.symbolName ?? "circle",
                    color: accent
                )
            }
            renderer.cgContext.setShadow(offset: .zero, blur: 0)
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    static func barImage(symbolName: String, displayScale: CGFloat) -> UIImage {
        // A transparent square canvas gives both the bell and warning triangle
        // identical optical bounds, with enough breathing room inside the
        // rounded CarPlay navigation-bar button.
        let size = CGSize(width: 30, height: 30)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = max(displayScale, 1)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            drawSymbol(
                named: symbolName,
                in: CGRect(x: 6.5, y: 6.5, width: 17, height: 17),
                color: .white,
                weight: .semibold
            )
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    private static func drawDPFLamp(
        in bounds: CGRect,
        color: UIColor,
        illuminated: Bool
    ) {
        let side = min(bounds.width, bounds.height)
        let ringRect = bounds.insetBy(dx: side * 0.035, dy: side * 0.035)
        let ring = UIBezierPath(ovalIn: ringRect)
        ring.lineWidth = max(3, side * 0.055)
        color.withAlphaComponent(illuminated ? 0.16 : 0.08).setFill()
        ring.fill()
        if illuminated {
            UIGraphicsGetCurrentContext()?.setShadow(
                offset: .zero,
                blur: side * 0.08,
                color: color.withAlphaComponent(0.65).cgColor
            )
        }
        color.setStroke()
        ring.stroke()
        UIGraphicsGetCurrentContext()?.setShadow(offset: .zero, blur: 0)

        let filter = CGRect(
            x: bounds.midX - side * 0.20,
            y: bounds.midY - side * 0.18,
            width: side * 0.40,
            height: side * 0.36
        )
        let filterPath = UIBezierPath(
            roundedRect: filter,
            cornerRadius: side * 0.035
        )
        filterPath.lineWidth = max(2.2, side * 0.035)
        filterPath.lineJoinStyle = .round
        color.setStroke()
        filterPath.stroke()

        let pipe = UIBezierPath()
        pipe.move(to: CGPoint(x: ringRect.minX + side * 0.07, y: bounds.midY))
        pipe.addLine(to: CGPoint(x: filter.minX, y: bounds.midY))
        pipe.move(to: CGPoint(x: filter.maxX, y: bounds.midY))
        pipe.addLine(to: CGPoint(x: ringRect.maxX - side * 0.07, y: bounds.midY))
        pipe.lineWidth = max(2.2, side * 0.035)
        pipe.lineCapStyle = .round
        pipe.stroke()

        let dotRadius = side * 0.019
        color.setFill()
        for row in 0..<3 {
            for column in 0..<3 {
                let center = CGPoint(
                    x: filter.minX + filter.width * CGFloat(column + 1) / 4,
                    y: filter.minY + filter.height * CGFloat(row + 1) / 4
                )
                UIBezierPath(
                    ovalIn: CGRect(
                        x: center.x - dotRadius,
                        y: center.y - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    )
                ).fill()
            }
        }
    }

    private static func drawRegenerationLamp(
        in bounds: CGRect,
        color: UIColor,
        illuminated: Bool
    ) {
        let side = min(bounds.width, bounds.height)
        let ringRect = bounds.insetBy(dx: side * 0.07, dy: side * 0.07)
        let ring = UIBezierPath(ovalIn: ringRect)
        ring.lineWidth = max(2.2, side * 0.034)
        color.withAlphaComponent(illuminated ? 0.14 : 0.04).setFill()
        ring.fill()
        if illuminated {
            UIGraphicsGetCurrentContext()?.setShadow(
                offset: .zero,
                blur: side * 0.075,
                color: color.withAlphaComponent(0.60).cgColor
            )
        }
        color.withAlphaComponent(illuminated ? 1 : 0.55).setStroke()
        ring.stroke()
        UIGraphicsGetCurrentContext()?.setShadow(offset: .zero, blur: 0)

        drawSymbol(
            named: "arrow.triangle.2.circlepath",
            in: ringRect.insetBy(dx: side * 0.08, dy: side * 0.08),
            color: color,
            weight: .bold
        )
    }

    private static func drawMetricLamp(
        in bounds: CGRect,
        symbolName: String,
        color: UIColor
    ) {
        let side = min(bounds.width, bounds.height)
        let bezelRect = bounds.insetBy(dx: side * 0.08, dy: side * 0.08)
        let bezel = UIBezierPath(
            roundedRect: bezelRect,
            cornerRadius: side * 0.11
        )
        bezel.lineWidth = max(1.5, side * 0.024)
        neutral.withAlphaComponent(0.28).setStroke()
        bezel.stroke()

        drawSymbol(
            named: symbolName,
            in: bezelRect.insetBy(dx: side * 0.065, dy: side * 0.065),
            color: color,
            weight: .medium
        )
    }

    private static func drawSymbol(
        named name: String,
        in rect: CGRect,
        color: UIColor,
        weight: UIImage.SymbolWeight
    ) {
        let configuration = UIImage.SymbolConfiguration(
            pointSize: rect.height,
            weight: weight
        )
        guard let source = UIImage(systemName: name, withConfiguration: configuration) else {
            return
        }
        let symbol = source.withTintColor(color, renderingMode: .alwaysOriginal)
        symbol.draw(in: aspectFit(source.size, inside: rect))
    }

    private static func aspectFit(_ size: CGSize, inside rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: rect.midX - fitted.width / 2,
            y: rect.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
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
            title: dashboardTitle,
            gridButtons: makeGridButtons()
        )
        configureNavigationButtons(on: template)
        return template
    }

    private func refreshDashboard() {
        guard let dashboardTemplate else { return }
        dashboardTemplate.updateTitle(dashboardTitle)
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
            return session.alertAuthorization.canPresentSystemCarPlayAlert
        }
        return false
    }

    private func makeGridButtons() -> [CPGridButton] {
        let dpf = session.carPlayDPFState
        let isLive = session.status == .running && session.hasLiveTelemetry
        let dpfColor = CarPlayDashboardArtwork.dpfColor(
            for: dpf.loadAlertLevel,
            isLive: isLive
        )
        let regenerationColor = CarPlayDashboardArtwork.regenerationColor(
            for: dpf.effectiveRegenerationMode,
            isLive: isLive
        )
        return [
            makeMetricGridButton(
                label: String(localized: "DPF"),
                value: compactFormatted(dpf.cloggingPercent, fractionDigits: 1, unit: "%"),
                icon: .dpf,
                accent: dpfColor,
                illuminated: dpf.loadAlertLevel != .unavailable,
                detailKind: .dpf
            ),
            makeMetricGridButton(
                label: String(localized: "Regen"),
                value: regenerationGridText(for: dpf),
                icon: .regeneration,
                accent: regenerationColor,
                illuminated: dpf.effectiveRegenerationMode != .none,
                detailKind: .regeneration
            ),
            makeMetricGridButton(
                label: String(localized: "Dall’ultima"),
                value: compactFormatted(dpf.distanceSinceLastRegenKm, fractionDigits: 0, unit: "km"),
                icon: .distance,
                accent: CarPlayDashboardArtwork.neutral,
                illuminated: false,
                shortLabel: String(localized: "Ultima"),
                detailKind: .distance
            ),
            makeMetricGridButton(
                label: String(localized: "Scarico"),
                value: compactFormatted(dpf.exhaustTempC, fractionDigits: 0, unit: "°C"),
                icon: .exhaust,
                accent: CarPlayDashboardArtwork.neutral,
                illuminated: false,
                detailKind: .exhaust
            ),
            makeMetricGridButton(
                label: String(localized: "Olio"),
                value: dpf.oilPressureStatusText ?? "—",
                icon: .oil,
                accent: CarPlayDashboardArtwork.neutral,
                illuminated: false,
                detailKind: .oil
            ),
            makeMetricGridButton(
                label: String(localized: "Batteria"),
                value: compactFormatted(dpf.batteryVoltage, fractionDigits: 1, unit: "V"),
                icon: .battery,
                accent: CarPlayDashboardArtwork.neutral,
                illuminated: false,
                detailKind: .battery
            ),
        ]
    }

    private var dashboardTitle: String {
        let base = String(localized: "Alpha DPF")
        guard session.carPlayDPFState.hasTelemetry else { return base }
        let status = session.status == .running && session.hasLiveTelemetry
            ? String(localized: "Live")
            : String(localized: "Salvati")
        return "\(base) · \(status)"
    }

    private var carDisplayScale: CGFloat {
        interfaceController?.carTraitCollection.displayScale ?? 2
    }

    private func makeMetricGridButton(
        label: String,
        value: String,
        icon: CarPlayDashboardIcon,
        accent: UIColor,
        illuminated: Bool,
        shortLabel: String? = nil,
        detailKind: CarPlayDetailKind
    ) -> CPGridButton {
        let titleVariants: [String]
        if let shortLabel {
            // On compact dashboards CarPlay chooses the first variant that
            // fits. Keep the reading ahead of the descriptive fallback so the
            // distance can never disappear merely because the label is long.
            titleVariants = [
                "\(shortLabel) · \(value)",
                value,
                label,
            ]
        } else {
            titleVariants = ["\(label) · \(value)", "\(label) \(value)", label]
        }

        return CPGridButton(
            titleVariants: titleVariants,
            image: CarPlayDashboardArtwork.gridImage(
                icon: icon,
                accent: accent,
                illuminated: illuminated,
                displayScale: carDisplayScale
            )
        ) { [weak self] _ in
            self?.showDetails(detailKind)
        }
    }

    private func regenerationGridText(for dpf: DPFState) -> String {
        switch dpf.effectiveRegenerationMode {
        case .none:
            return String(localized: "Non attiva")
        case .passive:
            return String(localized: "Passiva")
        case .active:
            return compactFormatted(dpf.regenProgressPercent, fractionDigits: 0, unit: "%")
        }
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
                    detail: formatted(dpf.cloggingPercent, fractionDigits: 1, unit: "%")
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
        let button = CPBarButton(
            image: CarPlayDashboardArtwork.barImage(
                symbolName: symbol,
                displayScale: carDisplayScale
            )
        ) { [weak self] _ in
            self?.toggleCarPlayAlerts()
        }
        button.buttonStyle = .rounded
        return button
    }

    private func makeNotificationTestBarButton() -> CPBarButton {
        let symbol = session.alertAuthorization.carPlayNotificationIssues.isEmpty
            ? "ellipsis.circle"
            : "exclamationmark.triangle.fill"
        let button = CPBarButton(
            image: CarPlayDashboardArtwork.barImage(
                symbolName: symbol,
                displayScale: carDisplayScale
            )
        ) { [weak self] _ in
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
        case .oil: return String(localized: "Stato pressione olio")
        case .battery: return String(localized: "Tensione batteria")
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

    private func compactFormatted(
        _ value: Double?,
        fractionDigits: Int,
        unit: String? = nil
    ) -> String {
        guard let value else { return "—" }
        let number = value.formatted(
            .number.precision(.fractionLength(fractionDigits))
        )
        guard let unit else { return number }
        return "\(number)\(unit)"
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
