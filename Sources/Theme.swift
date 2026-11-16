import SwiftUI
import UIKit

/// Shared visual language for LinkaPlus: colors, gradients, haptics, card style.
enum Theme {
    static let accent = Color(red: 0.20, green: 0.52, blue: 1.0)   // vivid blue (info/connectivity)
    /// Adaptive colour: bright on dark backgrounds, darker on light (WCAG contrast).
    private static func dyn(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(UIColor { t in
            let c = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    static let open    = dyn((0.80, 0.40, 0.00), (1.00, 0.58, 0.10))  // orange = ontgrendeld
    static let locked  = dyn((0.05, 0.50, 0.22), (0.15, 0.78, 0.38))  // green  = vergrendeld
    static let danger  = dyn((0.80, 0.12, 0.16), (1.00, 0.30, 0.33))  // red    = alarm/laag/fout
    static let success = dyn((0.05, 0.50, 0.22), (0.15, 0.78, 0.38))  // green  = gelukt
    static let warn    = dyn((0.72, 0.38, 0.00), (1.00, 0.62, 0.15))  // orange = waarschuwing

    /// Corner radii — two sizes, both continuous (squircle).
    static let cardRadius: CGFloat = 20
    static let tileRadius: CGFloat = 16

    /// Battery is "low" below this percentage (single source of truth).
    static let batteryLowPct = 20

    /// Diagonal gradient from a base color — used for the hero control and icons.
    static func grad(_ c: Color) -> LinearGradient {
        LinearGradient(colors: [c.opacity(0.98), c.opacity(0.62)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Lightweight haptic feedback helpers.
enum Haptic {
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

/// Soft rounded card background.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// Button style that gives a subtle spring press-scale — used for the big lock control.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
