import Foundation

/// 运行时字符串表：优先从 .lproj/Localizable.strings 加载；若无则从 Localizable.xcstrings 解析。
final class StringCatalog {
    static let shared = StringCatalog()

    private var tables: [String: [String: String]] = [:]
    private let sourceLanguage = "zh-Hans"

    private init() {
        loadFromLproj("zh-Hans")
        loadFromLproj("zh_CN")
        loadFromLproj("en")
        if tables.isEmpty {
            loadFromXcstrings()
        }
    }

    private func loadFromLproj(_ code: String) {
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path),
              let stringsPath = bundle.path(forResource: "Localizable", ofType: "strings"),
              let dict = NSDictionary(contentsOfFile: stringsPath) as? [String: String] else {
            return
        }
        tables[code] = dict
    }

    /// 从 String Catalog 源文件解析（.lproj 未生成时的兜底）
    private func loadFromXcstrings() {
        guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "xcstrings")
            ?? Bundle.main.url(forResource: "Localizable", withExtension: "xcstrings", subdirectory: "UmbraiOS/Resources"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any] else {
            return
        }

        for (key, entry) in strings {
            guard let entryDict = entry as? [String: Any],
                  let localizations = entryDict["localizations"] as? [String: Any] else { continue }

            for (lang, loc) in localizations {
                guard let locDict = loc as? [String: Any],
                      let unit = locDict["stringUnit"] as? [String: Any],
                      let value = unit["value"] as? String else { continue }
                if tables[lang] == nil { tables[lang] = [:] }
                tables[lang]?[key] = value
            }
        }
    }

    func string(for key: String, languageCode: String) -> String {
        let candidates: [String]
        switch languageCode {
        case "zh-Hans", "zh_CN", "zh-CN":
            candidates = ["zh-Hans", "zh_CN", "zh-CN"]
        default:
            candidates = [languageCode]
        }
        for code in candidates {
            if let value = tables[code]?[key] { return value }
        }
        if let value = tables[sourceLanguage]?[key] { return value }
        return key
    }

    var isLoaded: Bool { !tables.isEmpty }
}
