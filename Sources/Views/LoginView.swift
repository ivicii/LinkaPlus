import SwiftUI

struct LoginView: View {
    @EnvironmentObject var session: SessionStore
    private let api = APIClient()

    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "lock.shield")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("LinkaPlus")
                    .font(.largeTitle.bold())
                Text("Log in met je bestaande LINKA-account.")
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
                        .disabled(codeSent)

                    if codeSent {
                        TextField("Logincode uit e-mail", text: $code)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.horizontal)

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
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
                    .background(canSubmit ? Color.accentColor : Color.gray)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!canSubmit || busy)
                .padding(.horizontal)

                if codeSent {
                    Button("Ander e-mailadres / opnieuw") {
                        codeSent = false; code = ""; error = nil
                    }
                    .font(.footnote)
                }
                Spacer()
            }
            .padding()
        }
    }

    private var canSubmit: Bool {
        if codeSent { return !code.isEmpty }
        return email.contains("@")
    }

    private func primaryAction() {
        error = nil
        busy = true
        Task {
            do {
                let auth = session.identity()
                if codeSent {
                    let data = try await api.login(email: email, code: code, auth: auth)
                    session.signIn(with: data)
                } else {
                    try await api.sendLoginCode(email: email, auth: auth)
                    codeSent = true
                }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            busy = false
        }
    }
}
