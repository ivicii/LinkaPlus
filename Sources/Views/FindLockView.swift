import SwiftUI

/// "Find My"-style proximity finder based on Bluetooth signal strength.
/// No UWB on the lock, so there's no direction arrow — but the ring grows and
/// turns green as you get closer, with an estimated distance.
struct FindLockView: View {
    @ObservedObject var ble: BLEController
    let onSiren: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var tune = LockPrefs.finderTune
    @State private var showBeepNeedsBT = false

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

                        VStack(spacing: 10) {
                            // The melody is a Bluetooth-only command. Always tappable:
                            // when not connected it explains why and offers the siren.
                            Button {
                                Haptic.tap()
                                if ble.ready { ble.playTune(tune) } else { showBeepNeedsBT = true }
                            } label: {
                                Label("Laat slot piepen", systemImage: "music.note")
                                    .frame(maxWidth: .infinity).padding()
                                    .background(tint.opacity(ble.ready ? 0.2 : 0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
                            }

                            // The lock has four melodies — tap to try, the choice is remembered.
                            HStack(spacing: 8) {
                                Text("Melodie").font(.caption).foregroundStyle(.secondary)
                                ForEach(0..<4) { n in
                                    Button {
                                        tune = n; LockPrefs.finderTune = n
                                        if ble.ready { ble.playTune(n) }
                                    } label: {
                                        Text("\(n + 1)")
                                            .font(.subheadline.weight(.semibold))
                                            .frame(width: 34, height: 34)
                                            .background((tune == n ? tint : Color.secondary).opacity(tune == n ? 0.3 : 0.12))
                                            .clipShape(Circle())
                                    }
                                }
                            }
                            if !ble.ready {
                                Text("De melodie werkt alleen via Bluetooth.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }

                            if sirenActive {
                                Button { ble.sirenOff() } label: {
                                    Label("Sirene stoppen", systemImage: "speaker.slash.fill")
                                        .font(.footnote).foregroundStyle(Theme.danger)
                                }
                            } else {
                                Button { Haptic.tap(); onSiren() } label: {
                                    Label(ble.ready ? "Toch de sirene" : "Sirene (via internet)", systemImage: "speaker.wave.3.fill")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .alert("Melodie werkt via Bluetooth", isPresented: $showBeepNeedsBT) {
                            Button("Sirene via internet") { onSiren() }
                            Button("Oké", role: .cancel) {}
                        } message: {
                            Text("Het zachte piepje is een Bluetooth-commando. Zet Bluetooth aan als je dichtbij bent. Op afstand kan LINKA alleen de volledige sirene afspelen, en dan alleen als je slot net wakker is.")
                        }
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
