import Foundation
import SwiftUI

// MARK: - App Language

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese
    case english

    var id: String { rawValue }

    /// 设置页展示名（各语言用原生写法，便于识别）
    var nativeDisplayName: String {
        switch self {
        case .system: return "跟随系统 / Follow System"
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
}

// MARK: - Language Manager

@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    private static let storageKey = "appLanguage"

    /// 语言变更时递增，用于强制 SwiftUI 重建界面
    @Published private(set) var localeRevision = 0

    @Published var preference: AppLanguage {
        didSet {
            UserDefaults.standard.set(preference.rawValue, forKey: Self.storageKey)
            localeRevision += 1
        }
    }

    /// 实际生效的语言（system 会解析为中文或英文）
    var effectiveLanguage: AppLanguage {
        switch preference {
        case .system: return Self.resolveSystemLanguage()
        case .chinese, .english: return preference
        }
    }

    var locale: Locale {
        Locale(identifier: languageCode)
    }

    var languageCode: String {
        switch effectiveLanguage {
        case .chinese: return "zh-Hans"
        case .english: return "en"
        case .system: return "zh-Hans"
        }
    }

    var speechLocaleIdentifier: String {
        switch effectiveLanguage {
        case .chinese: return "zh-CN"
        case .english: return "en-US"
        case .system: return "zh-CN"
        }
    }

    /// 设置页当前语言展示
    var currentDisplayName: String {
        switch preference {
        case .system:
            let resolved = Self.resolveSystemLanguage()
            let resolvedName = resolved == .chinese ? "简体中文" : "English"
            return "\(L("settings.followSystem")) (\(resolvedName))"
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.storageKey),
           let saved = AppLanguage(rawValue: raw) {
            preference = saved
        } else {
            preference = .system
        }
    }

    /// 读取系统语言；失败或无对应语言时默认中文
    static func resolveSystemLanguage() -> AppLanguage {
        let preferred = Locale.preferredLanguages.first ?? ""
        guard !preferred.isEmpty else { return .chinese }
        let lower = preferred.lowercased()
        if lower.hasPrefix("zh") { return .chinese }
        if lower.hasPrefix("en") { return .english }
        return .chinese
    }

    func localized(_ key: String, _ arguments: CVarArg...) -> String {
        let format = StringCatalog.shared.string(for: key, languageCode: languageCode)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: arguments)
    }
}

// MARK: - Localization Helper

@MainActor
func L(_ key: String) -> String {
    LanguageManager.shared.localized(key)
}

@MainActor
func L(_ key: String, _ arguments: CVarArg...) -> String {
    LanguageManager.shared.localized(key, arguments)
}
