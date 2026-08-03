// 密码保险箱的支撑件：会话与自动锁定、密码强度、安全体检、字段行、分数环、剪贴板。
//
// 加解密本身不在这里 —— VaultFeature.swift 里那套（PBKDF2-SHA256 600k 次派生 AUK、
// AES-256-GCM、Secret Key 存 Keychain、服务端零知识只存密文）已经跑通并和电脑端互通，
// **一行都不动**。这里只加界面这一层缺的东西。
//
// 两级锁定（设计稿的「自动锁定 + Face ID」要它才成立）：
//   软锁 —— 界面锁住，AUK 还在内存里。自动锁定走这一档，刷脸即可。
//   硬锁 —— VaultStore.lock()，AUK 清掉。「立即上锁」和退出应用走这一档。
//
// 硬锁下的「Face ID 直接解锁」是**可选**的：打开之后主密码会存进这台设备带生物识别
// 保护的 Keychain（细节与取舍见 UmbraBiometricStore）。默认关闭 —— 关着的时候
// 「主密码不保存」这句话仍然成立，界面文案也会跟着变。
import SwiftUI
import UIKit
import LocalAuthentication
import Security

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

    static var hasCredential: Bool { UserDefaults.standard.bool(forKey: flagKey) }

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
        let ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        UserDefaults.standard.set(ok, forKey: flagKey)
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
        SecItemDelete(baseQuery() as CFDictionary)
        UserDefaults.standard.set(false, forKey: flagKey)
    }
}

// MARK: - 会话
//
// 两级锁定：
//   软锁 —— 界面锁住，AUK 还在内存里。自动锁定走这一档。
//   硬锁 —— VaultStore.lock()，AUK 清掉。「立即上锁」和退出应用走这一档。
//
// 解锁页的状态机（规格见「Face ID 解锁-实现说明」）：
//   idle ──进页面自动/点图标──▶ scanning ──通过──▶ unlocked
//                                    └──未通过──▶ failed ──点图标──▶ scanning
//   failed ──「用主密码解锁」──▶ idle + fallbackOnly
@MainActor
final class UmbraVaultSession: ObservableObject {

    enum FaceState { case idle, scanning, failed }

    @Published var softLocked = false
    @Published private(set) var faceState: FaceState = .idle
    @Published private(set) var faceFailure: UmbraBiometricStore.Failure? = nil
    /// 用户明确选了「用主密码解锁」/ 主动上锁 / 取消过系统弹窗 —— **这期间不再自动发起识别**。
    /// 少了它，用户刚点「用主密码解锁」页面又立刻弹系统识别，主密码根本输不进去。
    @Published private(set) var fallbackOnly = false
    /// 本次进入解锁页是否已经自动发起过。只在离开页面时清，防止重渲染反复弹窗。
    private var autoTriedThisVisit = false

    @Published var autoLockMinutes: Int {
        didSet { UserDefaults.standard.set(autoLockMinutes, forKey: "umbra.vault.lockMin"); touch() }
    }
    @Published var maskEnabled: Bool {
        didSet { UserDefaults.standard.set(maskEnabled, forKey: "umbra.vault.mask") }
    }
    /// 设置里的「用 Face ID 解锁」。**只读**——要改走 enableBiometry / disableBiometry，
    /// 因为开启必须先验主密码再验生物识别，直接赋值会绕过这两步。
    @Published private(set) var faceIDEnabled: Bool
    @Published private(set) var hasBiometricCredential = UmbraBiometricStore.hasCredential

    /// 从记录详情返回时要滚回哪一行。存在 session 上而不是页面 @State 里：
    /// 页面在 pop 之后会被重建，@State 会跟着没。
    @Published var lastOpenedRecordId: String?

