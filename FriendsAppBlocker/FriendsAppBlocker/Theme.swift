import SwiftUI

enum Theme {
    // Colors
    static let background = Color(red: 0.95, green: 0.97, blue: 0.98)
    static let cardBackground = Color.white
    static let controlBackground = Color(red: 0.94, green: 0.96, blue: 0.97)
    static let accent = Color(red: 0.06, green: 0.35, blue: 0.95)
    static let accentSoft = Color(red: 0.86, green: 0.91, blue: 1.0)
    static let success = Color(red: 0.0, green: 0.54, blue: 0.36)
    static let successSoft = Color(red: 0.84, green: 0.95, blue: 0.91)
    static let warning = Color(red: 0.78, green: 0.48, blue: 0.0)
    static let warningSoft = Color(red: 1.0, green: 0.93, blue: 0.78)
    static let textPrimary = Color(red: 0.08, green: 0.10, blue: 0.13)
    static let textSecondary = Color(red: 0.43, green: 0.48, blue: 0.55)
    static let destructive = Color(red: 0.95, green: 0.3, blue: 0.3)
    static let border = Color(red: 0.86, green: 0.89, blue: 0.92)

    // Typography
    enum Font {
        static func title(_ size: CGFloat = 32) -> SwiftUI.Font {
            .system(size: size, weight: .bold, design: .rounded)
        }

        static func heading(_ size: CGFloat = 18) -> SwiftUI.Font {
            .system(size: size, weight: .semibold, design: .rounded)
        }

        static func body(_ size: CGFloat = 16) -> SwiftUI.Font {
            .system(size: size, weight: .regular, design: .rounded)
        }

        static func caption(_ size: CGFloat = 13) -> SwiftUI.Font {
            .system(size: size, weight: .medium, design: .rounded)
        }
    }

    // Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    // Corner Radius
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 10
    }
}

// Card style modifier
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.Spacing.md)
            .background(Theme.cardBackground)
            .cornerRadius(Theme.Radius.lg)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}
