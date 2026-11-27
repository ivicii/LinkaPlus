import SwiftUI

struct LockListView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var router: AppRouter
    private let api = APIClient()

    @State private var locks: [Lock] = []
    @State private var busy = false
    @State private var error: String?
    @State private var showDiagnostics = false
    @State private var showAddLock = false
    @State private var offline = false
    @State private var path: [Lock] = []
    @State private var confirmSignOut = false
    @State private var sessionExpired = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if busy && locks.isEmpty {
                    ProgressView("Sloten laden…")
                } else if let error, locks.isEmpty {
                    errorState(error)
                } else if locks.isEmpty {
                    VStack(spacing: 12) {
                        ContentUnavailableViewCompat(
                            title: "Geen sloten",
                            systemImage: "lock.slash",
                            description: "Er zijn geen sloten gekoppeld aan dit account."
                        )
                        Button("Slot toevoegen") { showAddLock = true }
                            .buttonStyle(.borderedProminent)
                        Button("Vernieuwen") { Task { await load() } }
                    }
                } else {
                    List {
                        if sessionExpired {
                            Section {
                                Label("Je sessie lijkt verlopen — dit zijn opgeslagen gegevens. Bluetooth-bediening werkt nog.",
                                      systemImage: "person.crop.circle.badge.exclamationmark")
                                    .font(.caption)
                                    .foregroundStyle(Theme.warn)
                                Button("Opnieuw inloggen") { confirmSignOut = true }
                            }
                        } else if offline {
                            Section {
                                Label("Offline — opgeslagen gegevens. Bluetooth-bediening werkt.",
                                      systemImage: "wifi.slash")
                                    .font(.caption)
                                    .foregroundStyle(Theme.warn)
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showAddLock = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Slot toevoegen")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        if let name = session.displayName { Text(name) }
                        if let email = session.email { Text(email) }
                        Divider()
                        Button { showDiagnostics = true } label: {
                            Label("Diagnose (API)", systemImage: "stethoscope")
                        }
                        Button(role: .destructive) { confirmSignOut = true } label: {
                            Label("Uitloggen", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Image(systemName: "person.circle")
                    }
                    .accessibilityLabel("Account")
                }
            }
            .task { await load() }
            .onChange(of: router.requestSeq) { _ in
                // Only from the list itself: don't yank the user away from a lock
                // (or its settings) they are looking at — that screen handles it.
                if router.unlockRequested, path.isEmpty, let first = locks.first { path = [first] }
            }
            .onChange(of: router.lockRemoved) { _ in
                path = []
                Task { await load() }
            }
            .onChange(of: router.locksChanged) { _ in
                Task { await load() }
            }
            .confirmationDialog("Uitloggen?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Uitloggen", role: .destructive) {
                    // Also drop the Bluetooth link: without an account nobody should
                    // keep (auto-)controlling the lock from this app.
                    BLEController.shared.stop()
                    router.cancelRequest()
                    path = []
                    session.signOut()
                }
                Button("Annuleer", role: .cancel) {}
            } message: {
                Text("Je slot blijft gekoppeld aan je account. Log opnieuw in om het weer te bedienen.")
            }
            .onChange(of: locks) { newLocks in
                if router.hasFreshRequest(), let first = newLocks.first, path.isEmpty { path = [first] }
            }
            .sheet(isPresented: $showAddLock) {
                AddLockView(onDone: { Task { await load() } }).environmentObject(session)
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView().environmentObject(session)
            }
        }
    }

    @ViewBuilder
    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Sloten laden mislukt").font(.headline)
            Text(message).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Opnieuw proberen") { Task { await load() } }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            if sessionExpired {
                Button("Opnieuw inloggen") { confirmSignOut = true }
            }
        }
        .padding(32)
    }

    private func load() async {
        busy = true; error = nil
        do {
            locks = try await api.getLocks(auth: session.identity())
            LockCache.saveLocks(locks)
            offline = false; sessionExpired = false
        } catch {
            // Token no longer accepted → say so, instead of a vague "offline".
            if let apiError = error as? APIError, case .http(let code, _) = apiError,
               code == 401 || code == 403 { sessionExpired = true }
            let cached = LockCache.loadLocks()
            if !cached.isEmpty {
                locks = cached
                offline = true
            } else {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        busy = false
    }
}

struct LockRow: View {
    let lock: Lock
    @ObservedObject private var ble = BLEController.shared

    /// This row's lock is the one the Bluetooth controller is driving.
    private var isLive: Bool {
        guard let serial = lock.serial_no, let current = ble.currentSerial else { return false }
        return serial.caseInsensitiveCompare(current) == .orderedSame
    }

    /// Live Bluetooth state when available, else what the cloud last knew.
    /// nil = unknown — shown as such instead of pretending the lock is closed.
    private var isLocked: Bool? {
        if isLive, let live = ble.liveLocked { return live }
        return lock.is_locked
    }

    private var tint: Color {
        guard let locked = isLocked else { return Theme.accent }
        return locked ? Theme.locked : Theme.open
    }
    private var icon: String {
        guard let locked = isLocked else { return "questionmark" }
        return locked ? "lock.fill" : "lock.open.fill"
    }
    private var statusText: String {
        guard let locked = isLocked else { return "Status onbekend" }
        return locked ? "Vergrendeld" : "Ontgrendeld"
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                    .fill(Theme.grad(tint))
                    .frame(width: 48, height: 48)
                    .shadow(color: tint.opacity(0.35), radius: 6, y: 3)
                Image(systemName: icon)
                    .foregroundStyle(.white)
                    .font(.title3.weight(.bold))
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(lock.displayName).font(.headline)
                HStack(spacing: 6) {
                    Text(statusText).foregroundStyle(tint)
                    if isLive && ble.ready {
                        Label("verbonden", systemImage: "dot.radiowaves.left.and.right")
                    } else if lock.hasLocation {
                        Label("locatie", systemImage: "mappin.circle.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            // No hand-drawn chevron: NavigationLink already adds one in a List.
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
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
