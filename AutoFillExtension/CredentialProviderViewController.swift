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
//   UmbraiOS/Features/Vault/VaultCore.swift       加密内核 + 数据模型 + VaultStore + VaultKeychain
//   UmbraiOS/Features/Vault/VaultSharing.swift    App Group 配置 + 共享 Keychain 访问组
//   UmbraiOS/Features/Vault/VaultBiometrics.swift Face ID 取回主密码
//   UmbraiOS/Networking/NetworkConfig.swift       服务端地址与 Token
//   UmbraiOS/DesignSystem/UmbraTokens.swift       颜色 / 字号 / 间距
// 别的设计系统文件不要勾 —— 扩展的内存上限很紧（约 120MB），能少带就少带。
// 编译若再报缺某个类型，把报错指向的那**一个**文件补勾进来即可，不要整包勾。
//
// 与主 App 共享了什么（2026-08 修订，之前那两条「要重输一次」的取舍已经解决）：
//   1. **配置走 App Group**：服务端地址与访问令牌主 App 填过就行，这里不再问。
//   2. **密钥走共享 Keychain 访问组**：Secret Key 主 App 存过就能直接用；
//      开了 Face ID 的话这里也能刷脸解锁 —— 取回的是同一条生物识别保护的主密码。
//   3. 没开 Face ID 时仍然每次输主密码：**主密码不保存、不上传**这条规则不变，
//      开 Face ID 等于明确接受「主密码存在本机安全隔区里」，那是用户自己的选择。
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
        view.addSubview(vc.view)
        // 用约束贴满四边，**不用** frame + autoresizingMask：
        // 系统是在装载之后才把填充面板拉到最终高度的，按装载那一刻的 bounds 定死，
        // 面板长高后内容就吊在中间、上下留一片空白（用户实测点名）。
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: view.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
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
    /// 分类筛选："" 全部 / "fav" 收藏 / typeId。
    @State private var cat = ""
    /// 生物识别正在弹窗 / 刚失败的说明。开了 Face ID 才有这一路。
    @State private var faceScanning = false
    @State private var faceNote = ""
    /// 这次进面板已经自动刷过一次脸了。不置这个标记的话，
    /// 用户点「取消」之后 onAppear 会再弹一次，成了甩不掉的弹窗。
    @State private var faceTried = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.unlocked { list } else { unlockPane }
        }
        // 内容不够高时也要顶到上边、底色铺满整屏 —— 否则短列表会浮在面板中间。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(UmbraColor.bg.ignoresSafeArea())
        .task {
            await store.pullRecord()
            // 拉完密文再刷脸：解锁需要密文在手，顺序反了会「脸过了却没东西可解」。
            autoScanIfNeeded()
        }
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
                Text(faceAvailable
                     ? "填充前要先解锁。可以刷脸，也可以输主密码。"
                     : "填充前要先解锁。主密码不保存、不上传 —— 扩展里也一样。")
                    .font(UmbraFont.sans(13, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineSpacing(13 * 0.6)

                // 主 App 里开过 Face ID 才给这颗按钮 —— 没开的话点了只会报「没存过凭证」，
                // 摆一个点了必然失败的按钮比不摆更糟。
                if faceAvailable {
                    Button { startFace() } label: {
                        Text(faceScanning ? "识别中…" : "用 Face ID 解锁")
                            .font(UmbraFont.sans(15, .w600))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(faceScanning ? UmbraColor.faint : UmbraColor.orange))
                    }
                    .buttonStyle(.plain)
                    .disabled(faceScanning)

                    if !faceNote.isEmpty {
                        Text(faceNote)
                            .font(UmbraFont.sans(12.5, .w400))
                            .foregroundColor(UmbraColor.warning)
                            .lineSpacing(12.5 * 0.6)
                    }

                    Text("或者输入主密码")
                        .font(UmbraFont.sans(12, .w400))
                        .foregroundColor(UmbraColor.faint)
                        .padding(.top, 2)
                }

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
                        // 有 Face ID 那颗橙按钮时，这颗降成次要样式 —— 一屏一个橙实底。
                        .foregroundColor(faceAvailable ? UmbraColor.text : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(faceAvailable ? UmbraColor.card
                                      : (store.loading ? UmbraColor.faint : UmbraColor.orange))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(faceAvailable ? UmbraColor.border : .clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(store.loading)
            }
            .padding(16)
        }
    }

    // MARK: Face ID
    //
    // 取回的是主 App 存进共享 Keychain 的那条主密码（生物识别保护），
    // 拿到之后走和手输一模一样的 unlock —— 加解密链路一行没变。

    /// 主 App 里开过 Face ID 才显示这条路。
    private var faceAvailable: Bool { UmbraBiometricStore.hasCredential }

    /// 进面板自动刷一次脸。只自动一次，用户取消了就不再纠缠。
    private func autoScanIfNeeded() {
        guard faceAvailable, !faceTried, !store.unlocked else { return }
        startFace()
    }

    private func startFace() {
        guard !faceScanning else { return }
        faceTried = true
        faceScanning = true
        faceNote = ""
        UmbraBiometricStore.load(reason: "解锁 Umbra 保险箱以填充密码") { result in
            faceScanning = false
            switch result {
            case .success(let pw):
                Task { await store.unlock(password: pw, secretKey: "") }
            case .failure(let f):
                // 失败不挡路：说清楚原因，主密码那条路一直开着。
                faceNote = f.message
            }
        }
    }

    // MARK: 列表

    /// 分类筛选项：全部 / 收藏 / 各分组。只列**真的有可填充记录**的分组 ——
    /// 摆一个点了必然空列表的分类没有意义。
    private var catItems: [(key: String, label: String, count: Int)] {
        let pool = store.items.filter { $0.blocks.contains { $0.type == "account" } }
        var out: [(String, String, Int)] = [("", "全部", pool.count)]
        let favs = pool.filter { $0.favorite == true }.count
        if favs > 0 { out.append(("fav", "收藏", favs)) }
        for t in store.types {
            let n = pool.filter { $0.typeId == t.id }.count
            if n > 0 { out.append((t.id, t.name, n)) }
        }
        return out
    }

    private var catRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(catItems, id: \.key) { item in
                    let on = cat == item.key
                    Button { cat = item.key } label: {
                        HStack(spacing: 4) {
                            Text(item.label).font(UmbraFont.sans(12.5, on ? .w560 : .w400))
                            Text("\(item.count)").font(UmbraFont.mono(11)).opacity(0.75)
                        }
                        .foregroundColor(on ? UmbraColor.orangeText : UmbraColor.muted)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(on ? UmbraColor.orangeSoft : UmbraColor.card))
                        .overlay(Capsule().strokeBorder(on ? UmbraColor.orange : UmbraColor.border, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 有账号控件的记录才能填充；先按当前域名排，再按标题。
    private var candidates: [VItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var withAccount = store.items.filter { $0.blocks.contains { $0.type == "account" } }
        // 分类先过一道：收藏 / 某个分组。
        if cat == "fav" { withAccount = withAccount.filter { $0.favorite == true } }
        else if !cat.isEmpty { withAccount = withAccount.filter { $0.typeId == cat } }
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

            // 分类只有「全部」一项时不画 —— 一个选项的筛选器是纯占地方。
            if catItems.count > 1 { catRow }

            Text(listCaption)
                .font(UmbraFont.sans(11.5, .w560))
                .foregroundColor(UmbraColor.faint)

            if candidates.isEmpty {
                // 空态吃满剩下的高度：不撑开的话面板底下会空出一大片没底色的区域。
                Text(emptyText)
                    .font(UmbraFont.sans(13, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineSpacing(13 * 0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 20)
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
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear(perform: fillPreselectedIfPossible)
    }

    /// 列表小标题：跟着当前筛选走，别永远写「全部」。
    private var listCaption: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "搜索结果" }
        if cat == "fav" { return "收藏" }
        if let t = store.types.first(where: { $0.id == cat }) { return t.name }
        return domain.isEmpty ? "全部可填充的记录" : "「\(domain)」的匹配项"
    }

    /// 空态文案分三种情况说清楚，别一句「没有记录」打发。
    private var emptyText: String {
        if store.items.isEmpty { return "这个身份库里还没有记录。" }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "没有匹配的记录。换个词，或者清空搜索看全部。"
        }
        if !cat.isEmpty { return "这个分类下没有可填充的记录。点「全部」看看别的。" }
        return "没有带账号的记录 —— 只有含账号控件的记录才能用来填充。"
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
