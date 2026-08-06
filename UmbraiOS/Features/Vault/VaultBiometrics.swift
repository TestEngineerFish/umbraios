// 生物识别凭证：用 Face ID / Touch ID 取回本地保存的主密码。
//
// ⚠️ Target Membership：主 App + AutoFillExtension 双勾 —— 填充面板也要能刷脸解锁，
// 否则每次填一个密码都得手打一遍主密码（用户实测点名）。
// 从 VaultKit.swift 里抽出来单独成文件，就是为了让扩展只带这一小块，
// 不必把整个 VaultKit（会话/体检/字段行那些 UI）拖进扩展 —— 扩展内存上限约 120MB。
//
// Keychain 条目存在**共享访问组**里（见 VaultSharing.swift），两个进程读的是同一条。
import Foundation
import Security
import LocalAuthentication

// MARK: - 生物识别凭证
//
// 「用 Face ID 解锁」不是「跳过主密码」，而是**用生物识别取回本地保存的主密钥**：
// 解密需要 AUK，AUK 只能由主密码 + Secret Key 派生，所以主密码必须存在这台设备上。
//
// 这是一个明确的取舍，界面上说清楚了：
//   · 开关默认开，但**开启时会先验一次主密码 + 走一次生物识别**才写入；
//   · Keychain 项带 `.biometryCurrentSet` —— 只有刷脸/指纹取得出，
//     而且一旦录入的面容/指纹变化，这条凭证**立刻作废**（别人事后加一张脸也没用）；
//   · `WhenUnlockedThisDeviceOnly` —— 不进 iCloud 钥匙串、不进备份、只在本机解锁时可读；
//   · 关掉开关 / 「忘掉已存的主密码」/「忘掉本机数据」都会清除。
//
// **兜底必须是保险箱主密码，不能是设备锁屏密码**：设备密码解不开密文。
// 所以策略用 `.deviceOwnerAuthenticationWithBiometrics`（不是 deviceOwnerAuthentication），
// 并把 localizedFallbackTitle 置空，隐藏系统那颗「输入密码」。
enum UmbraBiometricStore {
    private static let account = "umbra.vault.masterPassword"
    /// 存过没有的标记。**不用查 Keychain 来判断** ——
    /// 带 .biometryCurrentSet 的项一旦被查询就可能触发系统验证 UI，
    /// 而这个判断是在每次画上锁页时都要用的，那会变成"进页面就弹脸"。
    /// （上一版用 kSecUseAuthenticationUI 想跳过 UI，那个 API 已废弃、在新系统上不保证生效，
    ///  结果是后台线程里 SecItemCopyMatching 直接把进程带崩。）
    private static let flagKey = "umbra.vault.hasBioCred"

    /// 必须显式声明 Error（Result 的失败类型有这个约束）和 Equatable（下面要 == 比较）。
    enum Failure: Error, Equatable {
        /// 用户取消系统弹窗 / 点了兜底 —— 之后不要再自动弹。
        case cancelled
        /// 连错太多次被系统锁住，要先用设备密码解锁一次 iPhone。
        case lockout
        /// 面容/指纹数据变了，`.biometryCurrentSet` 保护的项已失效。
        case invalidated
        /// 设备不支持或没录入。
        case unavailable
        /// 其它（没识别通过、超时…）。
        case failed

        var message: String {
            switch self {
            case .cancelled: return "已取消。可以点上面的图标再识别一次，或者输入主密码。"
            case .lockout: return "Face ID 被系统锁定了，需要先用设备密码解锁一次 iPhone。现在可以用主密码打开保险箱。"
            case .invalidated: return "设备的面容数据变了，需要重新输入一次主密码来重新授权 Face ID。"
            case .unavailable: return "这台设备没有可用的生物识别。"
            case .failed: return "系统没能识别，可能是被遮挡或超过了等待时间。点一下上面的图标再识别一次，或者直接输入主密码。"
            }
        }
    }