    private var lastActivity = Date()
    private var ticker: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        autoLockMinutes = d.object(forKey: "umbra.vault.lockMin") as? Int ?? 10
        maskEnabled = d.object(forKey: "umbra.vault.mask") as? Bool ?? true
        faceIDEnabled = d.object(forKey: "umbra.vault.faceID") as? Bool ?? true
    }

    // MARK: 生物识别可用性

    var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "生物识别"
        }
    }

    // MARK: 自动锁定

    func touch() { lastActivity = Date() }

    func startAutoLock() {
        touch()
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard !self.softLocked else { continue }
                if Date().timeIntervalSince(self.lastActivity) >= Double(self.autoLockMinutes * 60) {
                    self.softLocked = true
                    // 超时上锁时用户多半已经不看手机了，这时候弹识别没意义。
                    self.fallbackOnly = true
                }
            }
        }
    }

    func stopAutoLock() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: 解锁页状态

    /// 进入解锁页时调。返回 true 表示"该自动发起一次识别了"。
    /// 六个条件全满足才给过，逐条对应规格第 2 节。
    func shouldAutoScan(unlocked: Bool) -> Bool {
        guard !unlocked,
              faceIDEnabled,
              hasBiometricCredential || softLocked,   // 软锁只要验身份，不必有存好的凭证
              biometryAvailable,
              !fallbackOnly,
              faceState == .idle,
              !autoTriedThisVisit else { return false }
        autoTriedThisVisit = true
        return true
    }

    /// 离开解锁页时调，让下次进来重新自动识别一次。
    func resetVisit() {
        autoTriedThisVisit = false
        faceState = .idle
        faceFailure = nil
    }

    /// 用户主动选择走主密码：收起错误、这期间不再自动弹。
    func preferPassword() {
        faceState = .idle
        faceFailure = nil
        fallbackOnly = true
    }

    /// 主动上锁（首页「立即上锁」/ 设置里那颗）。同样要压住自动识别。
    func markManualLock() {
        softLocked = false
        fallbackOnly = true
        faceState = .idle
        faceFailure = nil
    }

    /// 解锁成功后复位，下次上锁又是新的一轮。
    func markUnlocked() {
        faceState = .idle
        faceFailure = nil
        fallbackOnly = false
        touch()
    }

    // MARK: 发起识别

    /// 硬锁：刷脸 → 取回主密码 → 交给调用方去解密。
    func scanForPassword(_ onPassword: @escaping @MainActor (String) -> Void) {
        guard faceState != .scanning else { return }
        guard faceIDEnabled else { return }
        guard biometryAvailable else { faceState = .failed; faceFailure = .unavailable; return }
        guard hasBiometricCredential else { faceState = .failed; faceFailure = .invalidated; return }
        faceState = .scanning
        faceFailure = nil
        UmbraBiometricStore.load(reason: "解锁密码保险箱") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let pw):
                self.faceState = .idle
                onPassword(pw)
            case .failure(let f):
                self.faceState = .failed
                self.faceFailure = f
                if f == .cancelled { self.fallbackOnly = true }
                if f == .invalidated { self.hasBiometricCredential = false }
            }
        }
    }

    /// 软锁：AUK 还在内存里，只要证明是本人就行，不用取密码。
    func scanForSoftUnlock() {
        guard faceState != .scanning else { return }
        guard biometryAvailable else { faceState = .failed; faceFailure = .unavailable; return }
        faceState = .scanning
        faceFailure = nil
        UmbraBiometricStore.verifyOnly(reason: "解锁密码保险箱") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.faceState = .idle
                self.softLocked = false
                self.touch()
            case .failure(let f):
                self.faceState = .failed
                self.faceFailure = f
                if f == .cancelled { self.fallbackOnly = true }
            }
        }
    }

    // MARK: 开关

    /// 开启。**先验主密码、再验生物识别，两关都过才写入** ——
    /// 用户点开关时期望立刻被验证一次，而不是"下次解锁时悄悄存下来"。
    /// verifyPassword 由调用方（VaultStore）提供，本地校验，不联网。
    func enableBiometry(password: String,
                        verifyPassword: (String) -> Bool,
                        completion: @escaping @MainActor (String?) -> Void) {
        guard biometryAvailable else { completion("这台设备没有可用的\(biometryName)"); return }
        guard verifyPassword(password) else { completion("主密码不对"); return }
        UmbraBiometricStore.verifyOnly(reason: "开启用\(biometryName)解锁保险箱") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if UmbraBiometricStore.save(password: password) {
                    self.hasBiometricCredential = true
                    self.faceIDEnabled = true
                    UserDefaults.standard.set(true, forKey: "umbra.vault.faceID")
                    completion(nil)
                } else {
                    completion("存不进钥匙串，检查一下这台设备有没有设锁屏密码")
                }
            case .failure(let f):
                completion(f.message)
            }
        }
    }

    func disableBiometry() {
        faceIDEnabled = false
        UserDefaults.standard.set(false, forKey: "umbra.vault.faceID")
        forgetPassword()
    }

    func forgetPassword() {
        UmbraBiometricStore.clear()
        hasBiometricCredential = false
    }
}

