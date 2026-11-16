import SwiftUI

struct LoginView: View {
    @EnvironmentObject var session: SessionStore
    private let api = APIClient()

    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?
    private enum Field { case email, code }

    private var cleanEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                LockGraphic(locked: true, color: Theme.locked, size: 110)
                    .accessibilityHidden(true)
                Text("LinkaPlus")
                    .font(.largeTitle.bold())
                Text(codeSent ? "We hebben een logincode gestuurd naar \(cleanEmail)."
                              : "Log in met je bestaande LINKA-account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 14) {
                    TextField("E-mailadres", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .email)
                        .submitLabel(.send)
                        .onSubmit { if canSubmit && !busy { primaryAction() } }
                        .disabled(codeSent)

                    if codeSent {
                        TextField("Logincode uit e-mail", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)   // iOS offers the code from Mail
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .code)
                    }
                }
                .padding(.horizontal)

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Button(action: primaryAction) {
                    HStack {
                        if busy { ProgressView().tint(.white) }
                        Text(codeSent ? "Inloggen" : "Stuur logincode")
                            .bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canSubmit ? Theme.accent : Color(.systemGray3))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
                }
                .disabled(!canSubmit || busy)
                .padding(.horizontal)

                if codeSent {
                    Button("Ander e-mailadres / opnieuw") {
                        codeSent = false; code = ""; error = nil; focus = .email
                    }
                    .font(.footnote)
                    .disabled(busy)
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: 480)             // keeps the form readable on iPad / landscape
            .frame(maxWidth: .infinity)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Gereed") { focus = nil }   // number pad has no return key
                }
            }
        }
    }

    private var canSubmit: Bool {
        if codeSent { return !cleanCode.isEmpty }
        let parts = cleanEmail.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".")
    }

    private func primaryAction() {
        error = nil
        busy = true
        Task {
            do {
                let auth = session.identity()
                if codeSent {
                    let data = try await api.login(email: cleanEmail, code: cleanCode, auth: auth)
                    session.signIn(with: data)
                } else {
                    try await api.sendLoginCode(email: cleanEmail, auth: auth)
                    codeSent = true
                    focus = .code
                }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            busy = false
        }
    }
}
