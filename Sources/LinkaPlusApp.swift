import SwiftUI

@main
struct LinkaPlusApp: App {
    @StateObject private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
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
