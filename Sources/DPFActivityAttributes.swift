import ActivityKit
import Foundation

/// Shared data contract between the phone app and the WidgetKit extension.
/// A Live Activity needs no App Group: ActivityKit delivers each update to
/// the extension and also surfaces the compact presentation in CarPlay.
struct DPFActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var loadPercent: Int?
        var regenProgressPercent: Int?
        var isRegenerating: Bool
        var exhaustTemperatureC: Int?
        var updatedAt: Date
    }

    var vehicleName: String
}
