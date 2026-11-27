import AppIntents

/// Shortcuts / Action-button / Siri action to unlock the lock.
/// Opens the app (reliable Bluetooth path) and hands the request straight to the
/// router; the lock screen carries it out as soon as Bluetooth is ready.
@available(iOS 16.0, *)
struct UnlockLockIntent: AppIntent {
    static var title: LocalizedStringResource = "Ontgrendel slot"
    static var description = IntentDescription("Ontgrendelt je LINKA-slot via Bluetooth.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.requestUnlock()
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
        AppRouter.shared.requestLock()
        return .result()
    }
}

/// Action button: unlock when locked, lock when unlocked.
@available(iOS 16.0, *)
struct ToggleLockIntent: AppIntent {
    static var title: LocalizedStringResource = "Ontgrendel/vergrendel slot"
    static var description = IntentDescription("Opent je LINKA-slot als het dicht is en sluit het als het open is.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.requestToggle()
        return .result()
    }
}

@available(iOS 16.0, *)
struct LinkaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleLockIntent(),
            phrases: [
                "Wissel mijn slot met \(.applicationName)",
                "Ontgrendel of vergrendel mijn slot met \(.applicationName)"
            ],
            shortTitle: "Ontgrendel/vergrendel",
            systemImageName: "lock.rotation"
        )
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
