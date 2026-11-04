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
    @State private var confirmAccount = false
    @State private var step: String?
    @ObservedObject private var ble = BLEController.shared

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
                Button(role: .destructive) { confirmAccount = true } label: {
                    Label("Verwijder uit account", systemImage: "trash")
                }
                .disabled(busy || !isAdmin || !ble.ready)
            } footer: {
                Text(!isAdmin ? "Alleen de eigenaar kan het slot uit het account verwijderen."
                     : !ble.ready ? "Ga bij je slot staan: dit werkt alleen met een Bluetooth-verbinding."
                     : "Zoals de officiële app: het slot krijgt zijn standaardinstellingen terug (ook quick-lock, slaaptijd en PAC), de server ontkoppelt het van je account, daarna herstart het slot. De sleutels ín het slot veranderen niet; LinkaPlus bewaart je sleutel als back-up.")
            }

            if busy { Section { HStack { ProgressView(); Text(step ?? "Bezig…") } } }
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
        .alert("Uit account verwijderen?", isPresented: $confirmAccount) {
            Button("Annuleer", role: .cancel) {}
            Button("Verwijderen", role: .destructive) { removeFromAccount() }
        } message: {
            Text("Het slot gaat terug naar standaardinstellingen en wordt van je LINKA-account ontkoppeld. Blijf bij het slot tot het klaar is.")
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

    private func removeFromAccount() {
        busy = true; message = nil
        Task {
            // Step 1–2: lock side (no key changes). Abort before touching the server on failure.
            if let err = await ble.factoryResetForRemoval(progress: { step = $0 }) {
                message = "Gestopt: \(err) Er is niets op de server gewijzigd; je kunt het opnieuw proberen."
                busy = false; step = nil; return
            }
            step = "Ontkoppelen van account…"
            do {
                try await api.resetAllLockInformation(serial: serial, auth: session.identity())
            } catch {
                message = "Slot is gereset, maar de server gaf een fout: \((error as? LocalizedError)?.errorDescription ?? "\(error)"). Je sleutel werkt nog; probeer het opnieuw."
                busy = false; step = nil; return
            }
            step = "Slot herstarten…"
            ble.reboot()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            ble.sleepLock()
            busy = false; step = nil
            finishRemoval()
        }
    }

    /// Forget the lock locally (keys, cache, Bluetooth) and go back to the list.
    private func finishRemoval() {
        BLEController.shared.stop()
        if let k = Keychain.get("keys_\(serial)") { Keychain.set(k, for: "keys_backup_\(serial)") }
        Keychain.delete("keys_\(serial)")
        LockCache.saveLocks(LockCache.loadLocks().filter { $0.serial_no != serial })
        for k in ["ble_lastSerial", "ble_lastName", "ble_lastPeripheral"] { UserDefaults.standard.removeObject(forKey: k) }
        router.lockRemoved += 1
    }
}
