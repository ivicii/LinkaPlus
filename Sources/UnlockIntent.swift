import AppIntents

/// Shortcuts / Action-button / Siri action to unlock the lock.
/// Opens the app (reliable Bluetooth path) and the app auto-unlocks.
@available(iOS 16.0, *)
struct UnlockLockIntent: AppIntent {
    static var title: LocalizedStringResource = "Ontgrendel slot"
    static var description = IntentDescription("Ontgrendelt je LINKA-slot via Bluetooth.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: AppRouter.pendingKey)
        return .result()
    }
}

/// Shortcuts / Action-button / Siri action to lock the lock.
@available(iOS 16.0, *)
struct LockLockIntent: AppIntent {
    static var title: LocalizedStringResource = "Vergrendel slot"
    static var description = IntentDescription("Vergrendelt je LINKA-slot via Bluetooth.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: AppRouter.pendingLockKey)
        return .result()
    }
}

@available(iOS 16.0, *)
struct LinkaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: UnlockLockIntent(),
            phrases: [
                "Ontgrendel mijn slot met \(.applicationName)",
                "Open mijn slot met \(.applicationName)"
            ],
            shortTitle: "Ontgrendel slot",
            systemImageName: "lock.open.fill"
        )
        AppShortcut(
            intent: LockLockIntent(),
            phrases: [
                "Vergrendel mijn slot met \(.applicationName)",
                "Sluit mijn slot met \(.applicationName)"
            ],
            shortTitle: "Vergrendel slot",
            systemImageName: "lock.fill"
        )
    }
}