    /// 标记存共享域：主 App 存过之后，填充扩展也要知道「可以刷脸」。
    static var hasCredential: Bool { UmbraGroupStore.bool(flagKey) }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrAccount as String: account]
    }

    /// 写入。调用方**必须**已经验过主密码 —— 这里不做验证。
    @discardableResult
    static func save(password: String) -> Bool {
        clear()
        guard let data = password.data(using: .utf8),
              let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .biometryCurrentSet,
                nil) else { return false }
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessControl as String] = access
        // 落共享访问组，填充扩展才读得到（没配 Keychain Sharing 时自动落私有组）。
        let ok = SecItemAdd(UmbraKeychainShare.stamp(add) as CFDictionary, nil) == errSecSuccess
        UmbraGroupStore.set(ok, flagKey)
        if ok { UmbraKeychainShare.markMigrated(account) }
        return ok
    }

    /// 取回主密码。
    ///
    /// **两步走，顺序不能反**：先 `evaluatePolicy` 让 LocalAuthentication 自己去弹 UI，
    /// 通过之后再拿这个已验证的 context 去读 Keychain（不会二次弹窗）。
    /// 上一版是直接在后台线程 `SecItemCopyMatching` 让 Security 框架自己弹 ——
    /// 那条路在这里会当场崩进程，而且拿不到 .userCancel / .biometryLockout 这些能区分的错误码。
    ///
    /// completion 标成 `@MainActor`：调用方全是 UI 状态（会话里的 @Published、页面里的 @State），
    /// 而 LAContext 的回调落在任意线程上。类型上标死，就不必在每个调用点各自记得切回主线程。
    static func load(reason: String, completion: @escaping @MainActor (Result<String, Failure>) -> Void) {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = ""      // 隐藏系统的「输入密码」：设备密码解不开密文
        // 允许这次识别结果在 10 秒内被复用：下面读 Keychain 时带着同一个 ctx，
        // 万一系统仍想再验一次，也直接复用刚才那次，不会再弹第二张脸。
        ctx.touchIDAuthenticationAllowableReuseDuration = 10
        var canErr: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &canErr) else {
            let f: Failure = (canErr?.code == LAError.biometryLockout.rawValue) ? .lockout : .unavailable
            Task { @MainActor in completion(.failure(f)) }
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, err in
            guard ok else {
                let f = map(err)
                Task { @MainActor in completion(.failure(f)) }
                return
            }
            // 已经验过了，这次读不会再弹。放后台队列只是因为 Keychain 调用可能有 IO。
            DispatchQueue.global(qos: .userInitiated).async {
                var q = baseQuery()
                q[kSecReturnData as String] = true
                q[kSecUseAuthenticationContext as String] = ctx
                var out: AnyObject?
                let status = SecItemCopyMatching(q as CFDictionary, &out)
                let value = (status == errSecSuccess)
                    ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) }
                    : nil
                Task { @MainActor in
                    if let value {
                        // 老版本存在私有组里的条目：这会儿手上正好有明文，顺手搬进共享组，
                        // 之后填充扩展才刷得了脸。搬没搬过**看标记**，不去查条目属性 ——
                        // 查一次受 .biometryCurrentSet 保护的条目就会多弹一次脸。
                        if !UmbraKeychainShare.migrated(account) { save(password: value) }
                        completion(.success(value))
                    } else {
                        // 读不出来 = 凭证已失效（多半是重新录了面容）。清掉标记，让界面回到「要输主密码」。
                        clear()
                        completion(.failure(.invalidated))
                    }
                }
            }
        }
    }

    /// 只做一次生物识别验证，不读 Keychain。开启开关时用。
    static func verifyOnly(reason: String, completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = ""
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            Task { @MainActor in completion(.failure(.unavailable)) }
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, err in
            let r: Result<Void, Failure> = ok ? .success(()) : .failure(map(err))
            Task { @MainActor in completion(r) }
        }
    }

    private static func map(_ err: Error?) -> Failure {
        guard let code = (err as NSError?)?.code else { return .failed }
        switch code {
        case LAError.userCancel.rawValue, LAError.appCancel.rawValue, LAError.systemCancel.rawValue:
            return .cancelled
        case LAError.userFallback.rawValue:
            return .cancelled
        case LAError.biometryLockout.rawValue:
            return .lockout
        case LAError.biometryNotEnrolled.rawValue, LAError.biometryNotAvailable.rawValue:
            return .unavailable
        default:
            return .failed
        }
    }

    static func clear() {
        // 删除**不带**访问组：不指定时系统会搜遍本 App 能访问的所有组，
        // 共享组和老的私有组会一起清掉，不留残条。
        SecItemDelete(baseQuery() as CFDictionary)
        UmbraGroupStore.set(false, flagKey)
        UmbraKeychainShare.clearMigrated(account)
    }
}
