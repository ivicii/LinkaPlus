import SwiftUI

@main
struct LinkaPlusApp: App {
    @StateObject private var session = SessionStore()
    @StateObject private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(router)
                .onOpenURL { url in
                    if url.scheme == "linkaplus" && url.host == "unlock" {
                        router.requestUnlock()
                    }
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
