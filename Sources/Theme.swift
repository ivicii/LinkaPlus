import SwiftUI
import UIKit

/// Shared visual language for LinkaPlus: colors, gradients, haptics, card style.
enum Theme {
    static let accent = Color(red: 0.20, green: 0.52, blue: 1.0)   // vivid blue
    static let open   = Color(red: 1.00, green: 0.56, blue: 0.0)   // orange = ontgrendeld
    static let locked = Color(red: 0.13, green: 0.77, blue: 0.37)  // green  = vergrendeld
    static let danger = Color(red: 0.98, green: 0.26, blue: 0.30)

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
                RoundedRectangle(cornerRadius: 20, style: .continuous)
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
