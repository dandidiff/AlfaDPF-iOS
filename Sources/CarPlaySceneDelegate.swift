import CarPlay
import Foundation
import UIKit

private enum CarPlayDetailKind: Equatable, Sendable {
    case dpf
    case regeneration
    case distance
    case exhaust
    case progress
    case totalRegenerations
    case oil
    case battery
}

private enum CarPlayDashboardIcon {
    case dpf
    case regeneration
    case distance
    case exhaust
    case progress
    case totalRegenerations
    case oil
    case battery

    var symbolName: String? {
        switch self {
        case .dpf: return nil
        case .regeneration: return "arrow.triangle.2.circlepath"
        case .distance: return "road.lanes"
        case .exhaust: return "thermometer.high"
        case .progress: return "gauge.with.dots.needle.50percent"
        case .totalRegenerations: return "number.circle.fill"
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

    static func barImage(
        symbolName: String,
        color: UIColor,
        displayScale: CGFloat
    ) -> UIImage {
        // CPBarButton exposes its image, but not a public tint property. Draw
        // the symbol in the user's accent and keep it original so CarPlay can
        // display that supported customization without relying on private
        // template/background APIs.
        let size = CGSize(width: 30, height: 30)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = max(displayScale, 1)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            drawSymbol(
                named: symbolName,
                in: CGRect(x: 6.5, y: 6.5, width: 17, height: 17),
                color: color,
                weight: .semibold
            )
        }
        return image.withRenderingMode(.alwaysOriginal)
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

private struct CarPlayDashboardRenderSignature: Equatable, Sendable {
    var title: String
    var tileValues: [String]
    var iconTones: [CarPlayDashboardIconTone]
    var connectionAction: CarPlayConnectionAction
    var alertsEnabled: Bool
    var notificationIssues: [CarPlayNotificationIssue]
    var accent: String
    var language: String
    var displayScale: Double
}

private struct CarPlayDetailRenderSignature: Equatable, Sendable {
    var kind: CarPlayDetailKind
    var state: DPFState
    var language: String
}

private struct CarPlayRenderSignature: Equatable, Sendable {
    var dashboard: CarPlayDashboardRenderSignature
    var details: CarPlayDetailRenderSignature?
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
    private var periodicRefreshTask: Task<Void, Never>?
    private var eventRefreshTask: Task<Void, Never>?
    private var deferredRefreshTask: Task<Void, Never>?
    private var deferredRefreshDeadline: Date?
    private var refreshGate = CarPlayRefreshGate<CarPlayRenderSignature>()
    private var lastDashboardSignature: CarPlayDashboardRenderSignature?
    private var lastDetailSignature: CarPlayDetailRenderSignature?
    private var refreshMetrics = CarPlayRefreshMetrics()
    private var lastMetricsLogAt: Date?
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
        interfaceController.setRootTemplate(template, animated: false) { [weak self] success, error in
            if success {
                OBDLog.log("CarPlay: dashboard connected")
            } else {
                self?.refreshMetrics.recordFailure()
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
        periodicRefreshTask?.cancel()
        eventRefreshTask?.cancel()
        deferredRefreshTask?.cancel()
        periodicRefreshTask = nil
        eventRefreshTask = nil
        deferredRefreshTask = nil
        deferredRefreshDeadline = nil
        logRefreshMetricsIfNeeded(at: Date(), force: true)
        refreshGate.reset()
        lastDashboardSignature = nil
        lastDetailSignature = nil
        refreshMetrics = CarPlayRefreshMetrics()
        lastMetricsLogAt = nil
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
        periodicRefreshTask?.cancel()
        eventRefreshTask?.cancel()
        deferredRefreshTask?.cancel()
        deferredRefreshTask = nil
        deferredRefreshDeadline = nil

        let events = session.carPlayRefreshEvents()
        refreshDashboard(trigger: .interaction)

        periodicRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: CarPlayRefreshPolicy.interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.refreshDashboard(trigger: .periodic)
            }
        }

        eventRefreshTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                self.refreshDashboard(trigger: event.trigger)
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

    private func refreshDashboard(trigger: CarPlayRefreshTrigger = .interaction) {
        guard let dashboardTemplate else { return }
        observeRegenerationAlertIfNeeded()

        let now = Date()
        let dashboardSignature = makeDashboardRenderSignature()
        let detailSignature = makeDetailRenderSignature()
        let signature = CarPlayRenderSignature(
            dashboard: dashboardSignature,
            details: detailSignature
        )

        refreshMetrics.recordRequest(trigger: trigger)
        let decision = refreshGate.evaluate(
            signature: signature,
            at: now,
            minimumInterval: trigger.minimumInterval
        )
        refreshMetrics.recordDecision(decision)

        switch decision {
        case .skipDuplicate:
            deferredRefreshTask?.cancel()
            deferredRefreshTask = nil
            deferredRefreshDeadline = nil
        case .deferFor(let delay):
            scheduleDeferredRefresh(after: delay)
        case .render:
            deferredRefreshTask?.cancel()
            deferredRefreshTask = nil
            deferredRefreshDeadline = nil

            if dashboardSignature != lastDashboardSignature {
                dashboardTemplate.updateTitle(dashboardTitle)
                dashboardTemplate.updateGridButtons(makeGridButtons())
                configureNavigationButtons(on: dashboardTemplate)
                lastDashboardSignature = dashboardSignature
            }

            if detailSignature != lastDetailSignature {
                if let detailKind {
                    detailsTemplate?.items = boundedInformationItems(
                        makeInformationItems(for: detailKind)
                    )
                }
                lastDetailSignature = detailSignature
            }
        }

        logRefreshMetricsIfNeeded(at: now)
    }

    private func makeDashboardRenderSignature() -> CarPlayDashboardRenderSignature {
        let dpf = session.carPlayDPFState
        let isLive = CarPlayTelemetryPolicy.isLive(
            status: session.status,
            hasLiveTelemetry: session.hasLiveTelemetry
        )
        let tileValues = [
            compactFormatted(dpf.cloggingPercent, fractionDigits: 1, unit: "%"),
            regenerationGridText(for: dpf),
            compactFormatted(dpf.distanceSinceLastRegenKm, fractionDigits: 0, unit: "km"),
            compactFormatted(dpf.exhaustTempC, fractionDigits: 0, unit: "°C"),
            compactFormatted(dpf.regenProgressPercent, fractionDigits: 0, unit: "%"),
            compactFormatted(dpf.totalRegenCount, fractionDigits: 0),
            dpf.oilPressureStatusText ?? "—",
            batteryTileValue(for: dpf),
        ]
        let iconTones = CarPlayDashboardMetric.allCases.map {
            CarPlayDashboardIconPolicy.tone(for: $0, state: dpf, isLive: isLive)
        }
        return CarPlayDashboardRenderSignature(
            title: dashboardTitle,
            tileValues: tileValues,
            iconTones: iconTones,
            connectionAction: session.status.carPlayConnectionAction,
            alertsEnabled: session.carPlayAlertsEnabled,
            notificationIssues: session.alertAuthorization.carPlayNotificationIssues,
            accent: session.appAccent.rawValue,
            language: session.appLanguage.rawValue,
            displayScale: Double(carDisplayScale)
        )
    }

    private func makeDetailRenderSignature() -> CarPlayDetailRenderSignature? {
        guard let detailKind else { return nil }
        return CarPlayDetailRenderSignature(
            kind: detailKind,
            state: session.carPlayDPFState,
            language: session.appLanguage.rawValue
        )
    }

    private func scheduleDeferredRefresh(after delay: TimeInterval) {
        let boundedDelay = max(delay, 0.01)
        let deadline = Date().addingTimeInterval(boundedDelay)
        guard CarPlayDeferredRefreshPolicy.shouldReplace(
            currentDeadline: deferredRefreshDeadline,
            proposedDeadline: deadline
        ) else { return }

        deferredRefreshTask?.cancel()
        deferredRefreshDeadline = deadline
        deferredRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(boundedDelay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.deferredRefreshTask = nil
            self.deferredRefreshDeadline = nil
            self.refreshDashboard(trigger: .deferredEvent)
        }
    }

    private func logRefreshMetricsIfNeeded(at now: Date, force: Bool = false) {
        let isDue = lastMetricsLogAt.map {
            now.timeIntervalSince($0) >= CarPlayRefreshPolicy.metricsLogInterval
        } ?? true
        guard force || isDue else { return }
        OBDLog.log(refreshMetrics.summaryLine)
        lastMetricsLogAt = now
    }

    private func observeRegenerationAlertIfNeeded() {
        let telemetryIsLive = CarPlayTelemetryPolicy.isLive(
            status: session.status,
            hasLiveTelemetry: session.hasLiveTelemetry
        )
        let event = regenerationAlertTracker.observe(
            isRegenerating: session.dpf.regenActive,
            finishConfirmationSequence: session.dpf.finishConfirmationSequence ?? 0,
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
        let isLive = CarPlayTelemetryPolicy.isLive(
            status: session.status,
            hasLiveTelemetry: session.hasLiveTelemetry
        )
        let buttons: [CPGridButton] = [
            makeMetricGridButton(
                label: AppLocalization.string("DPF"),
                value: compactFormatted(dpf.cloggingPercent, fractionDigits: 1, unit: "%"),
                icon: .dpf,
                accent: dashboardIconColor(for: .dpf, state: dpf, isLive: isLive),
                illuminated: isLive && dpf.loadAlertLevel != .unavailable,
                detailKind: .dpf
            ),
            makeMetricGridButton(
                label: AppLocalization.string("Regen"),
                value: regenerationGridText(for: dpf),
                icon: .regeneration,
                accent: dashboardIconColor(for: .regeneration, state: dpf, isLive: isLive),
                illuminated: isLive && dpf.effectiveRegenerationMode != .none,
                detailKind: .regeneration
            ),
            makeMetricGridButton(
                label: AppLocalization.string("Dall’ultima"),
                value: compactFormatted(dpf.distanceSinceLastRegenKm, fractionDigits: 0, unit: "km"),
                icon: .distance,
                accent: dashboardIconColor(for: .distance, state: dpf, isLive: isLive),
                illuminated: false,
                shortLabel: AppLocalization.string("Ultima"),
                detailKind: .distance
            ),
            makeMetricGridButton(
                label: AppLocalization.string("Scarico"),
                value: compactFormatted(dpf.exhaustTempC, fractionDigits: 0, unit: "°C"),
                icon: .exhaust,
                accent: dashboardIconColor(for: .exhaust, state: dpf, isLive: isLive),
                illuminated: false,
                detailKind: .exhaust
            ),
            makeMetricGridButton(
                label: AppLocalization.string("Avanzamento"),
                value: compactFormatted(dpf.regenProgressPercent, fractionDigits: 0, unit: "%"),
                icon: .progress,
                accent: dashboardIconColor(for: .progress, state: dpf, isLive: isLive),
                illuminated: false,
                detailKind: .progress
            ),
            makeMetricGridButton(
                label: AppLocalization.string("Rigenerazioni"),
                value: compactFormatted(dpf.totalRegenCount, fractionDigits: 0),
                icon: .totalRegenerations,
                accent: dashboardIconColor(for: .totalRegenerations, state: dpf, isLive: isLive),
                illuminated: false,
                detailKind: .totalRegenerations
            ),
            makeMetricGridButton(
                label: AppLocalization.string("Olio"),
                value: dpf.oilPressureStatusText ?? "—",
                icon: .oil,
                accent: dashboardIconColor(for: .oil, state: dpf, isLive: isLive),
                illuminated: false,
                detailKind: .oil
            ),
            makeMetricGridButton(
                label: AppLocalization.string("Batteria"),
                value: batteryTileValue(for: dpf),
                icon: .battery,
                accent: dashboardIconColor(for: .battery, state: dpf, isLive: isLive),
                illuminated: false,
                detailKind: .battery
            ),
        ]
        guard buttons.count <= CarPlayDashboardPolicy.maximumTileCount else {
            OBDLog.log("CarPlay: dashboard tile list exceeded the public maximum")
            return Array(buttons.prefix(CarPlayDashboardPolicy.maximumTileCount))
        }
        return buttons
    }

    private var carPlayAccent: UIColor {
        let rgb = session.appAccent.rgb
        return UIColor(
            red: CGFloat(rgb.red),
            green: CGFloat(rgb.green),
            blue: CGFloat(rgb.blue),
            alpha: 1
        )
    }

    private func dashboardIconColor(
        for metric: CarPlayDashboardMetric,
        state: DPFState,
        isLive: Bool
    ) -> UIColor {
        switch CarPlayDashboardIconPolicy.tone(for: metric, state: state, isLive: isLive) {
        case .neutral:
            return CarPlayDashboardArtwork.neutral
        case .accent:
            return carPlayAccent
        case .dpfSemantic(let level):
            return CarPlayDashboardArtwork.dpfColor(for: level, isLive: true)
        case .regenerationSemantic(let mode):
            return CarPlayDashboardArtwork.regenerationColor(for: mode, isLive: true)
        }
    }

    private var dashboardTitle: String {
        let base = AppLocalization.string("Alpha DPF Monitor")
        guard session.carPlayDPFState.hasTelemetry else { return base }
        let status = CarPlayTelemetryPolicy.isLive(
            status: session.status,
            hasLiveTelemetry: session.hasLiveTelemetry
        )
            ? AppLocalization.string("Live")
            : AppLocalization.string("Salvati")
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
            return AppLocalization.string("Non attiva")
        case .passive:
            return AppLocalization.string("Passiva")
        case .active:
            return compactFormatted(dpf.regenProgressPercent, fractionDigits: 0, unit: "%")
        }
    }

    private func makeInformationItems(for detailKind: CarPlayDetailKind) -> [CPInformationItem] {
        let dpf = session.carPlayDPFState
        let hasTimestamp = dpf.hasTelemetry
        let timestamp = hasTimestamp
            ? dpf.timestamp.formatted(
                Date.FormatStyle(
                    date: .omitted,
                    time: .standard,
                    locale: session.appLanguage.locale
                )
            )
            : "—"
        let updated = CPInformationItem(
            title: AppLocalization.string("Ultimo aggiornamento"),
            detail: timestamp
        )

        switch detailKind {
        case .dpf:
            return [
                CPInformationItem(
                    title: AppLocalization.string("Carico DPF"),
                    detail: formatted(dpf.cloggingPercent, fractionDigits: 1, unit: "%")
                ),
                CPInformationItem(
                    title: AppLocalization.string("Distanza dall’ultima rigenerazione"),
                    detail: formatted(dpf.distanceSinceLastRegenKm, fractionDigits: 1, unit: "km")
                ),
                CPInformationItem(
                    title: AppLocalization.string("Rigenerazioni totali"),
                    detail: formatted(dpf.totalRegenCount, fractionDigits: 0)
                ),
                updated,
            ]
        case .regeneration:
            return [
                CPInformationItem(
                    title: AppLocalization.string("Rigenerazione"),
                    detail: regenerationStatusText(for: dpf)
                ),
                CPInformationItem(
                    title: AppLocalization.string("Avanzamento rigenerazione"),
                    detail: formatted(dpf.regenProgressPercent, fractionDigits: 0, unit: "%")
                ),
                CPInformationItem(
                    title: AppLocalization.string("Temperatura gas di scarico"),
                    detail: formatted(dpf.exhaustTempC, fractionDigits: 0, unit: "°C")
                ),
                updated,
            ]
        case .distance:
            return [
                CPInformationItem(
                    title: AppLocalization.string("Distanza dall’ultima rigenerazione"),
                    detail: formatted(dpf.distanceSinceLastRegenKm, fractionDigits: 1, unit: "km")
                ),
                CPInformationItem(
                    title: AppLocalization.string("Rigenerazioni totali"),
                    detail: formatted(dpf.totalRegenCount, fractionDigits: 0)
                ),
                updated,
            ]
        case .exhaust:
            return [
                CPInformationItem(
                    title: AppLocalization.string("Temperatura gas di scarico"),
                    detail: formatted(dpf.exhaustTempC, fractionDigits: 0, unit: "°C")
                ),
                CPInformationItem(
                    title: AppLocalization.string("Rigenerazione"),
                    detail: regenerationStatusText(for: dpf)
                ),
                updated,
            ]
        case .progress:
            return [
                CPInformationItem(
                    title: AppLocalization.string("Avanzamento rigenerazione"),
                    detail: formatted(dpf.regenProgressPercent, fractionDigits: 0, unit: "%")
                ),
                CPInformationItem(
                    title: AppLocalization.string("Rigenerazione"),
                    detail: regenerationStatusText(for: dpf)
                ),
                CPInformationItem(
                    title: AppLocalization.string("Temperatura gas di scarico"),
                    detail: formatted(dpf.exhaustTempC, fractionDigits: 0, unit: "°C")
                ),
                updated,
            ]
        case .totalRegenerations:
            return [
                CPInformationItem(
                    title: AppLocalization.string("Rigenerazioni totali"),
                    detail: formatted(dpf.totalRegenCount, fractionDigits: 0)
                ),
                CPInformationItem(
                    title: AppLocalization.string("Distanza dall’ultima rigenerazione"),
                    detail: formatted(dpf.distanceSinceLastRegenKm, fractionDigits: 1, unit: "km")
                ),
                updated,
            ]
        case .oil:
            return [
                CPInformationItem(
                    title: AppLocalization.string("Stato pressione olio"),
                    detail: dpf.oilPressureStatusText ?? "—"
                ),
                updated,
            ]
        case .battery:
            return [
                CPInformationItem(
                    title: AppLocalization.string("Stato di carica"),
                    detail: freshBatteryStateOfChargeText(for: dpf)
                ),
                CPInformationItem(
                    title: AppLocalization.string("Tensione batteria"),
                    detail: formatted(dpf.batteryVoltage, fractionDigits: 1, unit: "V")
                ),
                updated,
            ]
        }
    }

    private func batteryTileValue(for dpf: DPFState) -> String {
        let isLive = CarPlayTelemetryPolicy.isLive(
            status: session.status,
            hasLiveTelemetry: session.hasLiveTelemetry
        )
        switch BatteryMetricPresentation.resolve(state: dpf, isLive: isLive).headline {
        case .stateOfChargePercent(let percent):
            return compactFormatted(percent, fractionDigits: 0, unit: "%")
        case .voltage(let voltage):
            return compactFormatted(voltage, fractionDigits: 1, unit: "V")
        case .unavailable:
            return "—"
        }
    }

    private func freshBatteryStateOfCharge(for dpf: DPFState) -> Double? {
        let isLive = CarPlayTelemetryPolicy.isLive(
            status: session.status,
            hasLiveTelemetry: session.hasLiveTelemetry
        )
        guard case .stateOfChargePercent(let percent) = BatteryMetricPresentation.resolve(
            state: dpf,
            isLive: isLive
        ).headline else { return nil }
        return percent
    }

    private func freshBatteryStateOfChargeText(for dpf: DPFState) -> String {
        if let soc = freshBatteryStateOfCharge(for: dpf) {
            return formatted(soc, fractionDigits: 0, unit: "%")
        }
        if dpf.batteryStateOfChargePercent != nil {
            return AppLocalization.string("Dati non disponibili")
        }
        return "—"
    }

    private func boundedInformationItems(_ items: [CPInformationItem]) -> [CPInformationItem] {
        assert(items.count <= CarPlayDashboardPolicy.maximumInformationItemCount)
        return Array(items.prefix(CarPlayDashboardPolicy.maximumInformationItemCount))
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
            title = AppLocalization.string("Connetti")
        case .cancel:
            title = AppLocalization.string("Annulla")
        case .disconnect:
            title = AppLocalization.string("Disconnetti")
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
                color: session.carPlayAlertsEnabled
                    ? carPlayAccent
                    : CarPlayDashboardArtwork.neutral,
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
                color: carPlayAccent,
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
            let message = session.carPlayAlertsEnabled
                ? AppLocalization.string("Avvisi CarPlay attivi. Gli avvisi di rigenerazione possono apparire anche sul display dell’auto.")
                : AppLocalization.string("Avvisi CarPlay disattivati. Gli avvisi di rigenerazione restano attivi su iPhone.")
            presentInformationalAlert([message])
        }
    }

    private func showDetails(_ kind: CarPlayDetailKind) {
        guard let interfaceController, detailsTemplate == nil else { return }
        let details = CPInformationTemplate(
            title: detailTitle(for: kind),
            layout: .twoColumn,
            items: boundedInformationItems(makeInformationItems(for: kind)),
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
        case .dpf: return AppLocalization.string("Carico DPF")
        case .regeneration: return AppLocalization.string("Rigenerazione")
        case .distance: return AppLocalization.string("Distanza dall’ultima rigenerazione")
        case .exhaust: return AppLocalization.string("Temperatura gas di scarico")
        case .progress: return AppLocalization.string("Avanzamento rigenerazione")
        case .totalRegenerations: return AppLocalization.string("Rigenerazioni totali")
        case .oil: return AppLocalization.string("Stato pressione olio")
        case .battery: return AppLocalization.string("Batteria")
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
                title: AppLocalization.string("Test sistema · 10 s"),
                style: .default
            ) { [weak self] _ in
                guard let self else { return }
                dismissPresentedTemplate { [weak self] in
                    self?.queueCarPlaySystemTest()
                }
            })
        }
        actions.append(CPAlertAction(
            title: AppLocalization.string("Test alert CarPlay"),
            style: .default
        ) { [weak self] _ in
            guard let self else { return }
            dismissPresentedTemplate { [weak self] in
                self?.presentInformationalAlert([
                    AppLocalization.string("Alert CarPlay visibile correttamente."),
                    AppLocalization.string("Alert CarPlay OK"),
                ])
            }
        })
        actions.append(CPAlertAction(
            title: AppLocalization.string("Chiudi"),
            style: .cancel
        ) { [weak self] _ in
            self?.dismissPresentedTemplate {}
        })

        let sheet = CPActionSheetTemplate(
            title: AppLocalization.string("Notifiche CarPlay"),
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
            ? AppLocalization.string("Avvisi Alpha su CarPlay attivi.")
            : AppLocalization.string("Avvisi Alpha su CarPlay disattivati.")

        let testScope = AppLocalization.string(
            "I test notifiche ignorano lo stato della campanella."
        )
        guard #available(iOS 18.4, *) else {
            return localStatus + "\n" + testScope + "\n"
                + AppLocalization.string("Le notifiche di sistema Driving Task richiedono iOS 18.4. Usa il test alert CarPlay.")
        }

        let issues = session.alertAuthorization.carPlayNotificationIssues
        let status: String
        if issues.isEmpty {
            status = AppLocalization.string("Mostra in CarPlay, Time Sensitive e suoni sono attivi.")
                + " "
                + AppLocalization.string("Full immersion Guida può comunque silenziare l’avviso.")
        } else {
            status = issues.map(notificationIssueText).joined(separator: " · ")
        }
        let instruction = session.alertAuthorization.authorization == .authorized
            ? AppLocalization.string("Per il test sistema, tocca il pulsante e torna subito alla Home CarPlay.")
            : AppLocalization.string("Concedi prima il permesso notifiche dall’iPhone.")
        return localStatus + "\n" + testScope + "\n" + status + "\n" + instruction
    }

