import SwiftUI

struct LockListView: View {
    @EnvironmentObject var session: SessionStore
    private let api = APIClient()

    @State private var locks: [Lock] = []
    @State private var busy = false
    @State private var error: String?

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
                    List(locks) { lock in
                        NavigationLink(value: lock) {
                            LockRow(lock: lock)
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
                        Button("Uitloggen", role: .destructive) { session.signOut() }
                    } label: {
                        Image(systemName: "person.circle")
                    }
                }
            }
            .task { await load() }
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
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        busy = false
    }
}

struct LockRow: View {
    let lock: Lock
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: (lock.is_locked ?? true) ? "lock.fill" : "lock.open.fill")
                .foregroundStyle((lock.is_locked ?? true) ? .green : .orange)
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(lock.displayName).font(.headline)
                HStack(spacing: 6) {
                    if let serial = lock.serial_no { Text(serial) }
                    if lock.hasLocation {
                        Label("locatie bekend", systemImage: "mappin.circle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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
