import SwiftUI
import UIKit
import StripePaymentSheet
import StripePayments

/// Renews the lock's cellular data plan: loads pricing + a Stripe SetupIntent,
/// presents Stripe's PaymentSheet to add a card, then enables the data plan.
struct RenewDataPlanView: View {
    let serial: String
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) var dismiss
    private let api = APIClient()

    @State private var priceDesc: String?
    @State private var paymentSheet: PaymentSheet?
    @State private var loading = true
    @State private var working = false
    @State private var message: String?
    @State private var done = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if loading {
                        HStack { ProgressView(); Text("Betaalgegevens laden…") }
                    } else {
                        if let priceDesc {
                            HStack { Text("Prijs"); Spacer(); Text(priceDesc).foregroundStyle(.secondary) }
                        }
                        Button {
                            pay()
                        } label: {
                            HStack {
                                if working { ProgressView() }
                                Label(done ? "Geactiveerd ✓" : "Kaart toevoegen & activeren",
                                      systemImage: "creditcard")
                            }
                        }
                        .disabled(working || paymentSheet == nil || done)
                    }
                    if let message {
                        Text(message).font(.footnote)
                            .foregroundStyle(done ? .green : .secondary)
                    }
                } header: {
                    Text("Dataplan verlengen")
                } footer: {
                    Text("Betaling verloopt veilig via Stripe. Na succesvolle betaling wordt het dataplan geactiveerd en werken live tracking en remote sirene weer.")
                }
            }
            .navigationTitle("Verlengen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(done ? "Klaar" : "Annuleer") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true; message = nil
        do {
            let auth = session.identity()
            // Ensure a Stripe customer exists first (idempotent; ignore if present).
            try? await api.addCustomer(auth: auth)
            let pi = try await api.getPaymentInfo(auth: auth)
            let si = try await api.createSetupIntent(auth: auth)
            priceDesc = pi.annual_cost_desc
            if let key = pi.stripe_publishable_key { STPAPIClient.shared.publishableKey = key }

            if let secret = si.clientSecret, let customer = si.customer_id, let ek = si.ephemeralKey {
                var config = PaymentSheet.Configuration()
                config.merchantDisplayName = "LINKA"
                config.customer = .init(id: customer, ephemeralKeySecret: ek)
                paymentSheet = PaymentSheet(setupIntentClientSecret: secret, configuration: config)
            } else {
                message = "Kon betaalsessie niet opzetten."
            }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "Laden mislukt: \(error)"
        }
        loading = false
    }

    private func pay() {
        guard let sheet = paymentSheet, let vc = Self.topViewController() else { return }
        working = true; message = nil
        sheet.present(from: vc) { result in
            switch result {
            case .completed:
                Task {
                    do {
                        let auth = session.identity()
                        try await api.addCard(auth: auth)   // sync saved card to backend
                        try await api.enableDataPlan(serial: serial, enabled: true, auth: auth)
                        message = "Betaald en dataplan geactiveerd. Ververs zo meteen de dataplan-status."
                        done = true
                    } catch {
                        message = "Kaart opgeslagen, maar activeren mislukte: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
                    }
                    working = false
                }
            case .canceled:
                message = "Geannuleerd."
                working = false
            case .failed(let err):
                message = "Betaling mislukt: \(err.localizedDescription)"
                working = false
            }
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var vc = window?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}
