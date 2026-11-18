import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Starts, updates and ends the tracking Live Activity. No-op below iOS 16.1 or
/// when the user has Live Activities disabled.
@available(iOS 16.1, *)
enum LiveActivityManager {
    private static var current: Activity<TrackingActivityAttributes>?

    static func start(lockName: String, state: TrackingActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let attr = TrackingActivityAttributes(lockName: lockName)
        do {
            if #available(iOS 16.2, *) {
                current = try Activity.request(attributes: attr, content: .init(state: state, staleDate: nil))
            } else {
                current = try Activity.request(attributes: attr, contentState: state)
            }
        } catch {
            current = nil
        }
    }

    static func update(_ state: TrackingActivityAttributes.ContentState) {
        guard let a = current else { return }
        Task {
            if #available(iOS 16.2, *) { await a.update(ActivityContent(state: state, staleDate: nil)) }
            else { await a.update(using: state) }
        }
    }

    static func end() {
        guard let a = current else { return }
        current = nil
        Task {
            if #available(iOS 16.2, *) { await a.end(nil, dismissalPolicy: .immediate) }
            else { await a.end(dismissalPolicy: .immediate) }
        }
    }
}
#endif
