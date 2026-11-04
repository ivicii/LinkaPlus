import SwiftUI

/// App-wide router for deep links / intents / widgets: "open" or "close" the lock now.
final class AppRouter: ObservableObject {
    /// An action is pending (kept under this name so existing observers still work).
    @Published var unlockRequested = false
    /// true = the pending action is LOCK, false = UNLOCK.
    var wantsLock = false
    /// true = do the opposite of the current lock state.
    var wantsToggle = false
    /// Bumped when a lock was removed/transferred → the list pops to root and reloads.
    @Published var lockRemoved = 0

    static let pendingKey = "pendingUnlock"
    static let pendingLockKey = "pendingLock"
    static let pendingToggleKey = "pendingToggle"

    func requestUnlock() { wantsToggle = false; wantsLock = false; unlockRequested = true }
    func requestLock()   { wantsToggle = false; wantsLock = true;  unlockRequested = true }
    func requestToggle() { wantsToggle = true; unlockRequested = true }

    /// Consume a flag set by an App Intent that launched the app.
    func consumePendingFlag() {
        let d = UserDefaults.standard
        if d.bool(forKey: Self.pendingKey) {
            d.set(false, forKey: Self.pendingKey); requestUnlock()
        } else if d.bool(forKey: Self.pendingLockKey) {
            d.set(false, forKey: Self.pendingLockKey); requestLock()
        } else if d.bool(forKey: Self.pendingToggleKey) {
            d.set(false, forKey: Self.pendingToggleKey); requestToggle()
        }
    }
}