// MARK: - 剪贴板
//
// 敏感值复制后 60 秒自动清空。**清之前要确认剪贴板里还是我们放的那份** ——
// 用户中途复制了别的东西，我们再去清就把他的东西弄没了。
enum UmbraClipboard {
    static func copySensitive(_ value: String) {
        UIPasteboard.general.string = value
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if UIPasteboard.general.string == value { UIPasteboard.general.string = "" }
        }
    }
}

// MARK: - 密码强度
//
// 只看密码本身：长度 + 字符集种类。**不联网校验**，也不查泄漏库 ——
// 保险箱的原则是内容不出设备，为了打个分把密码发出去是本末倒置。
enum UmbraPasswordStrength {
    /// 0 弱 / 1 一般 / 2 强 / 3 很强
    static func level(_ pw: String) -> Int {
        guard !pw.isEmpty else { return 0 }
        var kinds = 0
        if pw.rangeOfCharacter(from: .lowercaseLetters) != nil { kinds += 1 }
        if pw.rangeOfCharacter(from: .uppercaseLetters) != nil { kinds += 1 }
        if pw.rangeOfCharacter(from: .decimalDigits) != nil { kinds += 1 }
        if pw.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil { kinds += 1 }
        let n = pw.count
        if n < 8 || kinds <= 1 { return 0 }
        if n < 12 || kinds == 2 { return 1 }
        if n < 16 || kinds == 3 { return 2 }
        return 3
    }

    static func label(_ level: Int) -> String {
        ["弱", "一般", "强", "很强"][min(max(level, 0), 3)]
    }
    static func color(_ level: Int) -> Color {
        switch min(max(level, 0), 3) {
        case 0: return UmbraColor.danger
        case 1: return UmbraColor.warning
        default: return UmbraColor.success
        }
    }
    static func ratio(_ level: Int) -> Double {
        [0.3, 0.55, 0.8, 1.0][min(max(level, 0), 3)]
    }
}

// MARK: - 安全体检
//
// 全部在本机算，不上传、不联网。四类问题都来自记录本身：
//   重复使用 / 弱密码 / 没开两步验证 / 长期未更新。
struct UmbraVaultAudit {

    struct Finding: Identifiable {
        let id: String        // = item.id + 类别，同一条记录可能出现在多组里
        let item: VItem
        let why: String
    }

    struct Group: Identifiable {
        let id: String
        let name: String
        let iconPath: String
        let color: Color
        let findings: [Finding]
    }

    let groups: [Group]
    let total: Int
    let score: Int

