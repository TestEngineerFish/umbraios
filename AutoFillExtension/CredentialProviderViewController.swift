// Umbra 的 AutoFill Credential Provider 扩展。
//
// **这个文件用来整个覆盖 Xcode 向导生成的 CredentialProviderViewController.swift。**
// 类名保持 CredentialProviderViewController 不变，这样向导生成的 MainInterface.storyboard
// 不用改就还认得它。向导生成的 Info.plist 也不用改。
//
// 系统在别的 App / Safari 的密码输入框上唤起它，用户挑一条，系统把账号密码填进去。
// 扩展是**独立进程**，和主 App 不共享内存，只共享代码 —— 所以它自己拉密文、自己解密。
//
// 需要一起加进这个 target 的文件（在 Xcode 右侧 Target Membership 里勾上；
// 路径按 2026-08 重组后的 Features 目录，旧注释里的 Views/ 路径已作废）：
//   UmbraiOS/Features/Vault/VaultCore.swift   加密内核 + 数据模型 + VaultStore + VaultKeychain
//   UmbraiOS/Networking/NetworkConfig.swift   服务端地址与 Token
//   UmbraiOS/DesignSystem/UmbraTokens.swift   颜色 / 字号 / 间距
// 别的设计系统文件不要勾 —— 扩展的内存上限很紧（约 120MB），能少带就少带。
// 编译若再报缺某个类型，把报错指向的那**一个**文件补勾进来即可，不要整包勾。
//
// 与主 App 的两点不同，都是扩展的硬约束：
//   1. **不共享 Keychain**。扩展和主 App 的默认 Keychain 访问组不一样，所以第一次用
//      要在这里也输一次 Secret Key，之后存进扩展自己的 Keychain。
//      （要做成共享，两个 target 都得加同一个 Keychain Sharing 组 —— 那会让主 App
//      已经存好的 Secret Key 读不到，用户要重输一次。这一版不做这个取舍。）
//   2. **每次都要输主密码**。主密码不保存、不上传，这条规则在扩展里同样成立。
import AuthenticationServices
import SwiftUI

// MARK: - 入口

class CredentialProviderViewController: ASCredentialProviderViewController {

    private var hosting: UIHostingController<UmbraAutoFillRoot>?
    /// 系统给的「当前在哪个网站/App 上要填」。用来把列表排到最相关的那几条。
    private var services: [ASCredentialServiceIdentifier] = []

    // MARK: 系统回调

    /// 用户点了「用 Umbra 填充」→ 展示可选列表。
    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        services = serviceIdentifiers
        mount(preselect: nil)
    }

    /// 系统希望**不弹界面**直接给一条。我们做不到 —— 必须先要主密码，
    /// 所以如实回 userInteractionRequired，系统会转而调 prepareInterfaceToProvideCredential。
    override func provideCredentialWithoutUserInteraction(for credentialIdentity: ASPasswordCredentialIdentity) {
        extensionContext.cancelRequest(
            withError: NSError(domain: ASExtensionErrorDomain,
                               code: ASExtensionError.userInteractionRequired.rawValue))
    }

    /// 用户在系统面板上直接点了某一条 → 解锁后填这一条。
    override func prepareInterfaceToProvideCredential(for credentialIdentity: ASPasswordCredentialIdentity) {
        mount(preselect: credentialIdentity.recordIdentifier)
    }

    // MARK: 装载界面

    private func mount(preselect: String?) {
        let root = UmbraAutoFillRoot(
            domain: Self.domain(from: services),
            preselect: preselect,
            onPick: { [weak self] user, password in
                self?.extensionContext.completeRequest(
                    withSelectedCredential: ASPasswordCredential(user: user, password: password))
            },
            onCancel: { [weak self] in
                self?.extensionContext.cancelRequest(
                    withError: NSError(domain: ASExtensionErrorDomain,
                                       code: ASExtensionError.userCanceled.rawValue))
            })

        let vc = UIHostingController(rootView: root)
        addChild(vc)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(vc.view)
        vc.didMove(toParent: self)
        hosting = vc
    }

    /// 从 serviceIdentifier 里取出域名。系统给的可能是完整 URL，也可能就是个域名。
    static func domain(from ids: [ASCredentialServiceIdentifier]) -> String {
        guard let raw = ids.first?.identifier, !raw.isEmpty else { return "" }
        if let host = URLComponents(string: raw)?.host, !host.isEmpty { return host }
        if let host = URLComponents(string: "https://" + raw)?.host, !host.isEmpty { return host }
        return raw
    }
}

// MARK: - 界面

struct UmbraAutoFillRoot: View {
    let domain: String
    /// 系统直接点了某一条时的记录 id。
    let preselect: String?
    let onPick: (String, String) -> Void
    let onCancel: () -> Void

