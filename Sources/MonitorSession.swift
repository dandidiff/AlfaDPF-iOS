import Foundation
import UIKit
import Observation

/// Phone-side coordinator. Mirrors what `CarPlaySceneDelegate` does for
/// CarPlay, but owned by the SwiftUI view so the phone app works standalone —
/// which is what you actually get to run without CarPlay entitlement.
///
/// Lifecycle: `start()` opens the socket, runs the ELM init, and begins two
/// poll loops (Mode 01 for universal live data, Mode 22 for DPF). `stop()`
/// tears everything down and releases the screen-awake lock.
@MainActor
@Observable
final class MonitorSession {
    enum Status: Equatable {
        case idle
        case connecting
        case running
        case failed(String)
    }

    // Observable state for the UI.
    private(set) var status: Status = .idle
    private(set) var live: Mode01Reader.Live = .init()
    private(set) var dpf: DPFState = .init()
    private(set) var lastRegenEvent: String?

    // Owned components.
    private var obd: OBDConnection?
    private var monitor: DPFMonitor?
    private var mode01: Mode01Reader?
    private var bootTask: Task<Void, Never>?
    private var pollTasks: [Task<Void, Never>] = []
    private let alerts = AlertService()

    func start() {
        guard status == .idle || isFailed(status) else { return }
        status = .connecting
        UIApplication.shared.isIdleTimerDisabled = true

        bootTask?.cancel()
        bootTask = Task { [weak self] in
            await self?.boot()
        }
    }

    func stop() {
        bootTask?.cancel()
        bootTask = nil
        pollTasks.forEach { $0.cancel() }
        pollTasks.removeAll()
        let obd = self.obd
        let monitor = self.monitor
        self.monitor = nil
        self.mode01 = nil
        self.obd = nil
        status = .idle
        UIApplication.shared.isIdleTimerDisabled = false

        Task {
            await monitor?.stop()
            await obd?.stop()
        }
    }

    // MARK: - Boot

    private func boot() async {
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
            status = .failed("Adapter init failed: \(error)")
            await obd.stop()
            return
        }
        guard !Task.isCancelled else {
            await obd.stop()
            return
        }

        let mode01 = Mode01Reader(connection: obd)
        let monitor = DPFMonitor(elm: elm, alerts: alerts)
        self.mode01 = mode01
        self.monitor = monitor
        await monitor.start(interval: .seconds(2))

        status = .running
        startPollLoops(mode01: mode01, monitor: monitor)
    }

    private func startPollLoops(mode01: Mode01Reader, monitor: DPFMonitor) {
        pollTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                let snap = await mode01.poll()
                await MainActor.run { self?.live = snap }
                try? await Task.sleep(for: .seconds(1))
            }
        })
        pollTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                let snap = await monitor.latest
                await MainActor.run { self?.dpf = snap }
                try? await Task.sleep(for: .seconds(1))
            }
        })
    }

    private func isFailed(_ s: Status) -> Bool {
        if case .failed = s { return true }
        return false
    }
}
