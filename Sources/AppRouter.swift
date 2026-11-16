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
    /// Bumped when a lock changed in place (e.g. renamed) → the list reloads, no pop.
    @Published var locksChanged = 0

    /// When the pending action was requested. A request that could not be carried
    /// out in time (lock out of range, Bluetooth off) must never fire later on its
    /// own — nobody expects the lock to open minutes after tapping a widget.
    private(set) var requestedAt: Date?
    static let requestLifetime: TimeInterval = 45

    static let pendingKey = "pendingUnlock"
    static let pendingLockKey = "pendingLock"
    static let pendingToggleKey = "pendingToggle"
    /// Epoch seconds at which an App Intent set one of the flags above.
    static let pendingAtKey = "pendingAt"

    func requestUnlock() { wantsToggle = false; wantsLock = false; requestedAt = Date(); unlockRequested = true }
    func requestLock()   { wantsToggle = false; wantsLock = true;  requestedAt = Date(); unlockRequested = true }
    func requestToggle() { wantsToggle = true; wantsLock = false;  requestedAt = Date(); unlockRequested = true }

    /// True while a request is pending and still recent. A stale request is dropped.
    func hasFreshRequest() -> Bool {
        guard unlockRequested else { return false }
        if let t = requestedAt, Date().timeIntervalSince(t) <= Self.requestLifetime { return true }
        cancelRequest()
        return false
    }

    func cancelRequest() {
        wantsToggle = false; wantsLock = false; requestedAt = nil
        if unlockRequested { unlockRequested = false }
    }

    /// Called by the App Intents: remember which action was asked for, and when.
    static func setPending(_ key: String) {
        let d = UserDefaults.standard
        for k in [pendingKey, pendingLockKey, pendingToggleKey] { d.set(k == key, forKey: k) }
        d.set(Date().timeIntervalSince1970, forKey: pendingAtKey)
    }

    /// Consume a flag set by an App Intent that launched the app.
    func consumePendingFlag() {
        let d = UserDefaults.standard
        let unlock = d.bool(forKey: Self.pendingKey)
        let lock = d.bool(forKey: Self.pendingLockKey)
        let toggle = d.bool(forKey: Self.pendingToggleKey)
        guard unlock || lock || toggle else { return }
        let age = Date().timeIntervalSince1970 - d.double(forKey: Self.pendingAtKey)
        for k in [Self.pendingKey, Self.pendingLockKey, Self.pendingToggleKey] { d.set(false, forKey: k) }
        // Ignore a flag that was left behind long ago (app never came to the foreground).
        guard age >= 0, age <= Self.requestLifetime else { return }
        if unlock { requestUnlock() } else if lock { requestLock() } else { requestToggle() }
    }
}