    @StateObject private var store = VaultStore()
    @State private var password = ""
    @State private var secretKey = ""
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.unlocked { list } else { unlockPane }
        }
        .background(UmbraColor.bg.ignoresSafeArea())
        .task { await store.pullRecord() }
        .onAppear { if !domain.isEmpty { query = domain } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(UmbraColor.orange)
                .frame(width: 24, height: 24)
                .overlay(Text("U").font(UmbraFont.sans(13, .w650)).foregroundColor(.white))
            Text("Umbra · 密码填充")
                .font(UmbraFont.sans(15, .w600))
                .foregroundColor(UmbraColor.text)
            Spacer(minLength: 0)
            Button(action: onCancel) {
                Text("关闭")
                    .font(UmbraFont.sans(15, .w400))
                    .foregroundColor(UmbraColor.orange)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(UmbraColor.borderSoft).frame(height: 1)
        }
    }

    // MARK: 解锁

    private var unlockPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("填充前要先解锁。主密码不保存、不上传 —— 扩展里也一样。")
                    .font(UmbraFont.sans(13, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineSpacing(13 * 0.6)

                SecureField("主密码", text: $password)
                    .font(UmbraFont.mono(15))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UmbraColor.card))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(UmbraColor.border, lineWidth: 1))

                // 扩展有自己的 Keychain，第一次用要在这里也输一次 Secret Key。
                if !store.hasSecretKey {
                    TextField("Secret Key（第一次在填充面板里用要输一次）", text: $secretKey)
                        .font(UmbraFont.mono(13))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UmbraColor.card))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(UmbraColor.border, lineWidth: 1))
                }

                if !store.error.isEmpty {
                    Text(store.error)
                        .font(UmbraFont.sans(12.5, .w400))
                        .foregroundColor(UmbraColor.danger)
                        .lineSpacing(12.5 * 0.6)
                }

                Button {
                    Task { await store.unlock(password: password, secretKey: secretKey) }
                } label: {
                    Text(store.loading ? "解锁中…" : "解锁并填充")
                        .font(UmbraFont.sans(15, .w600))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(store.loading ? UmbraColor.faint : UmbraColor.orange))
                }
                .buttonStyle(.plain)
                .disabled(store.loading)
            }
            .padding(16)
        }
    }

    // MARK: 列表

    /// 有账号控件的记录才能填充；先按当前域名排，再按标题。
    private var candidates: [VItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let withAccount = store.items.filter { $0.blocks.contains { $0.type == "account" } }
        let scored = withAccount.map { it -> (VItem, Int) in
            let urls = it.blocks.filter { $0.type == "account" }
                .map { ($0.data["url"]?.string ?? "").lowercased() }
                .joined(separator: " ")
            var score = 0
            if !domain.isEmpty && urls.contains(domain.lowercased()) { score += 2 }
            if !q.isEmpty && (it.title.lowercased().contains(q) || urls.contains(q)) { score += 1 }
            return (it, score)
        }
        // 用户在搜索框打了字就只留命中的；没打字就全给，但相关的排前面。
        let pool = q.isEmpty ? scored : scored.filter { $0.1 > 0 }
        return pool.sorted { a, b in
            a.1 == b.1 ? a.0.title < b.0.title : a.1 > b.1
        }.map(\.0)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(domain.isEmpty ? "搜名称或网址" : "搜 \(domain)", text: $query)
                    .font(UmbraFont.sans(14, .w400))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled(true)
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UmbraColor.chip))

            Text(domain.isEmpty ? "全部可填充的记录" : "「\(domain)」的匹配项")
                .font(UmbraFont.sans(11.5, .w560))
                .foregroundColor(UmbraColor.faint)

            if candidates.isEmpty {
                Text(store.items.isEmpty
                     ? "这个身份库里还没有记录。"
                     : "没有匹配的记录。换个词，或者清空搜索看全部。")
                    .font(UmbraFont.sans(13, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { idx, it in
                            if idx > 0 {
                                Rectangle().fill(UmbraColor.borderSoft).frame(height: 1)
                            }
                            row(it)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UmbraColor.card))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(UmbraColor.border, lineWidth: 1))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .onAppear(perform: fillPreselectedIfPossible)
    }

    private func row(_ it: VItem) -> some View {
        let account = it.blocks.first { $0.type == "account" }
        let user = account?.data["username"]?.string ?? ""
        return Button {
            let pw = account?.data["password"]?.string ?? ""
            onPick(user, pw)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(UmbraColor.chip)
                    .frame(width: 28, height: 28)
                    .overlay(Text(String(it.title.prefix(1)))
                        .font(UmbraFont.sans(13, .w600))
                        .foregroundColor(UmbraColor.muted))
                VStack(alignment: .leading, spacing: 1) {
                    Text(it.title).font(UmbraFont.sans(14, .w560)).foregroundColor(UmbraColor.text)
                    Text(user.isEmpty ? "（没有账号）" : user)
                        .font(UmbraFont.mono(12))
                        .foregroundColor(UmbraColor.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("填充").font(UmbraFont.sans(12.5, .w560)).foregroundColor(UmbraColor.orange)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 系统直接点了某一条时：解锁成功后立刻填那条，不用再让用户点一次。
    private func fillPreselectedIfPossible() {
        guard let rid = preselect,
              let it = store.items.first(where: { $0.id == rid }),
              let account = it.blocks.first(where: { $0.type == "account" }) else { return }
        onPick(account.data["username"]?.string ?? "", account.data["password"]?.string ?? "")
    }
}
