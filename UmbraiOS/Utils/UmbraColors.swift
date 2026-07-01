import SwiftUI

// MARK: - Umbra Color System (matching CSS variables)
struct UmbraColors {
    var isDark: Bool = false

    var bg: Color { isDark ? Color(hex: "15110E") : Color(hex: "F6F5F2") }
    var card: Color { isDark ? Color(hex: "232019") : Color(hex: "FFFFFF") }
    var bar: Color { isDark ? Color(hex: "1C1A17") : Color(hex: "FBFAF8") }
    var border: Color { isDark ? Color(hex: "332E26") : Color(hex: "E6E3DC") }
    var text: Color { isDark ? Color(hex: "EDEAE3") : Color(hex: "1F2320") }
    var muted: Color { isDark ? Color(hex: "9A938A") : Color(hex: "6B716B") }
    var orange: Color { Color(hex: "E8590C") }
    var orangeDeep: Color { Color(hex: "C2410C") }
    var orangeSoft: Color { isDark ? Color(hex: "E8590C").opacity(0.16) : Color(hex: "FFF1E6") }
    var orangeText: Color { isDark ? Color(hex: "F0A878") : Color(hex: "9A3412") }
    var success: Color { isDark ? Color(hex: "34B5A6") : Color(hex: "0F766E") }
    var successSoft: Color { isDark ? Color(hex: "0F766E").opacity(0.2) : Color(hex: "E2F1EF") }
    var warning: Color { isDark ? Color(hex: "D98A29") : Color(hex: "B45309") }
    var warningSoft: Color { isDark ? Color(hex: "B45309").opacity(0.22) : Color(hex: "FBEEDD") }
    var danger: Color { isDark ? Color(hex: "E0675C") : Color(hex: "B42318") }
    var dangerSoft: Color { isDark ? Color(hex: "B42318").opacity(0.22) : Color(hex: "FBE9E7") }
    var userBubble: Color { isDark ? Color(hex: "2B2620") : Color(hex: "EAF1F7") }
    var track: Color { isDark ? Color(hex: "1B1915") : Color(hex: "F3F2EF") }
    var chip: Color { isDark ? Color(hex: "2A251F") : Color(hex: "F0EEEA") }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Theme Environment
struct UmbraTheme: EnvironmentKey {
    static let defaultValue: Bool = false // false = light, true = dark
}

extension EnvironmentValues {
    var isDark: Bool {
        get { self[UmbraTheme.self] }
        set { self[UmbraTheme.self] = newValue }
    }
}
