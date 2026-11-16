import SwiftUI

/// "Find My"-style proximity finder based on Bluetooth signal strength.
/// No UWB on the lock, so there's no direction arrow — but the ring grows and
/// turns green as you get closer, with an estimated distance.
struct FindLockView: View {
    @ObservedObject var ble: BLEController
    let onSiren: () -> Void
    @Environment(\.dismiss) var dismiss

    private static let nl = Locale(identifier: "nl_NL")

    /// 0 (far) … 1 (very near), from RSSI roughly -90…-40 dBm.
    private var proximity: Double {
        guard let r = ble.rssi else { return 0 }
        return min(1, max(0, (Double(r) + 90) / 50))
    }

    /// Theme colours (readable in light and dark): green near, orange mid, red far.
    private var tint: Color {
        proximity > 0.7 ? Theme.locked : (proximity > 0.4 ? Theme.warn : Theme.danger)
    }

    private var sirenActive: Bool { ble.statusFlags.contains("Sirene actief") }

    private var distanceText: String {
        guard let m = ble.estimatedMeters else { return "—" }
        if m < 1 { return "< 1 m" }
        if m < 10 { return String(format: "~%.1f m", locale: Self.nl, m) }
        return String(format: "~%.0f m", locale: Self.nl, m)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                // The ring shrinks on short screens (landscape, iPhone SE); the
                // rest scrolls if it still does not fit.
                let ring = max(140, min(280, min(geo.size.width - 40, geo.size.height - 330)))
                ScrollView {
                    VStack(spacing: 28) {
                        Spacer(minLength: 0)
                        ZStack {
                            Circle().stroke(tint.opacity(0.25), lineWidth: 2)
                                .frame(width: ring, height: ring)
                            Circle().fill(tint.opacity(0.18))
                                .frame(width: ring * (0.21 + 0.79 * CGFloat(proximity)),
                                       height: ring * (0.21 + 0.79 * CGFloat(proximity)))
                                .animation(.easeInOut(duration: 0.4), value: proximity)
                            VStack(spacing: 6) {
                                Image(systemName: "bicycle")
                                    .font(.system(size: 44)).foregroundStyle(tint)
                                    .accessibilityHidden(true)
                                Text(distanceText).font(.system(size: 34, weight: .bold))
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Geschatte afstand tot het slot")
                        .accessibilityValue(distanceText)

                        VStack(spacing: 4) {
                            Text(ble.ready ? "Loop rond — de cirkel wordt groener en groter naarmate je dichterbij komt."
                                           : "Verbinden met je slot…")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            if let r = ble.rssi {
                                Text("Signaal: \(r) dBm").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 32)

                        Button {
                            Haptic.tap()
                            if sirenActive { ble.sirenOff() } else { onSiren() }
                        } label: {
                            Label(sirenActive ? "Sirene stoppen" : "Sirene laten afgaan",
                                  systemImage: sirenActive ? "speaker.slash.fill" : "speaker.wave.3.fill")
                                .frame(maxWidth: .infinity).padding()
                                .background((sirenActive ? Theme.danger : tint).opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
                        }
                        .padding(.horizontal, 24)
                        Spacer(minLength: 0)
                        Text("Richting is niet mogelijk via Bluetooth (geen UWB) — dit is een signaalsterkte-schatting.")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center).padding(.horizontal, 32).padding(.bottom, 8)
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
            .background(tint.opacity(0.12).ignoresSafeArea())
            .navigationTitle("Zoek je slot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Gereed") { dismiss() } } }
        }
    }
}
