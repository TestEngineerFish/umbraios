// 主 App 与 AutoFill 扩展之间的**共享存储**：设置项走 App Group，密钥走共享 Keychain。
//
// ⚠️ Target Membership：主 App + AutoFillExtension 双勾。
//
// 为什么需要这一层：扩展是独立进程，默认既读不到主 App 的 UserDefaults.standard，
// 也读不到它的 Keychain。结果就是填充面板里「服务端令牌要重填一次、Secret Key 要重输、
// Face ID 用不了」—— 用户实测点名的三件事，根子都在这里。
//
// 两个共享面各自的选择，是按**敏感度**分的，不能混：
//   · 服务端地址 / 令牌 / clientId 这类配置 → App Group 的 UserDefaults（够用、简单）；
//   · Secret Key、生物识别保护的主密码 → **共享 Keychain 访问组**。
//     这类东西放 UserDefaults 等于明文落盘，再方便也不做。
//
// 需要在 Xcode 里配（两个 target 都要，步骤见 doc/Widget与AutoFill-接入步骤.md）：
//   · App Groups：group.xyz.tingyusha.umbra.ios
//   · Keychain Sharing：xyz.tingyusha.umbra.ios.shared
// 没配好时全部**自动退回各自的私有存储**：功能照旧、只是不共享，不崩也不写错地方。
import Foundation
import Security

// MARK: - 共享设置（App Group）

enum UmbraGroupStore {
    static let appGroup = "group.xyz.tingyusha.umbra.ios"

    /// App Group 真的可用吗。UserDefaults(suiteName:) 在没配 entitlement 时也会给一个
    /// 「能用」的实例（只是落在自己沙盒里，另一个进程看不见）—— 用它判断会误判成正常，
    /// 所以查共享容器目录，那个才是实话。
    private static let ready: Bool =
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil

    /// 配好了就用共享域，没配好退回私有域。
    static let defaults: UserDefaults = {
        guard ready, let d = UserDefaults(suiteName: appGroup) else { return .standard }
        return d
    }()

    /// 读一个字符串：先读共享域；共享域没有就读私有域的老值并**顺手搬过去**。
    /// 老用户升级到这一版时，配置不会凭空消失。
    static func string(_ key: String) -> String? {
        if let v = defaults.string(forKey: key) { return v }
        guard defaults != .standard, let legacy = UserDefaults.standard.string(forKey: key) else { return nil }
        defaults.set(legacy, forKey: key)
        return legacy
    }

    static func bool(_ key: String) -> Bool {
        if defaults.object(forKey: key) != nil { return defaults.bool(forKey: key) }
        guard defaults != .standard, UserDefaults.standard.object(forKey: key) != nil else { return false }
        let legacy = UserDefaults.standard.bool(forKey: key)
        defaults.set(legacy, forKey: key)
        return legacy
    }

    static func set(_ value: Any?, _ key: String) { defaults.set(value, forKey: key) }
}

// MARK: - 共享 Keychain 访问组

enum UmbraKeychainShare {
    /// 访问组名。真实值要带团队前缀（`ABCDE12345.xyz…`），前缀在下面运行时问系统要 ——
    /// 硬编码团队 ID 会在换开发者账号那天悄悄失效。
    private static let suffix = "xyz.tingyusha.umbra.ios.shared"

    /// 完整访问组，拿不到（没配 Keychain Sharing）时返回 nil，调用方就退回私有组。
    static let group: String? = {
        guard let prefix = teamPrefix() else { return nil }
        return prefix + "." + suffix
    }()

    /// 问系统要团队前缀：写一条不指定访问组的探针，读回它落在哪个组里，
    /// 取第一段就是前缀（扩展里落在自己的 app id 组，前缀一样）。用完立刻删。
    private static func teamPrefix() -> String? {
        let account = "umbra.keychain.probe"
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data("probe".utf8)
        add[kSecReturnAttributes as String] = true
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var out: AnyObject?
        let status = SecItemAdd(add as CFDictionary, &out)
        defer { SecItemDelete(base as CFDictionary) }
        guard status == errSecSuccess,
              let attrs = out as? [String: Any],
              let g = attrs[kSecAttrAccessGroup as String] as? String,
              let prefix = g.split(separator: ".").first else { return nil }
        return String(prefix)
    }

    /// 给**写入**用的查询：配好了就指定共享组，没配就不指定（落私有组）。
    /// 读取一律**不指定**访问组 —— 不指定时系统会搜遍本 App 能访问的所有组，
    /// 这样老版本存在私有组里的条目照样读得到，不需要额外的迁移代码。
    static func stamp(_ query: [String: Any]) -> [String: Any] {
        guard let group else { return query }
        var q = query
        q[kSecAttrAccessGroup as String] = group
        return q
    }

    /// 这条条目**搬进共享组了吗** —— 用一个标记位记账，而不是去查条目属性。
    ///
    /// ⚠️ 这里踩过一次：上一版用 SecItemCopyMatching 查条目的 kSecAttrAccessGroup 来判断，
    /// 而主密码那条是 `.biometryCurrentSet` 保护的 —— **一查就弹一次系统验证**，
    /// 于是「刷脸取密码」变成了刷两次脸（用户实测点名）。
    /// 受保护的条目只能在拿着已验证的 LAContext 时碰，判断迁移与否不值得为它多弹一次。
    static func migrated(_ account: String) -> Bool {
        guard group != nil else { return true }   // 没开共享就无所谓搬不搬
        return UmbraGroupStore.bool("umbra.keychain.migrated." + account)
    }

    /// 写入共享组之后调一次，把账记上。
    static func markMigrated(_ account: String) {
        UmbraGroupStore.set(true, "umbra.keychain.migrated." + account)
    }

    static func clearMigrated(_ account: String) {
        UmbraGroupStore.set(false, "umbra.keychain.migrated." + account)
    }
}
