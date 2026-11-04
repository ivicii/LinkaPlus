import SwiftUI

/// "Change ownership", like the official app (NewOwnershipSettingFragment):
/// transfer to a new user, or remove the lock from this phone.
struct OwnershipView: View {
    let serial: String
    let lockName: String
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var router: AppRouter
    private let api = APIClient()

    @State private var email = ""
    @State private var email2 = ""
    @State private var busy = false
    @State private var message: String?
    @State private var confirmTransfer = false
    @State private var confirmRemove = false

    private var isAdmin: Bool { LockCache.loadKeys(serial: serial)?.commandKey?.admin ?? false }
    private var cleanEmail: String { email.trimmingCharacters(in: .whitespaces).lowercased() }
    private var emailValid: Bool {
        cleanEmail.contains("@") && cleanEmail.contains(".") && cleanEmail == email2.trimmingCharacters(in: .whitespaces).lowercased()
    }

    var body: some View {
        List {
            Section {
                TextField("E-mail nieuwe eigenaar", text: $email)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Herhaal e-mail", text: $email2)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button { confirmTransfer = true } label: {
                    Label("Eigendom overdragen", systemImage: "arrow.right.circle")
                }
                .disabled(!emailValid || busy || !isAdmin)
            } header: { Text("Overdragen aan nieuwe gebruiker") } footer: {
                Text(isAdmin
                     ? "De nieuwe eigenaar moet een LINKA-account hebben met dit e-mailadres. Na overdracht ben jij geen eigenaar meer en verdwijnt het slot uit je lijst."
                     : "Alleen de eigenaar (admin) kan het slot overdragen.")
            }

            Section {
                Button(role: .destructive) { confirmRemove = true } label: {
                    Label("Verwijder van deze telefoon", systemImage: "iphone.slash")
                }
                .disabled(busy)
            } footer: {
                Text(isAdmin
                     ? "Verbergt het slot in je account (zoals de officiële app) en wist de sleutel op deze telefoon. Je blijft eigenaar; het slot zelf wordt niet gereset."
                     : "Trekt je eigen (gedeelde) toegang tot dit slot in en wist de sleutel op deze telefoon.")
            }

            Section {
                Label("Verwijder uit account", systemImage: "trash.slash")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("In de officiële app herschrijft dit via Bluetooth de hoofdsleutels in het slot (eigendom resetten). Dat zit bewust niet in LinkaPlus: gaat het halverwege mis, dan kan niemand het slot meer bedienen. Gebruik ‘Overdragen’ als je het slot verkoopt.")
            }

            if busy { Section { HStack { ProgressView(); Text("Bezig…") } } }
            if let message { Section { Text(message).font(.callout).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("Eigendom wijzigen")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Eigendom overdragen?", isPresented: $confirmTransfer) {
            Button("Annuleer", role: .cancel) {}
            Button("Overdragen", role: .destructive) { transfer() }
        } message: {
            Text("\(lockName) gaat naar \(cleanEmail). Dit kun je niet zelf terugdraaien.")
        }
        .alert("Verwijderen van deze telefoon?", isPresented: $confirmRemove) {
            Button("Annuleer", role: .cancel) {}
            Button("Verwijderen", role: .destructive) { removeFromPhone() }
        } message: {
            Text(isAdmin ? "Het slot verdwijnt uit je lijst; je blijft eigenaar." : "Je verliest je toegang tot dit slot.")
        }
    }

    private func transfer() {
        busy = true; message = nil
        Task {
            do {
                try await api.transferOwnership(email: cleanEmail, serial: serial, auth: session.identity())
                finishRemoval()
            } catch {
                message = "Overdragen mislukt: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            }
            busy = false
        }
    }

    private func removeFromPhone() {
        busy = true; message = nil
        Task {
            do {
                if isAdmin {
                    try await api.hideLock(serial: serial, auth: session.identity())
                } else if let uid = session.identity().userId {
                    try await api.revokeAccess(userId: uid, serial: serial, auth: session.identity())
                }
                finishRemoval()
            } catch {
                message = "Verwijderen mislukt: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            }
            busy = false
        }
    }

    /// Forget the lock locally (keys, cache, Bluetooth) and go back to the list.
    private func finishRemoval() {
        BLEController.shared.stop()
        Keychain.delete("keys_\(serial)")
        LockCache.saveLocks(LockCache.loadLocks().filter { $0.serial_no != serial })
        for k in ["ble_lastSerial", "ble_lastName", "ble_lastPeripheral"] { UserDefaults.standard.removeObject(forKey: k) }
        router.lockRemoved += 1
    }
}