    init(items: [VItem]) {
        // 先把每条记录的密码抽出来（账号控件的 password / 密文控件的 value）。
        var pwOf: [String: String] = [:]
        var has2FA: Set<String> = []
        for it in items {
            for b in it.blocks {
                if b.type == "account" {
                    let p = b.data["password"]?.string ?? ""
                    if !p.isEmpty && pwOf[it.id] == nil { pwOf[it.id] = p }
                    if b.data["otp"]?.bool == true { has2FA.insert(it.id) }
                } else if b.type == "secret" {
                    let p = b.data["value"]?.string ?? ""
                    if !p.isEmpty && pwOf[it.id] == nil { pwOf[it.id] = p }
                }
            }
        }

        // 重复：同一个密码被两条以上记录用了。
        var byPassword: [String: [VItem]] = [:]
        for it in items {
            if let p = pwOf[it.id], !p.isEmpty { byPassword[p, default: []].append(it) }
        }
        var dup: [Finding] = []
        for (_, group) in byPassword where group.count > 1 {
            for it in group {
                let others = group.filter { $0.id != it.id }.map(\.title)
                let names = others.prefix(2).joined(separator: "、")
                let why = others.count > 2 ? "和另外 \(others.count) 条用了同一个密码" : "与「\(names)」重复"
                dup.append(Finding(id: it.id + ".dup", item: it, why: why))
            }
        }

        // 弱：强度 0。理由里带上具体长度，不写「太弱了」这种笼统话。
        let weak = items.compactMap { it -> Finding? in
            guard let p = pwOf[it.id], !p.isEmpty,
                  UmbraPasswordStrength.level(p) == 0 else { return nil }
            return Finding(id: it.id + ".weak", item: it,
                           why: "\(p.count) 位，强度 \(UmbraPasswordStrength.label(0))")
        }

        // 没开两步验证：只看**有账号控件**的记录 —— 一张护照没有两步验证很正常。
        let no2fa = items.compactMap { it -> Finding? in
            guard it.blocks.contains(where: { $0.type == "account" }),
                  !has2FA.contains(it.id) else { return nil }
            return Finding(id: it.id + ".2fa", item: it, why: "支持两步验证但没开")
        }

        // 长期未更新：90 天以上没动过，且它是有密码的记录。
        let now = Date().timeIntervalSince1970 * 1000
        let stale = items.compactMap { it -> Finding? in
            guard pwOf[it.id] != nil else { return nil }
            let days = Int((now - it.updatedAt) / 86_400_000)
            guard days >= 90 else { return nil }
            return Finding(id: it.id + ".old", item: it, why: "\(days) 天没动过")
        }

        var out: [Group] = []
        if !dup.isEmpty {
            out.append(Group(id: "dup", name: "重复使用", iconPath: UmbraIconPath.xCircle,
                             color: UmbraColor.danger, findings: dup))
        }
        if !weak.isEmpty {
            out.append(Group(id: "weak", name: "弱密码", iconPath: UmbraIconPath.alertTriangle,
                             color: UmbraColor.danger, findings: weak))
        }
        if !no2fa.isEmpty {
            out.append(Group(id: "2fa", name: "没开两步验证", iconPath: UmbraIconPath.shield,
                             color: UmbraColor.warning, findings: no2fa))
        }
        if !stale.isEmpty {
            out.append(Group(id: "old", name: "长期未更新", iconPath: UmbraIconPath.clock,
                             color: UmbraColor.muted, findings: stale))
        }
        groups = out

        // 分数：按「有问题的记录占比」扣分，重复和弱各扣得更狠。
        // 这个公式没有权威依据，所以界面上不写「安全等级 A」这种唬人的说法，只给一个数字和明细。
        let flagged = Set(dup.map(\.item.id)).union(weak.map(\.item.id))
        let soft = Set(no2fa.map(\.item.id)).union(stale.map(\.item.id))
        total = dup.count + weak.count + no2fa.count + stale.count
        if items.isEmpty {
            score = 100
        } else {
            let hard = Double(flagged.count) / Double(items.count)
            let mild = Double(soft.subtracting(flagged).count) / Double(items.count)
            score = max(0, min(100, Int(100 - hard * 60 - mild * 25)))
        }
    }
}

// MARK: - 分数环
//
// 44 / 72 两档，--orange 描边 + --orange-text 数字。
struct UmbraScoreRing: View {
    let score: Int
    var size: CGFloat = 72

    private var color: Color {
        if score >= 80 { return UmbraColor.success }
        if score >= 50 { return UmbraColor.orange }
        return UmbraColor.danger
    }

