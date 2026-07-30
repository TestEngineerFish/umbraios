// 密码保险箱的支撑件：会话与自动锁定、密码强度、安全体检、字段行、分数环、剪贴板。
//
// 加解密本身不在这里 —— VaultFeature.swift 里那套（PBKDF2-SHA256 600k 次派生 AUK、
// AES-256-GCM、Secret Key 存 Keychain、服务端零知识只存密文）已经跑通并和电脑端互通，
// **一行都不动**。这里只加界面这一层缺的东西。
//
// 两级锁定（这是新加的，设计稿的「自动锁定 + Face ID」要它才成立）：
//   软锁 —— 界面锁住，AUK 还在内存里。自动锁定走这一档，Face ID 就能解开。
//   硬锁 —— VaultStore.lock()，AUK 清掉。「立即上锁」和退出应用走这一档，只能用主密码。
// 为什么不做「Face ID 直接解锁」：那需要把主密码存进 Keychain，而设计稿和上锁页
// 都写着「主密码不保存、不上传」。软锁这一档能在不存主密码的前提下把 Face ID 用起来。
import SwiftUI
import UIKit
import LocalAuthentication

// MARK: - 会话

@MainActor
final class UmbraVaultSession: ObservableObject {
    /// 软锁：界面锁住但 AUK 还在内存里，Face ID / 主密码都能解开。
    @Published var softLocked = false
    /// 自动锁定分钟数。
    @Published var autoLockMinutes: Int {
        didSet { UserDefaults.standard.set(autoLockMinutes, forKey: "umbra.vault.lockMin"); touch() }
    }
    /// 切后台遮盖。
    @Published var maskEnabled: Bool {
        didSet { UserDefaults.standard.set(maskEnabled, forKey: "umbra.vault.mask") }
    }
    /// 允许 Face ID 解开软锁。
    @Published var faceIDEnabled: Bool {
        didSet { UserDefaults.standard.set(faceIDEnabled, forKey: "umbra.vault.faceID") }
    }
    /// Face ID 失败提示。
    @Published var faceError: String? = nil

    private var lastActivity = Date()
    private var ticker: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        autoLockMinutes = d.object(forKey: "umbra.vault.lockMin") as? Int ?? 10
        maskEnabled = d.object(forKey: "umbra.vault.mask") as? Bool ?? true
        faceIDEnabled = d.object(forKey: "umbra.vault.faceID") as? Bool ?? true
    }

    /// 设备上有没有 Face ID / Touch ID 可用。没有的话设置里那一项要说明原因，而不是给个点不动的开关。
    var biometryAvailable: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
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

    /// 有操作就往后推一次自动锁定。**每次交互都要调**，否则用户正在读密码时会被锁掉。
    func touch() { lastActivity = Date() }

    /// 开始计时。倒计时是真 tick（每 5 秒查一次），不是进页面时算一次。
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
                }
            }
        }
    }

    func stopAutoLock() {
        ticker?.cancel()
        ticker = nil
    }

    /// 用 Face ID 解开软锁。失败原因如实回传 —— 「没通过」和「不支持」是两回事。
    func unlockWithBiometry() {
        guard faceIDEnabled, biometryAvailable else {
            faceError = "这台设备没有可用的 \(biometryName)"
            return
        }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "用主密码解锁"
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: "解锁密码保险箱") { ok, error in
            Task { @MainActor in
                if ok {
                    self.faceError = nil
                    self.softLocked = false
                    self.touch()
                } else {
                    self.faceError = (error as NSError?)?.localizedDescription ?? "没有通过验证"
                }
            }
        }
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
        Circle()
            .strokeBorder(color, lineWidth: size >= 60 ? 5 : 3)
            .frame(width: size, height: size)
            .overlay(
                Text("\(score)")
                    .font(UmbraFont.mono(size >= 60 ? 24 : 15, .w600))
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
