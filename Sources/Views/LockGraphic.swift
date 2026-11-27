import SwiftUI
import UIKit

/// Flat 2D drawing of the LINKA ring lock: a calm neutral horseshoe ring with a
/// state-coloured shackle that slides across the bottom gap, a small centre dot,
/// and a soft colour bloom behind the shackle (no 3D, no hard halo). The ring
/// reads well in both light and dark — it stays charcoal, like the real lock body
/// — and the colour carries the state.
struct LockGraphic: View {
    /// true = locked (shackle closed), false = open (shackle retracted).
    let locked: Bool
    /// State colour (green locked, orange open, blue/grey unknown).
    let color: Color
    var size: CGFloat = 200
    /// Motor running → shackle/dot pulse (700 ms, like the official app).
    var moving: Bool = false
    /// Shackle travel time — the measured motor time, so it closes with the lock.
    var duration: Double = 1.0
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Calm neutral ring — dark charcoal on light, soft graphite on dark. Never a
    // stark white, so it reads like the real black lock body in both themes.
    private static let ringBase = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(red: 0.290, green: 0.330, blue: 0.430, alpha: 1)
                                      : UIColor(red: 0.149, green: 0.149, blue: 0.169, alpha: 1)
    })
    private static let ringTop = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(red: 0.400, green: 0.450, blue: 0.570, alpha: 1)
                                      : UIColor(red: 0.182, green: 0.182, blue: 0.206, alpha: 1)
    })

    private var ringGradient: LinearGradient {
        LinearGradient(colors: [Self.ringTop, Self.ringBase],
                       startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        let r = size * 0.37           // ring centre-line radius
        let t = size * 0.145          // ring thickness
        let g = 0.0972                // gap half-angle in turns (35°)
        let deg = 35.0 * .pi / 180
        let ex = r * sin(deg)
        let ey = r * cos(deg)
        let barH = t * 0.82
        let barW = locked ? ex * 2 + barH : barH

        ZStack {
            // Soft colour bloom behind the shackle — a flat, tight glow, not a 3D halo.
            Ellipse()
                .fill(color)
                .frame(width: barW * 1.05, height: barH * 1.7)
                .blur(radius: size * 0.055)
                .opacity(pulse ? 0.45 : 0.30)
                .offset(x: locked ? 0 : ex, y: ey)
                .animation(reduceMotion ? nil : .easeInOut(duration: duration), value: locked)

            // Main neutral horseshoe ring.
            Circle()
                .trim(from: g, to: 1 - g)
                .stroke(ringGradient, style: StrokeStyle(lineWidth: t, lineCap: .round))
                .rotationEffect(.degrees(90))
                .frame(width: r * 2, height: r * 2)

            // Centre state dot.
            Circle()
                .fill(color)
                .frame(width: t * 0.48, height: t * 0.48)
                .opacity(pulse ? 0.45 : 1)

            // Shackle across the bottom gap; slides open/closed with the motor.
            Capsule()
                .fill(color)
                .frame(width: barW, height: barH)
                .offset(x: locked ? 0 : ex, y: ey)
                .animation(reduceMotion ? nil : .easeInOut(duration: duration), value: locked)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.35), value: color)
        .onChange(of: moving) { m in
            if m && !reduceMotion {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { pulse = false }
            }
        }
    }
}
