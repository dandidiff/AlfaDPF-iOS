import ActivityKit
import Foundation

/// Owns the single glanceable DPF Live Activity. Local updates do not require
/// push notifications, an App Group, or the restricted full-CarPlay
/// entitlement.
@MainActor
final class DPFLiveActivityController {
    private var activity: Activity<DPFActivityAttributes>?
    private var lastContent: DPFActivityAttributes.ContentState?
    private var lastActivityUpdateAt: Date?

    func update(with dpf: DPFState) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard dpf.cloggingPercent != nil || dpf.regenProgressPercent != nil else { return }

        let state = DPFActivityAttributes.ContentState(
            loadPercent: dpf.cloggingPercent.map { Int($0.rounded()).clamped(to: 0...100) },
            regenProgressPercent: dpf.regenProgressPercent.map { Int($0.rounded()).clamped(to: 0...100) },
            isRegenerating: dpf.regenActive == true,
            exhaustTemperatureC: dpf.exhaustTempC.map { Int($0.rounded()) },
            updatedAt: dpf.timestamp
        )

        let now = Date()
        if let lastContent,
           lastContent.loadPercent == state.loadPercent,
           lastContent.regenProgressPercent == state.regenProgressPercent,
           lastContent.isRegenerating == state.isRegenerating,
           lastContent.exhaustTemperatureC == state.exhaustTemperatureC,
           let lastActivityUpdateAt,
           now.timeIntervalSince(lastActivityUpdateAt) < 15 {
            return
        }

        let content = ActivityContent(
            state: state,
            staleDate: now.addingTimeInterval(30)
        )

        do {
            if let current = activity ?? Activity<DPFActivityAttributes>.activities.first {
                activity = current
                await current.update(content)
            } else {
                activity = try Activity.request(
                    attributes: DPFActivityAttributes(vehicleName: "Alfa Romeo"),
                    content: content,
                    pushType: nil
                )
            }
            lastContent = state
            lastActivityUpdateAt = now
        } catch {
            OBDLog.log("live activity failed: \(error.localizedDescription)")
        }
    }

    func end() async {
        let current = activity ?? Activity<DPFActivityAttributes>.activities.first
        guard let current else { return }

        let final = lastContent ?? DPFActivityAttributes.ContentState(
            loadPercent: nil,
            regenProgressPercent: nil,
            isRegenerating: false,
            exhaustTemperatureC: nil,
            updatedAt: .init()
        )
        let content = ActivityContent(state: final, staleDate: nil)
        await current.end(content, dismissalPolicy: .immediate)
        activity = nil
        lastContent = nil
        lastActivityUpdateAt = nil
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
