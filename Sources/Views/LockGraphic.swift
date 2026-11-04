import SwiftUI
import UIKit

/// Flat 2D drawing of the LINKA ring lock — same shape as the app icon: a
/// neutral horseshoe ring with a bolt bar across the bottom gap. The bar (and
/// the centre dot) carry the state colour; the bar slides closed/open.
struct LockGraphic: View {
    /// true = locked (bar closed), false = open (bar retracted).
    let locked: Bool
    /// State colour (green locked, orange open, blue unknown).
    let color: Color
    var size: CGFloat = 200
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let ringColor = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 0.90, alpha: 1) : UIColor(white: 0.17, alpha: 1)
    })

    var body: some View {
        let r = size * 0.38           // ring centre-line radius
        let t = size * 0.15           // ring thickness
        let g = 0.0944                // gap half-angle in turns (34°)
        let ex = r * sin(34 * .pi / 180)
        let ey = r * cos(34 * .pi / 180)
        let barH = t * 0.78
        let barW = locked ? ex * 2 + barH : barH

        ZStack {
            Circle()
                .trim(from: g, to: 1 - g)
                .stroke(Self.ringColor, style: StrokeStyle(lineWidth: t, lineCap: .round))
                .rotationEffect(.degrees(90))
                .frame(width: r * 2, height: r * 2)

            Circle()
                .fill(color)
                .frame(width: t * 0.46, height: t * 0.46)

            Capsule()
                .fill(color)
                .frame(width: barW, height: barH)
                .offset(x: locked ? 0 : ex, y: ey)
        }
        .offset(y: -size * 0.03)
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: locked)
        .animation(.easeInOut(duration: 0.3), value: color)
    }
}
