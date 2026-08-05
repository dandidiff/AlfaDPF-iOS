import ActivityKit
import Foundation

/// Shared data contract between the phone app and the WidgetKit extension.
/// A Live Activity needs no App Group: ActivityKit delivers each update to
/// the extension and also surfaces the compact presentation in CarPlay.
struct DPFActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Kept as a decimal because the proprietary FCA load index can
        /// legitimately exceed 100 and the phone dashboard shows one decimal.
        var loadPercent: Double?
        var regenProgressPercent: Double?
        var isRegenerating: Bool
        var exhaustTemperatureC: Int?
        var updatedAt: Date
    }
}
