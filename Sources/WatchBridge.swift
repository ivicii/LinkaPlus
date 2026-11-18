import Foundation
import WatchConnectivity

/// Bridges the Apple Watch to the phone's BLE controller. The watch has no keys
/// and no BLE link of its own, so it asks the phone (which does the real work)
/// over WatchConnectivity and gets the lock state + battery back.
@MainActor
final class WatchBridge: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchBridge()
    private var ble: BLEController { .shared }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Current state as a small dictionary the watch understands.
    func snapshot() -> [String: Any] {
        var d: [String: Any] = ["ready": ble.ready]
        if let l = ble.liveLocked { d["locked"] = l }
        if let b = ble.batteryLevelBLE { d["battery"] = b }
        return d
    }

    /// Push the latest state to the watch (best-effort).
    func pushState() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(snapshot())
    }

    private func handle(_ message: [String: Any], reply: (([String: Any]) -> Void)?) {
        let cmd = message["cmd"] as? String
        switch cmd {
        case "unlock": ble.channel = 0; ble.counterOffset = 0; ble.unlock()
        case "lock":   ble.channel = 0; ble.counterOffset = 0; ble.lock()
        case "status": break
        default: break
        }
        // Give the command a brief moment, then reply with the latest state.
        if let reply {
            Task {
                try? await Task.sleep(nanoseconds: cmd == "status" ? 0 : 1_200_000_000)
                reply(snapshot())
            }
        }
    }

    // MARK: WCSessionDelegate
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in handle(message, reply: replyHandler) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in handle(message, reply: nil) }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
