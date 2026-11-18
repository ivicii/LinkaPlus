import SwiftUI

@main
struct LinkaWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { WatchContentView() }
    }
}

import WatchKit
final class WatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() { WatchConnector.shared.activate() }
}
