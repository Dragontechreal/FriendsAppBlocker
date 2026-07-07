import SwiftUI

enum Theme {
    // Colors
    static let background = adaptive(light: Color(red: 0.95, green: 0.97, blue: 0.98), dark: Color(red: 0.06, green: 0.07, blue: 0.09))
    static let cardBackground = adaptive(light: .white, dark: Color(red: 0.11, green: 0.13, blue: 0.16))
    static let controlBackground = adaptive(light: Color(red: 0.94, green: 0.96, blue: 0.97), dark: Color(red: 0.16, green: 0.18, blue: 0.22))
    static let accent = adaptive(light: Color(red: 0.06, green: 0.35, blue: 0.95), dark: Color(red: 0.42, green: 0.63, blue: 1.0))
    static let accentSoft = adaptive(light: Color(red: 0.86, green: 0.91, blue: 1.0), dark: Color(red: 0.13, green: 0.20, blue: 0.34))
    static let success = adaptive(light: Color(red: 0.0, green: 0.54, blue: 0.36), dark: Color(red: 0.35, green: 0.82, blue: 0.61))
    static let successSoft = adaptive(light: Color(red: 0.84, green: 0.95, blue: 0.91), dark: Color(red: 0.10, green: 0.24, blue: 0.19))
    static let warning = adaptive(light: Color(red: 0.78, green: 0.48, blue: 0.0), dark: Color(red: 1.0, green: 0.70, blue: 0.28))
    static let warningSoft = adaptive(light: Color(red: 1.0, green: 0.93, blue: 0.78), dark: Color(red: 0.30, green: 0.21, blue: 0.08))
    static let textPrimary = adaptive(light: Color(red: 0.08, green: 0.10, blue: 0.13), dark: Color(red: 0.94, green: 0.96, blue: 0.98))
    static let textSecondary = adaptive(light: Color(red: 0.43, green: 0.48, blue: 0.55), dark: Color(red: 0.62, green: 0.67, blue: 0.74))
    static let destructive = adaptive(light: Color(red: 0.95, green: 0.3, blue: 0.3), dark: Color(red: 1.0, green: 0.43, blue: 0.43))
    static let border = adaptive(light: Color(red: 0.86, green: 0.89, blue: 0.92), dark: Color(red: 0.23, green: 0.26, blue: 0.31))

    private static func adaptive(light: Color, dark: Color) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

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