    var body: some View {
        // 三档尺寸。首页那一行细摘要用 22 —— 沿用 44 档的 15pt 数字会顶破圆环，
        // 所以描边和字号都要跟着缩。
        let lw: CGFloat = size >= 60 ? 5 : (size >= 40 ? 3 : 2)
        let fs: CGFloat = size >= 60 ? 24 : (size >= 40 ? 15 : 10)
        return Circle()
            .strokeBorder(color, lineWidth: lw)
            .frame(width: size, height: size)
            .overlay(
                Text("\(score)")
                    .font(UmbraFont.mono(fs, .w600))
                    .foregroundColor(score >= 80 ? UmbraColor.success : (score >= 50 ? UmbraColor.orangeText : UmbraColor.danger))
            )
    }
}

// MARK: - 字段行（FieldRow）
//
// 标签 12/560/.06em + 值（敏感值等宽 + 遮罩）+ 44×44 的显示 / 复制按钮。
// 两条 iOS 特有规则都在这里：
//   · 敏感值显示 8 秒后自动重新遮盖；
//   · 复制反馈是**行内**「图标转对勾 + 已复制」1.5 秒，不用 toast。
struct UmbraFieldRow: View {
    let label: String
    let value: String
    /// 敏感值：默认遮罩、等宽显示。
    var secret: Bool = false
    /// 值是不是等宽（路径 / ID / 密钥 / 网址）。敏感值一定等宽。
    var mono: Bool = false
    /// 显示密码强度条（密码字段用）。
    var showStrength: Bool = false
    /// 值多行展开（文本控件）。
    var multiline: Bool = false

    @State private var revealed = false
    @State private var copied = false
    @State private var revealTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                UmbraFieldLabel(text: label)
                Text(display)
                    .font(mono || secret ? UmbraFont.mono(15) : UmbraFont.sans(15, .w400))
                    .foregroundColor(value.isEmpty ? UmbraColor.faint : UmbraColor.text)
                    .lineSpacing(15 * 0.65)
                    .lineLimit(multiline ? nil : 2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showStrength && !value.isEmpty {
                    let lv = UmbraPasswordStrength.level(value)
                    HStack(spacing: 6) {
                        UmbraProgressBar(progress: UmbraPasswordStrength.ratio(lv),
                                         color: UmbraPasswordStrength.color(lv))
                            .frame(width: 56)
                        Text("强度 \(UmbraPasswordStrength.label(lv))")
                            .font(UmbraFont.sans(11.5, .w560))
                            .foregroundColor(UmbraPasswordStrength.color(lv))
                    }
                    .padding(.top, 2)
                }
            }

            if secret && !value.isEmpty {
                Button(action: toggleReveal) {
                    UmbraIcon(d: revealed ? UmbraIconPath.eyeOff : UmbraIconPath.eye,
                              size: 20, strokeWidth: 1.9)
                        .foregroundColor(UmbraColor.muted)
                        .frame(width: UmbraMetric.tapMin, height: UmbraMetric.tapMin)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !value.isEmpty {
                Button(action: copy) {
                    VStack(spacing: 2) {
                        UmbraIcon(d: copied ? UmbraIconPath.check : UmbraIconPath.copy,
                                  size: 19, strokeWidth: 1.9)
                        if copied {
                            Text("已复制").font(UmbraFont.sans(9.5, .w560))
                        }
                    }
                    .foregroundColor(copied ? UmbraColor.success : UmbraColor.muted)
                    .frame(minWidth: UmbraMetric.tapMin, minHeight: UmbraMetric.tapMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .onDisappear { revealTask?.cancel() }
    }

    private var display: String {
        if value.isEmpty { return "—" }
        if secret && !revealed { return String(repeating: "•", count: min(max(value.count, 6), 16)) }
        return value
    }

    private func toggleReveal() {
        revealTask?.cancel()
        revealed.toggle()
        guard revealed else { return }
        // 8 秒后自动重新遮盖。计时器是真的 —— 只在按下时算一次的话，
        // 用户切走再回来会看到一个一直亮着的密码。
        revealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            revealed = false
        }
    }

    private func copy() {
        if secret { UmbraClipboard.copySensitive(value) } else { UIPasteboard.general.string = value }
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

