import SwiftUI

/// A visual of the LINKA LEO ring lock: a horseshoe body with a bolt bar that
/// slides across the bottom gap to lock, and retracts to open. The bar animates
/// over ~1.2s so it visually follows the real motor (which isn't instant).
struct LockGraphic: View {
    /// true = locked (bar closed), false = open (bar retracted).
    let locked: Bool
    /// Colour of the ring (green locked, orange open, blue unknown).
    let color: Color
    var size: CGFloat = 200

    var body: some View {
        ZStack {
            // Horseshoe body: a ring with a gap at the bottom.
            Circle()
                .trim(from: 0.07, to: 0.93)
                .stroke(Theme.grad(color),
                        style: StrokeStyle(lineWidth: size * 0.17, lineCap: .round))
                .rotationEffect(.degrees(90))
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.28), radius: 10, y: 6)

            // Bolt bar across the bottom gap.
            Capsule()
                .fill(Color.white)
                .frame(width: locked ? size * 0.54 : size * 0.17, height: size * 0.12)
                .overlay(
                    Capsule().stroke(color.opacity(0.25), lineWidth: 1)
                )
                .offset(x: locked ? 0 : size * 0.21, y: size * 0.415)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)

            // Lock glyph in the centre — tinted to the ring colour so it reads as
            // part of the graphic, not a sticker on top. The sliding bolt carries
            // the state; the glyph is a quiet reinforcement.
            Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: size * 0.20, weight: .semibold))
                .foregroundStyle(color)
                .offset(y: -size * 0.04)
                .animation(.easeInOut(duration: 0.3), value: locked)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 1.2), value: locked)
    }
}
