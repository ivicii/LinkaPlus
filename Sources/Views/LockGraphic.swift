import SwiftUI
import UIKit

/// Flat 2D drawing of the LINKA ring lock: a horseshoe ring with a shackle that
/// slides across the bottom gap. Refined, flat look — a soft state-coloured halo,
/// a faint full-circle track, a subtle gradient on the ring and shackle, and a
/// small LED. No skeuomorphic 3D; just clean, modern shapes.
struct LockGraphic: View {
    /// true = locked (shackle closed), false = open (shackle retracted).
    let locked: Bool
    /// State colour (green locked, orange open, blue/grey unknown).
    let color: Color
    var size: CGFloat = 200
    /// Motor running → shackle/LED pulse (700 ms, like the official app).
    var moving: Bool = false
    /// Shackle travel time — the measured motor time, so it closes with the lock.
    var duration: Double = 1.0
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let ringBase = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 0.92, alpha: 1) : UIColor(white: 0.16, alpha: 1)
    })
    private static let ringTop = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 0.74, alpha: 1) : UIColor(white: 0.34, alpha: 1)
    })
    private static let trackColor = Color(UIColor { t in
        UIColor(white: t.userInterfaceStyle == .dark ? 1 : 0, alpha: 0.08)
    })

    private var ringGradient: LinearGradient {
        LinearGradient(colors: [Self.ringTop, Self.ringBase],
                       startPoint: .top, endPoint: .bottom)
    }
    private var shackleGradient: LinearGradient {
        LinearGradient(colors: [color.opacity(0.95), color.opacity(0.72)],
                       startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        let r = size * 0.37           // ring centre-line radius
        let t = size * 0.145          // ring thickness
        let g = 0.0972                // gap half-angle in turns (35°)
        let deg = 35.0 * .pi / 180
        let ex = r * sin(deg)
        let ey = r * cos(deg)
        let barH = t * 0.74
        let barW = locked ? ex * 2 + barH : barH

        ZStack {
            // Soft state halo — flat glow, not a 3D shadow.
            Circle()
                .fill(color)
                .frame(width: r * 2.0, height: r * 2.0)
                .blur(radius: size * 0.085)
                .opacity(pulse ? 0.34 : 0.20)

            // Faint full-circle track so the gap reads as intentional.
            Circle()
                .stroke(Self.trackColor, lineWidth: t)
                .frame(width: r * 2, height: r * 2)

            // Main horseshoe ring.
            Circle()
                .trim(from: g, to: 1 - g)
                .stroke(ringGradient, style: StrokeStyle(lineWidth: t, lineCap: .round))
                .rotationEffect(.degrees(90))
                .frame(width: r * 2, height: r * 2)

            // LED / power dot in the centre.
            Circle()
                .fill(color)
                .frame(width: t * 0.42, height: t * 0.42)
                .opacity(pulse ? 0.4 : 0.95)

            // Shackle across the bottom gap; slides open/closed.
            Capsule()
                .fill(shackleGradient)
                .frame(width: barW, height: barH)
                .opacity(pulse ? 0.5 : 1)
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
