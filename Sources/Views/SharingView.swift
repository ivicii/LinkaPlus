import SwiftUI

/// Manage who has access to the lock: list permissions, invite, revoke.
struct SharingView: View {
    let serial: String
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) var dismiss
    private let api = APIClient()

    @State private var people: [LockPermission] = []
    @State private var loading = false
    @State private var inviteEmail = ""
    @State private var message: String?
    @State private var pendingRevoke: LockPermission?

    var body: some View {
        NavigationStack {
            List {
            Group {
                Section("Toegang") {
                    if loading && people.isEmpty {
                        HStack { ProgressView(); Text("Laden…").foregroundStyle(.secondary) }
                    } else if people.isEmpty {
                        Text("Niemand gevonden.").foregroundStyle(.secondary)
                    } else {
                        ForEach(people) { p in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.displayName).font(.body)
                                    HStack(spacing: 6) {
                                        if p.owner == true { Text("Eigenaar").foregroundStyle(Theme.accent) }
                                        if p.isPendingApproval == true { Text("In afwachting").foregroundStyle(Theme.warn) }
                                        if let e = p.email, e != p.displayName { Text(e) }
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if p.owner != true, p.userId != nil {
                                    Button(role: .destructive) { pendingRevoke = p } label: {
                                        Image(systemName: "person.badge.minus")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Toegang intrekken voor \(p.displayName)")
                                }
                            }
                        }
                    }
                }

                Section("Uitnodigen") {
                    TextField("E-mailadres", text: $inviteEmail)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        invite()
                    } label: { Label("Uitnodiging sturen", systemImage: "paperplane") }
                        .disabled(!inviteEmail.contains("@"))
                }

                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .listRowBackground(Theme.cardFill)
        }
            .linkaScreen().navigationTitle("Delen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Gereed") { dismiss() } } }
            .task { await load() }
            .confirmationDialog("Toegang intrekken?",
                                isPresented: Binding(get: { pendingRevoke != nil },
                                                     set: { if !$0 { pendingRevoke = nil } }),
                                titleVisibility: .visible) {
                Button("Intrekken", role: .destructive) {
                    if let uid = pendingRevoke?.userId { revoke(uid) }
                    pendingRevoke = nil
                }
                Button("Annuleer", role: .cancel) { pendingRevoke = nil }
            } message: {
                Text("\(pendingRevoke?.displayName ?? "Deze gebruiker") kan je slot daarna niet meer bedienen.")
            }
        }
    }

    private func load() async {
        loading = true
        do {
            people = try await api.lockPermissions(serial: serial, auth: session.identity())
        } catch {
            // Don't show "Niemand gevonden" when the list simply could not be loaded.
            message = "Laden mislukt: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        loading = false
    }

    private func invite() {
        let email = inviteEmail
        Task {
            do {
                try await api.sendInvite(email: email, serial: serial, auth: session.identity())
                message = "Uitnodiging gestuurd naar \(email)."
                inviteEmail = ""
                await load()
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? "Mislukt."
            }
        }
    }

    private func revoke(_ userId: String) {
        Task {
            do {
                try await api.revokeAccess(userId: userId, serial: serial, auth: session.identity())
                message = "Toegang ingetrokken."
                await load()
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? "Mislukt."
            }
        }
    }
}
