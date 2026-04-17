import CarPlay
import UIKit

/// Entry point when the head unit comes online. iOS instantiates this
/// automatically once CarPlay picks up our app — no user tap required. We
/// treat `didConnect` as "engine is on, start monitoring."
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    // Owned here so the monitor lives exactly as long as the CarPlay scene.
    private var obd: OBDConnection?
    private var monitor: DPFMonitor?
    private var bootTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private let alerts = AlertService()

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(buildDashboard(state: .init()), animated: false)

        bootTask?.cancel()
        refreshTask?.cancel()
        bootTask = Task { await bootMonitoring() }
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        let monitor = self.monitor
        let obd = self.obd

        bootTask?.cancel()
        refreshTask?.cancel()
        bootTask = nil
        refreshTask = nil

        interfaceController.popToRootTemplate(animated: false)
        self.interfaceController = nil
        self.monitor = nil
        self.obd = nil

        Task {
            await monitor?.stop()
            await obd?.stop()
        }
    }

    // MARK: - Boot

    private func bootMonitoring() async {
        await alerts.configure()
        guard !Task.isCancelled else { return }

        let obd = OBDConnection()
        self.obd = obd
        await obd.start()
        await obd.isReady()
        guard !Task.isCancelled else {
            await obd.stop()
            return
        }

        let elm = ELM327(connection: obd)
        do {
            try await elm.initializeSession()
        } catch {
            guard !Task.isCancelled else { return }
            await obd.stop()
            pushError("Adapter init failed: \(error)")
            return
        }
        guard !Task.isCancelled else {
            await obd.stop()
            return
        }

        let monitor = DPFMonitor(elm: elm, alerts: alerts)
        self.monitor = monitor
        await monitor.start(interval: .seconds(2))

        // Refresh the dashboard template on a slower cadence than we poll.
        refreshTask = Task { await refreshLoop(monitor: monitor) }
    }

    private func refreshLoop(monitor: DPFMonitor) async {
        while !Task.isCancelled {
            let state = await monitor.latest
            await MainActor.run {
                interfaceController?.setRootTemplate(buildDashboard(state: state), animated: false)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - Templates

    private func buildDashboard(state: DPFState) -> CPInformationTemplate {
        let items: [CPInformationItem] = [
            .init(title: "Soot mass",
                  detail: state.sootMassGrams.map { String(format: "%.1f g", $0) } ?? "—"),
            .init(title: "Since last regen",
                  detail: state.distanceSinceLastRegenKm.map { String(format: "%.0f km", $0) } ?? "—"),
            .init(title: "Exhaust temp",
                  detail: state.exhaustTempC.map { String(format: "%.0f °C", $0) } ?? "—"),
            .init(title: "Regen active",
                  detail: state.regenActive.map { $0 ? "YES" : "no" } ?? "—"),
        ]
        return CPInformationTemplate(
            title: "DPF",
            layout: .leading,
            items: items,
            actions: []
        )
    }

    private func pushError(_ message: String) {
        let alert = CPAlertTemplate(
            titleVariants: [message],
            actions: [CPAlertAction(title: "OK", style: .default, handler: { _ in })]
        )
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }
}
