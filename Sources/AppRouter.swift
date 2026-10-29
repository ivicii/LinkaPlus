import SwiftUI

/// App-wide router for deep links / intents, e.g. "unlock the lock now".
final class AppRouter: ObservableObject {
    @Published var unlockRequested = false

    static let pendingKey = "pendingUnlock"

    func requestUnlock() { unlockRequested = true }

    /// Consume a flag set by an App Intent that launched the app.
    func consumePendingFlag() {
        if UserDefaults.standard.bool(forKey: Self.pendingKey) {
            UserDefaults.standard.set(false, forKey: Self.pendingKey)
            unlockRequested = true
        }
    }
}
