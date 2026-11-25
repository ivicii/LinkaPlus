import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Shared between the app (which starts/updates it) and the widget extension
/// (which draws it). Live Activity shown while LINKA recovery tracking is on.
@available(iOS 16.1, *)
struct TrackingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var statusText: String
        var pointCount: Int
        var lastUpdate: Date
        var positionText: String?
        var distanceText: String? = nil   // "1,2 km" while following
    }
    var lockName: String
}
#endif
