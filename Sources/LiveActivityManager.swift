import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Starts, updates and ends the tracking Live Activity. No-op below iOS 16.1 or
/// when the user has Live Activities disabled. Re-attaches to an activity that is
/// still running after iOS relaunched the app (the old static-only reference was
/// lost then, so the Dynamic Island froze on its first value).
@available(iOS 16.1, *)
enum LiveActivityManager {
    private static var _current: Activity<TrackingActivityAttributes>?

    private static var current: Activity<TrackingActivityAttributes>? {
        if let c = _current, c.activityState == .active { return c }
        _current = Activity<TrackingActivityAttributes>.activities.first { $0.activityState == .active }
        return _current
    }

    static var isRunning: Bool { current != nil }

    static func start(lockName: String, state: TrackingActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endAll()
        let attr = TrackingActivityAttributes(lockName: lockName)
        do {
            if #available(iOS 16.2, *) {
                _current = try Activity.request(attributes: attr, content: .init(state: state, staleDate: nil))
            } else {
                _current = try Activity.request(attributes: attr, contentState: state)
            }
        } catch {
            _current = nil
        }
    }

    /// Update the running activity, or start one if none is running.
    static func ensure(lockName: String, state: TrackingActivityAttributes.ContentState) {
        if current != nil { update(state) } else { start(lockName: lockName, state: state) }
    }

    static func update(_ state: TrackingActivityAttributes.ContentState) {
        guard let a = current else { return }
        Task {
            if #available(iOS 16.2, *) { await a.update(ActivityContent(state: state, staleDate: nil)) }
            else { await a.update(using: state) }
        }
    }

    static func end() { endAll() }

    private static func endAll() {
        let all = Activity<TrackingActivityAttributes>.activities
        _current = nil
        for a in all {
            Task {
                if #available(iOS 16.2, *) { await a.end(nil, dismissalPolicy: .immediate) }
                else { await a.end(dismissalPolicy: .immediate) }
            }
        }
    }
}
#endif
