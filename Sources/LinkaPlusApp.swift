import SwiftUI

@main
struct LinkaPlusApp: App {
    @StateObject private var session = SessionStore()
    @StateObject private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.accent)
                .environmentObject(session)
                .environmentObject(router)
                .onOpenURL { url in
                    guard url.scheme == "linkaplus" else { return }
                    if url.host == "unlock" { router.requestUnlock() }
                    if url.host == "lock" { router.requestLock() }
                    if url.host == "toggle" { router.requestToggle() }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { router.consumePendingFlag() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var session: SessionStore

    var body: some View {
        if session.isAuthenticated {
            LockListView()
        } else {
            LoginView()
        }
    }
}
