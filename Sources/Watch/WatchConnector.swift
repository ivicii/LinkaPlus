import Foundation
import WatchConnectivity
import SwiftUI

/// Watch side of the bridge: sends lock/unlock/status to the phone and keeps the
/// latest state it reports back.
@MainActor
final class WatchConnector: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchConnector()

    @Published var ready = false
    @Published var locked: Bool?
    @Published var battery: Int?
    @Published var busy = false
    @Published var phoneReachable = false

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ cmd: String) {
        guard WCSession.default.activationState == .activated else { return }
        busy = cmd != "status"
        WCSession.default.sendMessage(["cmd": cmd], replyHandler: { [weak self] reply in
            Task { @MainActor in self?.apply(reply); self?.busy = false }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in self?.busy = false }
        })
    }

    private func apply(_ d: [String: Any]) {
        if let r = d["ready"] as? Bool { ready = r }
        if let l = d["locked"] as? Bool { locked = l } else if d["locked"] == nil { /* keep */ }
        if let b = d["battery"] as? Int { battery = b }
    }

    // MARK: WCSessionDelegate
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in apply(applicationContext) }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            phoneReachable = session.isReachable
            if activationState == .activated { send("status") }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in phoneReachable = session.isReachable }
    }
}
