import SwiftUI

/// "Find My"-style proximity finder based on Bluetooth signal strength.
/// No UWB on the lock, so there's no direction arrow — but the ring grows and
/// turns green as you get closer, with an estimated distance.
struct FindLockView: View {
    @ObservedObject var ble: BLEController
    let onSiren: () -> Void
    @Environment(\.dismiss) var dismiss

    /// 0 (far) … 1 (very near), from RSSI roughly -90…-40 dBm.
    private var proximity: Double {
        guard let r = ble.rssi else { return 0 }
        return min(1, max(0, (Double(r) + 90) / 50))
    }

    private var tint: Color {
        proximity > 0.7 ? .green : (proximity > 0.4 ? .yellow : .orange)
    }

    private var distanceText: String {
        guard let m = ble.estimatedMeters else { return "—" }
        if m < 1 { return "< 1 m" }
        if m < 10 { return String(format: "~%.1f m", m) }
        return String(format: "~%.0f m", m)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                tint.opacity(0.12).ignoresSafeArea()
                VStack(spacing: 28) {
                    Spacer()
                    ZStack {
                        Circle().stroke(tint.opacity(0.25), lineWidth: 2)
                            .frame(width: 280, height: 280)
                        Circle().fill(tint.opacity(0.18))
                            .frame(width: 60 + CGFloat(proximity) * 220,
                                   height: 60 + CGFloat(proximity) * 220)
                            .animation(.easeInOut(duration: 0.4), value: proximity)
                        VStack(spacing: 6) {
                            Image(systemName: "bicycle")
                                .font(.system(size: 44)).foregroundStyle(tint)
                            Text(distanceText).font(.system(size: 34, weight: .bold))
                        }
                    }
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

                    Button(action: onSiren) {
                        Label("Laat sirene afspelen", systemImage: "speaker.wave.3.fill")
                            .frame(maxWidth: .infinity).padding()
                            .background(tint.opacity(0.2)).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 24)
                    Spacer()
                    Text("Richting is niet mogelijk via Bluetooth (geen UWB) — dit is een signaalsterkte-schatting.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center).padding(.horizontal, 32).padding(.bottom, 8)
                }
            }
            .navigationTitle("Zoek je slot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Sluit") { dismiss() } } }
        }
    }
}
