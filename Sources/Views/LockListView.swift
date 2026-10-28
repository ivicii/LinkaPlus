import SwiftUI

struct LockListView: View {
    @EnvironmentObject var session: SessionStore
    private let api = APIClient()

    @State private var locks: [Lock] = []
    @State private var busy = false
    @State private var error: String?
    @State private var showDiagnostics = false
    @State private var offline = false

    var body: some View {
        NavigationStack {
            Group {
                if busy && locks.isEmpty {
                    ProgressView("Sloten laden…")
                } else if let error, locks.isEmpty {
                    errorState(error)
                } else if locks.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "Geen sloten",
                        systemImage: "lock.slash",
                        description: "Er zijn geen sloten gekoppeld aan dit account."
                    )
                } else {
                    List {
                        if offline {
                            Section {
                                Label("Offline — opgeslagen gegevens. Bluetooth-bediening werkt.",
                                      systemImage: "wifi.slash")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        ForEach(locks) { lock in
                            NavigationLink(value: lock) {
                                LockRow(lock: lock)
                            }
                        }
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Mijn sloten")
            .navigationDestination(for: Lock.self) { lock in
                LockDetailView(lock: lock)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        if let name = session.displayName { Text(name) }
                        if let email = session.email { Text(email) }
                        Divider()
                        Button("Diagnose (API)") { showDiagnostics = true }
                        Button("Uitloggen", role: .destructive) { session.signOut() }
                    } label: {
                        Image(systemName: "person.circle")
                    }
                }
            }
            .task { await load() }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView().environmentObject(session)
            }
        }
    }

    @ViewBuilder
    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Opnieuw proberen") { Task { await load() } }
        }
        .padding()
    }

    private func load() async {
        busy = true; error = nil
        do {
            locks = try await api.getLocks(auth: session.identity())
            LockCache.saveLocks(locks)
            offline = false
        } catch {
            let cached = LockCache.loadLocks()
            if !cached.isEmpty {
                locks = cached
                offline = true
            } else {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
        busy = false
    }
}

struct LockRow: View {
    let lock: Lock
    private var isLocked: Bool { lock.is_locked ?? true }
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.grad(isLocked ? Theme.locked : Theme.open))
                    .frame(width: 48, height: 48)
                    .shadow(color: (isLocked ? Theme.locked : Theme.open).opacity(0.35), radius: 6, y: 3)
                Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                    .foregroundStyle(.white)
                    .font(.title3.weight(.bold))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(lock.displayName).font(.headline)
                HStack(spacing: 6) {
                    if let serial = lock.serial_no { Text(serial) }
                    if lock.hasLocation {
                        Label("locatie", systemImage: "mappin.circle.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }
}

/// Backwards-compatible stand-in for ContentUnavailableView (iOS 17+).
struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let description: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(description).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