    private func notificationIssueText(_ issue: CarPlayNotificationIssue) -> String {
        switch issue {
        case .checking:
            return AppLocalization.string("Verifica impostazioni in corso")
        case .permissionRequired:
            return AppLocalization.string("Permesso notifiche non ancora concesso")
        case .permissionDenied:
            return AppLocalization.string("Permesso notifiche negato")
        case .carPlayDisabled:
            return AppLocalization.string("Mostra in CarPlay disattivato")
        case .alertsDisabled:
            return AppLocalization.string("Banner notifiche disattivati")
        case .timeSensitiveDisabled:
            return AppLocalization.string("Time Sensitive disattivate")
        case .soundDisabled:
            return AppLocalization.string("Suoni disattivati")
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
                AppLocalization.string("Impossibile accodare la notifica di test."),
                AppLocalization.string("Test notifica non riuscito"),
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
            title: AppLocalization.string("OK"),
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
                ? AppLocalization.string("Disconnesso · ultimo dato salvato")
                : AppLocalization.string("Disconnesso")
        case .connecting:
            return AppLocalization.string("Connessione all’adattatore…")
        case .running:
            return session.hasLiveTelemetry
                ? AppLocalization.string("Connesso · dati live")
                : AppLocalization.string("Connesso · attesa dati ECU")
        case .simulating:
            return AppLocalization.string("Test disponibile solo su iPhone")
        case .failed:
            return AppLocalization.string("Connessione interrotta · tocca Connetti")
        }
    }

    private func regenerationStatusText(for dpf: DPFState) -> String {
        switch dpf.effectiveRegenerationMode {
        case .none:
            return AppLocalization.string("Non attiva")
        case .passive:
            return AppLocalization.string("Passiva")
        case .active:
            return AppLocalization.string("Attiva · non spegnere il motore")
        }
    }

    private func formatted(
        _ value: Double?,
        fractionDigits: Int,
        unit: String? = nil
    ) -> String {
        guard let value else { return "—" }
        let number = value.formatted(
            .number
                .precision(.fractionLength(fractionDigits))
                .locale(session.appLanguage.locale)
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
            .number
                .precision(.fractionLength(fractionDigits))
                .locale(session.appLanguage.locale)
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
                AppLocalization.string("Rigenerazione DPF iniziata — non spegnere il motore."),
                AppLocalization.string("Rigenerazione DPF iniziata"),
            ]
        case .finished:
            titleVariants = [
                AppLocalization.string("Rigenerazione DPF completata."),
                AppLocalization.string("Rigenerazione completata"),
            ]
        }

        let dismissAction = CPAlertAction(
            title: AppLocalization.string("OK"),
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
