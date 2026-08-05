// 密码保险箱 · 首页（上锁 / 解锁）、记录详情、记录编辑。
//
// 数据与加解密全部走既有的 VaultStore（VaultFeature.swift）—— 那套已经和电脑端互通，
// 这里只换界面。控件类型与电脑端一致：
//   account {username,password,url,otp} / secret {value} / field {value} /
//   text {value} / images {atts} / files {atts}
//
// 与设计稿的一处实质差异：设计稿的记录详情有一个**会跳数字的两步验证码**。
// 数据模型里的 otp 只是一个「含两步验证」的布尔标记，没有存 TOTP 密钥，
// 所以算不出验证码。这里如实显示「已启用 / 未启用两步验证」，不编一个跳动的假数字。
import SwiftUI
import UIKit

// MARK: - 首页

struct UmbraVaultHomeView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var session: UmbraVaultSession

    @State private var password = ""
    @State private var secretKey = ""
    @State private var query = ""
    /// "" 全部 / "fav" 收藏 / typeId
    @State private var cat = ""
    /// 主密码框的焦点。错误卡里的「用主密码解锁 / 重新输入」要能把键盘直接叫起来，
    /// 否则用户点完按钮还得再点一次输入框。
    @FocusState private var passwordFocused: Bool
    /// 识别中的呼吸/扫描线动画开关（上锁页出现即置 true，动画本身是 repeatForever）。
    @State private var breathing = false
    /// 连续输错主密码的次数。到第三次错误卡的第二段换成「只能用 Secret Key 恢复」。
    @State private var wrongPasswordCount = 0

    private var locked: Bool { !store.unlocked || session.softLocked }

    /// 解锁横条只闪 3 秒（用户点名：一直挂着占地方）。「立即上锁」在 ⋮ 面板里常驻。
    @State private var showUnlockedNote = false
    @State private var noteTask: Task<Void, Never>?

    var body: some View {
        Group {
            // 解锁态是 List 而不是 UmbraScreen 的 ScrollView：
            // 记录行的左滑动作（复制密码 / 删除）只有系统 List 给得出来。
            if locked {
                UmbraScreen { lockedBody }
            } else {
                unlockedList
            }
        }
        .navigationTitle("密码保险箱")
        .navigationBarTitleDisplayMode(.inline)
        // ＋ 与 ⋮ 只在解锁态出现 —— 上锁时点它们没有任何事情能做，
        // 摆在那里只会让人点了发现没反应。
        .toolbar {
            if !locked {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { addRecord() } label: { Image(systemName: "plus") }
                        .tint(UmbraColor.orange)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // ⋮ 面板每行带实时子值（几项待处理/几个分组/…），是「带说明的多动作」——
                    // 按规范留在底部弹层，不塞系统 Menu。
                    Button { session.touch(); router.present(moreSheet()) } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .tint(UmbraColor.orange)
                }
            }
        }
        .task { await store.pullRecord() }
        .onAppear {
            session.startAutoLock()
            autoScanIfNeeded()
            // 进来时就是解锁态（比如从别的页返回）也闪一下横条，提示自动锁还在计时。
            if !locked { flashUnlockedNote() }
        }
        .onDisappear {
            session.stopAutoLock()
            // 离开页面就把「这一趟已经自动识别过」的标记清掉，下次进来才会再自动刷一次。
            session.resetVisit()
        }
        // 上锁状态是异步变的（软锁到点、store 拉完数据才知道解没解开），
        // 只在 onAppear 判一次会漏掉「进来时还没上锁、几分钟后自动上锁」这一档。
        .onChange(of: locked) { _ in
            autoScanIfNeeded()
            if !locked { flashUnlockedNote() }
        }
    }

    /// 解锁那一刻亮 3 秒再自己收掉。重复解锁会重置计时（先取消上一个）。
    private func flashUnlockedNote() {
        noteTask?.cancel()
        withAnimation(UmbraMotion.push) { showUnlockedNote = true }
        noteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(UmbraMotion.push) { showUnlockedNote = false }
        }
    }
    // 一期这里有一套「返回时滚回上次看的那行」（scrollAnchor + lastOpenedRecordId）——
    // 那是自绘栈每次返回都重建页面逼出来的。系统 NavigationStack 返回时父页不重建，
    // 滚动位置天然保留，整套机制删掉。

    /// 进页面自动刷脸：延迟 420ms 再发起，让转场先走完 ——
    /// 页面还在滑动时弹系统识别面板，两个动画会打架，而且用户根本来不及看清。
    private func autoScanIfNeeded() {
        guard session.shouldAutoScan(unlocked: store.unlocked) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)
            // 这 420ms 里状态可能已经变了（比如用户手动输密码进去了），再确认一次。
            guard locked, session.faceState == .idle else { return }
            startScan()
        }
    }

    // MARK: 上锁态
    //
    // 状态机见「Face ID 解锁-实现说明」：idle / scanning / failed + fallbackOnly 旁路。
    // 结构自上而下：96 识别图标区 → 标题+副文 → 主密码框 → 错误卡 → 解锁按钮 →
    // 文字按钮 → 两行灰色链接。

    @ViewBuilder
    private var lockedBody: some View {
        VStack(spacing: 16) {
            faceIconArea

            VStack(spacing: 7) {
                Text(lockTitle)
                    .font(UmbraFont.sans(20, .w600))
                    .foregroundColor(UmbraColor.text)
                Text(lockSubtitle)
                    .font(UmbraFont.sans(13, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineSpacing(13 * 0.65)
                    .multilineTextAlignment(.center)
            }

            // 软锁时 AUK 还在内存里，只要证明是本人，不必再输主密码。
            if !session.softLocked {
                SecureField("主密码", text: $password)
                    .font(UmbraFont.mono(15))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .focused($passwordFocused)
                    .padding(.horizontal, 13)
                    .frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous).fill(UmbraColor.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous)
                            .strokeBorder(store.error.isEmpty ? UmbraColor.border : UmbraColor.danger, lineWidth: UmbraMetric.borderW)
                    )

                // 本机第一次解锁要 Secret Key（电脑端 Emergency Kit 里那串）。存过就不再问。
                if !store.hasSecretKey {
                    TextField("Secret Key（电脑端 Emergency Kit）", text: $secretKey)
                        .font(UmbraFont.mono(14))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 13)
                        .frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous).fill(UmbraColor.card))
                        .overlay(
                            RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous)
                                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                        )
                }
            }

            if let f = session.faceFailure, session.faceState == .failed { faceErrorCard(f) }
            if !store.error.isEmpty { errorCard(store.error) }

            if session.softLocked {
                UmbraButton(title: "解锁保险箱", kind: .primary, height: 52) { session.scanForSoftUnlock() }
                UmbraButton(title: "改用主密码（会完全上锁）", kind: .secondary, height: 48) {
                    store.lock()
                    session.markManualLock()
                }
            } else {
                UmbraButton(title: store.loading ? "解锁中…" : "解锁保险箱",
                            kind: store.loading ? .disabled : .primary, height: 52) {
                    submitPassword()
                }
                // 用不了就不摆这颗按钮。摆一个点了只会弹「已关掉」的按钮
                // 比不摆更糟 —— 用户会以为是自己操作不对。
                if faceUsable { textButton }
            }

            VStack(spacing: 9) {
                linkText("换了新设备？输入 Secret Key") { router.go(.vaultRecover) }
                linkText("还没有保险箱？看看怎么建") { router.go(.vaultCreate) }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
    }

    // MARK: 识别图标区
    //
    // 96×96 / 圆角 26，内含 56 的 Face ID 线性图标。底色与描边随状态过渡 .2s。
    // scanning 时呼吸（.55→1 透明度、.97→1.03 缩放，1.4s）+ 一条扫描线上下走（1.1s）。
    // 「看起来在动的东西必须真的在动」—— 这两个动效是自查清单里点名的。
    /// 这台设备、这个时刻，刷脸这条路走不走得通。
    /// 软锁只要验身份，不需要存过主密码；硬锁必须有存好的凭证才能把密码取回来。
    private var faceUsable: Bool {
        session.biometryAvailable && session.faceIDEnabled
            && (session.hasBiometricCredential || session.softLocked)
    }

    private var faceIconArea: some View {
        let scanning = session.faceState == .scanning
        let failed = session.faceState == .failed
        let bg = scanning ? UmbraColor.orangeSoft : (failed ? UmbraColor.warningSoft : UmbraColor.chip)
        let fg = scanning ? UmbraColor.orange : (failed ? UmbraColor.warning : UmbraColor.faint)
        // 刷脸走不通时画一把锁，不画 Face ID 图标 —— 画了就是在暗示「点我能刷脸」。
        let icon = faceUsable ? UmbraIconPath.faceId : UmbraIconPath.lock
        return Button(action: tapFaceIcon) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(bg)
                UmbraIcon(d: icon, size: 56, strokeWidth: 1.4)
                    .foregroundColor(fg)
                    .opacity(scanning && breathing ? 1 : (scanning ? 0.55 : 1))
                    .scaleEffect(scanning && breathing ? 1.03 : (scanning ? 0.97 : 1))
                    .animation(scanning
                               ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true)
                               : .default,
                               value: breathing)
                if scanning {
                    Capsule()
                        .fill(UmbraColor.orange)
                        .frame(height: 2)
                        .padding(.horizontal, 22)
                        .opacity(0.7)
                        .offset(y: breathing ? 18 : -18)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: breathing)
                }
            }
            .frame(width: 96, height: 96)
            .animation(UmbraMotion.tint, value: session.faceState)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(!faceUsable ? "保险箱已上锁"
                            : (failed ? "再识别一次" : "用\(session.biometryName)解锁"))
        .onAppear { breathing = true }
    }

    /// 点图标：scanning 时忽略；关掉 / 不支持各给自己的提示；其余发起识别。
    private func tapFaceIcon() {
        guard session.faceState != .scanning else { return }
        guard session.faceIDEnabled else {
            router.showToast("\(session.biometryName) 已在保险箱设置里关掉")
            return
        }
        guard session.biometryAvailable else {
            router.showToast("这台设备没有可用的 \(session.biometryName)")
            return
        }
        startScan()
    }

    /// 发起识别。软锁只验身份；硬锁验完还要把主密码取回来去解密。
    private func startScan() {
        if session.softLocked {
            session.scanForSoftUnlock()
        } else {
            guard session.hasBiometricCredential else {
                router.showToast("还没开启\(session.biometryName)解锁，先用主密码进一次")
                return
            }
            session.scanForPassword { pw in
                Task {
                    await store.unlock(password: pw, secretKey: "")
                    if store.unlocked {
                        session.markUnlocked()
                        router.showToast("\(session.biometryName) 通过，已解锁")
                    }
                }
            }
        }
    }

    private func submitPassword() {
        let attempted = password
        Task {
            await store.unlock(password: attempted, secretKey: secretKey)
            if store.unlocked {
                password = ""; secretKey = ""
                session.markUnlocked()
            } else {
                wrongPasswordCount += 1
            }
        }
    }

    // MARK: 上锁态文案（照搬规格，别改写）

    private var lockTitle: String {
        switch session.faceState {
        case .scanning: return "正在识别…"
        case .failed: return "\(session.biometryName) 没通过"
        case .idle: return session.softLocked ? "保险箱已自动上锁" : "保险箱已上锁"
        }
    }

    private var lockSubtitle: String {
        switch session.faceState {
        case .scanning: return "看一下屏幕就好"
        case .failed: return "点一下上面的图标再识别一次，或者输入主密码。"
        case .idle:
            if session.softLocked { return "\(session.autoLockMinutes) 分钟没动了，验证一下继续。" }
            if !session.faceIDEnabled {
                return "\(session.biometryName) 已关闭，输入主密码解锁。主密码不保存、不上传，忘记无法找回。"
            }
            if session.hasBiometricCredential {
                return "进来时会自动识别 \(session.biometryName)。也可以输入主密码，主密码存在这台设备的安全隔区里，不上传，忘记无法找回。"
            }
            return "用主密码解锁。主密码不保存、不上传，忘记无法找回。"
        }
    }

    private var textButton: some View {
        let label: String = {
            switch session.faceState {
            case .scanning: return "识别中…"
            case .failed: return "再识别一次"
            case .idle: return "用\(session.biometryName)解锁"
            }
        }()
        return Button(action: tapFaceIcon) {
            Text(label)
                .font(UmbraFont.sans(15, .w560))
                .foregroundColor(session.faceState == .scanning ? UmbraColor.faint : UmbraColor.orange)
                .frame(minHeight: UmbraMetric.tapMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.faceState == .scanning)
    }

    private func linkText(_ t: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t)
                .font(UmbraFont.sans(13, .w400))
                .foregroundColor(UmbraColor.muted)
                .frame(minHeight: UmbraMetric.tapMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 两种错误卡（都必须是三段式）

    /// 生物识别未通过（琥珀）。
    private func faceErrorCard(_ f: UmbraBiometricStore.Failure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                UmbraIcon(d: UmbraIconPath.alertTriangle, size: 14, strokeWidth: 2.1)
                Text("\(session.biometryName) 没通过").font(UmbraFont.sans(14.5, .w560))
            }
            .foregroundColor(UmbraColor.warning)
            Text(f.message)
                .font(UmbraFont.sans(13, .w400))
                .foregroundColor(UmbraColor.muted)
                .lineSpacing(13 * 0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 7) {
                UmbraButton(title: "再试一次", kind: .secondary, height: 40) { startScan() }
                UmbraButton(title: "用主密码解锁", kind: .secondary, height: 40) {
                    session.preferPassword()
                    passwordFocused = true
                }
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous).fill(UmbraColor.warningSoft))
    }

    /// 主密码错误 / 连接问题（砖红）。第三段按问题类型给不同按钮。
    private func errorCard(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                UmbraIcon(d: UmbraIconPath.xCircle, size: 15, strokeWidth: 2.1)
                Text("没能解锁").font(UmbraFont.sans(14.5, .w560))
            }
            .foregroundColor(UmbraColor.danger)
            Text(wrongPasswordCount >= 3 && !isConnectionProblem(why)
                 ? "已经错了 \(wrongPasswordCount) 次。忘记主密码只能用 Secret Key 恢复，Umbra 这边没有备份。"
                 : why)
                .font(UmbraFont.sans(13, .w400))
                .foregroundColor(UmbraColor.muted)
                .lineSpacing(13 * 0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 7) {
                if isConnectionProblem(why) {
                    UmbraButton(title: "去填连接", kind: .primary, height: 40) { router.go(.setConn) }
                    UmbraButton(title: "重新输入", kind: .secondary, height: 40) { clearPasswordError() }
                } else {
                    UmbraButton(title: "重新输入", kind: .secondary, height: 40) { clearPasswordError() }
                    UmbraButton(title: "用 Secret Key 恢复", kind: .secondary, height: 40) {
                        router.go(.vaultRecover)
                    }
                }
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous).fill(UmbraColor.dangerSoft))
    }

    private func clearPasswordError() {
        password = ""
        store.error = ""
        passwordFocused = true
    }

    /// 这条错误是「连接/令牌」还是「密码」。两类问题下一步要做的事完全不同，
    /// 给错按钮比不给按钮更糟（用户会照着按，然后发现没用）。
    private func isConnectionProblem(_ why: String) -> Bool {
        for k in ["令牌", "服务器", "连不上", "地址", "同步接口"] where why.contains(k) { return true }
        return false
    }

    // MARK: 解锁态

    /// 解锁态整页。顶部几张卡是透明背景的「假行」（不画行卡），
    /// 记录分组是真正的 List Section —— 记录行的左滑动作只有系统 List 给得出来。
    /// 一期底部那句 PBKDF2 说明删了：加密参数说明属于「保险箱设置 › 关于」，
    /// 不该天天挂在列表底下（用户点名去掉）。
    private var unlockedList: some View {
        let audit = UmbraVaultAudit(items: store.items)

        return List {
            Section {
                if showUnlockedNote {
                    unlockedNote.transition(.opacity)
                }
                if store.offline { offlineNote }
                profileCard

                UmbraSearchField(placeholder: "搜名称、账号或网址", text: $query)
                    .onChange(of: query) { _ in session.touch() }

                catRow

                // 安全体检压成**一行细摘要**放在这里，而不是列表底下那张大卡：
                // 它是「顺手看一眼」的东西，挡在记录前面会天天被略过，
                // 埋在最底下又等于没有 —— 记录多了根本滚不到。
                checkupLine(audit)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: UmbraMetric.sp2, leading: 0, bottom: UmbraMetric.sp2, trailing: 0))
            .listRowSeparator(.hidden)

            if rows.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            } else {
                ForEach(groups) { g in groupSection(g) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UmbraColor.bg)
        .scrollDismissesKeyboard(.interactively)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
    }

    private var unlockedNote: some View {
        HStack(spacing: 9) {
            UmbraIcon(d: UmbraIconPath.check, size: 15, strokeWidth: 2.2)
            Text("已解锁 · \(session.autoLockMinutes) 分钟后自动上锁")
                .font(UmbraFont.sans(12.5, .w560))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                store.lock()
                // 手动上锁 = 「我现在就要它锁上」。这一档**不自动刷脸**，
                // 否则刚点完上锁系统就把识别面板弹出来，等于没锁。
                session.markManualLock()
                router.showToast("已重新上锁")
            } label: {
                Text("立即上锁")
                    .font(UmbraFont.sans(12, .w560))
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(UmbraColor.success)
        .padding(.horizontal, UmbraMetric.sp4)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous).fill(UmbraColor.successSoft))
    }

    /// 离线提示。用的是本机那份密文缓存，能看能改，只是还没同步。
    /// 不说清楚的话，用户会以为在别的设备上改的东西没同步过来是 App 坏了。
    private var offlineNote: some View {
        HStack(alignment: .top, spacing: 9) {
            UmbraIcon(d: UmbraIconPath.alertTriangle, size: 15, strokeWidth: 2).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.pendingPush ? "离线 · 有改动还没同步上去" : "离线 · 看的是本机缓存")
                    .font(UmbraFont.sans(12.5, .w560))
                Text(store.pendingPush
                     ? "改动已经存在这台手机上了，连上网会自动补推。"
                     : "别的设备上的新改动要等联网后才看得到。")
                    .font(UmbraFont.sans(12, .w400))
                    .lineSpacing(12 * 0.55)
            }
            Spacer(minLength: 0)
            Button {
                Task {
                    await store.pullRecord()
                    await store.syncNow()
                }
            } label: {
                Text("重试")
                    .font(UmbraFont.sans(12.5, .w560))
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(UmbraColor.warning)
        .padding(.horizontal, UmbraMetric.sp4)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous).fill(UmbraColor.warningSoft))
    }

    private var currentVault: VVaultInfo? { store.vaults.first { $0.id == store.curVaultId } }

    private var profileCard: some View {
        Button { switchProfile() } label: {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous)
                    .fill(UmbraColor.orangeSoft)
                    .frame(width: 34, height: 34)
                    .overlay(
                        Text(String((currentVault?.name ?? "库").prefix(1)))
                            .font(UmbraFont.sans(15, .w600))
                            .foregroundColor(UmbraColor.orangeText)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentVault?.name ?? "默认库")
                        .font(UmbraFont.sans(16, .w560))
                        .foregroundColor(UmbraColor.text)
                    Text("当前身份库 · \(store.items.count) 条记录")
                        .font(UmbraFont.sans(12, .w400))
                        .foregroundColor(UmbraColor.faint)
                }
                Spacer(minLength: 0)
                Text("切换")
                    .font(UmbraFont.sans(13, .w560))
                    .foregroundColor(UmbraColor.orange)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                    .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func switchProfile() {
        session.touch()
        var items = store.vaults.map { v in
            UmbraSheetItem(label: v.name, checked: v.id == store.curVaultId) {
                store.switchVault(v.id)
                cat = ""
            }
        }
        items.append(UmbraSheetItem(label: "管理身份库") { router.go(.vaultProfiles) })
        router.present(UmbraSheet(title: "身份库",
                                  subtitle: "身份库之间数据隔离，同一时刻只有一个是当前库。",
                                  items: items))
    }

    private var catItems: [UmbraFilterChips<String>.Item] {
        var out: [UmbraFilterChips<String>.Item] = [
            .init(value: "", label: "全部", count: store.items.count),
            .init(value: "fav", label: "收藏", count: store.items.filter { $0.favorite == true }.count)
        ]
        for t in store.types {
            out.append(.init(value: t.id, label: t.name,
                             count: store.items.filter { $0.typeId == t.id }.count))
        }
        return out
    }

    private var catRow: some View {
        // List 行自带左右边距，胶囊排里不再垫 pagePadX（垫了就是双重缩进）。
        UmbraFilterChips(items: catItems, selection: $cat, edgeInset: 0)
    }

    private var rows: [VItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.items.filter { it in
            if cat == "fav" && it.favorite != true { return false }
            if !cat.isEmpty && cat != "fav" && it.typeId != cat { return false }
            guard !q.isEmpty else { return true }
            // **密码与密文不参与搜索** —— 搜索命中会把内容泄漏到列表副文里。
            var hay = [it.title] + (it.tags ?? [])
            for b in it.blocks where b.type == "account" {
                hay.append(b.data["username"]?.string ?? "")
                hay.append(b.data["url"]?.string ?? "")
            }
            return hay.joined(separator: " ").lowercased().contains(q)
        }
    }

    private struct RowGroup: Identifiable {
        let id: String
        let name: String
        let items: [VItem]
    }

    private var groups: [RowGroup] {
        var out: [RowGroup] = []
        let favs = rows.filter { $0.favorite == true }
        if cat.isEmpty && !favs.isEmpty {
            out.append(RowGroup(id: "fav", name: "收藏", items: favs))
        }
        for t in store.types {
            let items = rows.filter { $0.typeId == t.id }
            if !items.isEmpty { out.append(RowGroup(id: t.id, name: t.name, items: items)) }
        }
        // 分组被删掉但记录还在（跨端同步时可能出现）：兜到一个「未分组」里，别让记录凭空消失。
        let known = Set(store.types.map(\.id))
        let orphan = rows.filter { !known.contains($0.typeId) }
        if !orphan.isEmpty { out.append(RowGroup(id: "_orphan", name: "未分组", items: orphan)) }
        return out
    }

    /// 一个分组 = 一个 List Section（卡片、行分隔线交给系统），
    /// 每行挂系统左滑：复制密码（有密码才给）+ 删除（必进确认弹窗）。
    private func groupSection(_ g: RowGroup) -> some View {
        Section {
            ForEach(g.items) { it in
                recordRow(it)
                    .listRowBackground(UmbraColor.card)
                    .listRowInsets(EdgeInsets())
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // 不用 role: .destructive —— 带 role 系统会先把行划走，
                        // 确认弹窗点取消后行回不来（与提醒列表同一个坑）。
                        Button {
                            confirmDelete(it)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .tint(UmbraColor.danger)

                        if let p = passwordOf(it) {
                            Button {
                                session.touch()
                                UmbraClipboard.copySensitive(p)
                                router.showToast("已复制密码 · 60 秒后自动清除")
                            } label: {
                                Label("复制密码", systemImage: "doc.on.doc")
                            }
                            .tint(UmbraColor.orange)
                        }
                    }
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                UmbraFieldLabel(text: g.name)
                Spacer(minLength: 0)
                Text("\(g.items.count) 条")
                    .font(UmbraFont.mono(12))
                    .foregroundColor(UmbraColor.faint)
            }
            .textCase(nil)
        }
    }

    /// 账号块里的密码。左滑「复制密码」只在真有密码时出现 —— 摆一个点了没反应的动作最糟。
    private func passwordOf(_ it: VItem) -> String? {
        let p = it.blocks.first { $0.type == "account" }?.data["password"]?.string
        return (p?.isEmpty == false) ? p : nil
    }

    /// 删除确认。左滑和长按菜单共用这一份，文案只维护一处。
    private func confirmDelete(_ it: VItem) {
        session.touch()
        router.confirm(UmbraAlert(
            title: "删除「\(it.title)」？",
            body: "会同步删除到所有设备。这一版没有回收站，删了找不回来。",
            confirmLabel: "删除",
            confirmDestructive: true,
            onConfirm: {
                Task { await store.deleteItem(it.id) }
                router.showToast("已删除")
            }))
    }

    private func recordRow(_ it: VItem) -> some View {
        Button {
            session.touch()
            router.go(.vaultRecord(id: it.id))
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous)
                    .fill(UmbraColor.chip)
                    .frame(width: 34, height: 34)
                    .overlay(
                        Text(String(it.title.prefix(1)))
                            .font(UmbraFont.sans(15, .w600))
                            .foregroundColor(UmbraColor.muted)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(it.title)
                            .font(UmbraFont.sans(16, .w560))
                            .foregroundColor(UmbraColor.text)
                            .lineLimit(1)
                        if it.favorite == true {
                            UmbraIcon(d: UmbraIconPath.star, size: 13, strokeWidth: 2)
                                .foregroundColor(UmbraColor.orange)
                        }
                    }
                    Text(subtitle(it))
                        .font(UmbraFont.sans(13, .w400))
                        .foregroundColor(UmbraColor.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(typeName(it.typeId))
                    .font(UmbraFont.sans(11, .w600))
                    .foregroundColor(UmbraColor.faint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(UmbraColor.chip))
                UmbraIcon(d: UmbraIconPath.chevronRight, size: 16, strokeWidth: 2.2)
                    .foregroundColor(UmbraColor.faint)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onLongPressGesture { rowMenu(it) }
    }

    private func typeName(_ id: String) -> String {
        store.types.first { $0.id == id }?.name ?? "未分组"
    }

    /// 副文：优先显示账号，没有账号就显示分组。**永远不显示密码**。
    private func subtitle(_ it: VItem) -> String {
        for b in it.blocks where b.type == "account" {
            let u = b.data["username"]?.string ?? ""
            if !u.isEmpty { return u }
        }
        return typeName(it.typeId)
    }

    private func rowMenu(_ it: VItem) {
        session.touch()
        let account = it.blocks.first { $0.type == "account" }
        var items: [UmbraSheetItem] = []
        if let u = account?.data["username"]?.string, !u.isEmpty {
            items.append(UmbraSheetItem(label: "复制账号") {
                UmbraClipboard.copySensitive(u)
                router.showToast("已复制账号 · 60 秒后自动清除")
            })
        }
        if let p = account?.data["password"]?.string, !p.isEmpty {
            items.append(UmbraSheetItem(label: "复制密码") {
                UmbraClipboard.copySensitive(p)
                router.showToast("已复制密码 · 60 秒后自动清除")
            })
        }
        items.append(UmbraSheetItem(label: it.favorite == true ? "取消收藏" : "加入收藏") {
            Task { await store.toggleFav(it.id) }
        })
        items.append(UmbraSheetItem(label: "移动到分组") { movePicker(it) })
        items.append(UmbraSheetItem(label: "删除", destructive: true) { confirmDelete(it) })
        router.present(UmbraSheet(title: it.title, items: items))
    }

    private func movePicker(_ it: VItem) {
        router.present(UmbraSheet(title: "移动到分组", items: store.types.map { t in
            UmbraSheetItem(label: t.name, checked: t.id == it.typeId) {
                Task { await store.moveItem(it.id, to: t.id) }
                router.showToast("已移到「\(t.name)」")
            }
        }))
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Text(emptyTitle)
                .font(UmbraFont.sans(15, .w560))
                .foregroundColor(UmbraColor.text)
            Text(emptyBody)
                .font(UmbraFont.sans(13, .w400))
                .foregroundColor(UmbraColor.muted)
                .lineSpacing(13 * 0.65)
                .multilineTextAlignment(.center)
            UmbraButton(title: "存一条新的", kind: .primary, height: 44) { addRecord() }
                .frame(maxWidth: 160)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 34)
    }

    private var emptyTitle: String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { return "没有匹配「\(q)」的记录" }
        return store.items.isEmpty ? "还没有记录" : "这个分组下还没有记录"
    }

    private var emptyBody: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "加一条登录信息，工作流也能直接取用。"
            : "密码与密文内容不参与搜索，可以试试名称、账号或网址。"
    }

    private func addRecord() {
        session.touch()
        router.go(.vaultEdit(id: nil))
    }

    /// 安全体检的一行细摘要。左边一个 22 的小分数环，右边一句话，整行可点进详情。
    /// 有问题时数字用警示色，没问题时整行都是弱色 —— 不打扰。
    private func checkupLine(_ audit: UmbraVaultAudit) -> some View {
        Button {
            session.touch()
            router.go(.vaultCheck)
        } label: {
            HStack(spacing: 8) {
                UmbraScoreRing(score: audit.score, size: 22)
                Text("安全体检")
                    .font(UmbraFont.sans(13, .w560))
                    .foregroundColor(UmbraColor.muted)
                Text(audit.total == 0 ? "没有发现问题" : "\(audit.total) 项需要处理")
                    .font(UmbraFont.sans(13, .w400))
                    .foregroundColor(audit.total == 0 ? UmbraColor.faint : UmbraColor.warning)
                    .lineLimit(1)
                Spacer(minLength: 0)
                UmbraIcon(d: UmbraIconPath.chevronRight, size: 14, strokeWidth: 2.2)
                    .foregroundColor(UmbraColor.faint)
            }
            .frame(minHeight: UmbraMetric.tapMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 「⋮」动作面板
    //
    // 原来这些入口是列表**底下**的大卡与三行卡：记录一多就滚不到，
    // 而且它们和「翻记录」根本不是一件事，横在中间还挡路。
    // 收进导航栏的「⋮」里，每一行都带**当下的真实值**（几项待处理、几个分组、
    // 几分钟自动锁），不用点进去才知道现在是什么状态。
    private func moreSheet() -> UmbraSheet {
        let audit = UmbraVaultAudit(items: store.items)
        let vaultName = currentVault?.name ?? "默认库"
        let bio = session.faceIDEnabled && session.hasBiometricCredential
            ? "\(session.biometryName) 已开启"
            : "只用主密码"
        return UmbraSheet(
            title: "保险箱",
            subtitle: "\(store.items.count) 条记录 · \(vaultName)",
            items: [
                UmbraSheetItem(label: "安全体检",
                               note: audit.total == 0 ? "没有发现问题" : "\(audit.total) 项需要处理") {
                    session.touch(); router.go(.vaultCheck)
                },
                UmbraSheetItem(label: "密码生成器", note: "本机随机，不联网") {
                    session.touch(); router.go(.vaultGen)
                },
                UmbraSheetItem(label: "分组", note: "\(store.types.count) 个") {
                    session.touch(); router.go(.vaultGroups)
                },
                UmbraSheetItem(label: "身份库", note: "当前：\(vaultName) · 共 \(store.vaults.count) 个") {
                    session.touch(); router.go(.vaultProfiles)
                },
                UmbraSheetItem(label: "回收站", note: "这一版在电脑上") {
                    session.touch(); router.go(.vaultTrash)
                },
                UmbraSheetItem(label: "从别处导入", note: "这一版在电脑上") {
                    session.touch(); router.go(.vaultImport)
                },
                UmbraSheetItem(label: "保险箱设置",
                               note: "\(session.autoLockMinutes) 分钟自动锁定 · \(bio)") {
                    session.touch(); router.go(.vaultSettings)
                },
                // 解锁横条 3 秒就收起了，「立即上锁」得有个常驻入口 —— 收在这里。
                UmbraSheetItem(label: "立即上锁",
                               note: "\(session.autoLockMinutes) 分钟后也会自动锁") {
                    store.lock()
                    session.markManualLock()
                    router.showToast("已重新上锁")
                }
            ])
    }
}

// MARK: - 记录详情

struct UmbraVaultRecordView: View {
    let id: String

    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var session: UmbraVaultSession

    private var item: VItem? { store.items.first { $0.id == id } }

    var body: some View {
        UmbraScreen {
            if let it = item { content(it) } else { missing }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let it = item {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        session.touch()
                        Task { await store.toggleFav(it.id) }
                    } label: {
                        Image(systemName: it.favorite == true ? "star.fill" : "star")
                    }
                    .tint(it.favorite == true ? UmbraColor.orange : UmbraColor.faint)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("编辑") {
                        session.touch()
                        router.go(.vaultEdit(id: it.id))
                    }
                    .tint(UmbraColor.orange)
                }
            }
        }
        .onAppear { session.touch() }
    }

    private var missing: some View {
        UmbraEmptyState(iconPath: UmbraIconPath.lockKeyhole, title: "这条记录不在了",
                        hint: "可能是在别的设备上删掉了。", actionTitle: "回到保险箱",
                        action: { router.back() })
    }

    @ViewBuilder
    private func content(_ it: VItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(UmbraColor.orangeSoft)
                    .frame(width: UmbraMetric.iconBlockLG, height: UmbraMetric.iconBlockLG)
                    .overlay(
                        Text(String(it.title.prefix(1)))
                            .font(UmbraFont.sans(19, .w600))
                            .foregroundColor(UmbraColor.orangeText)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(it.title)
                        .font(UmbraFont.sans(20, .w600))
                        .foregroundColor(UmbraColor.text)
                    Text(store.types.first { $0.id == it.typeId }?.name ?? "未分组")
                        .font(UmbraFont.sans(13, .w400))
                        .foregroundColor(UmbraColor.muted)
                }
                Spacer(minLength: 0)
            }

            ForEach(it.blocks) { b in blockCard(b, item: it) }

            UmbraSettingSectionView(section: UmbraSettingSection(header: "记录信息", rows: [
                UmbraSettingRow(label: "创建", value: UmbraTime.absolute(iso(it.createdAt))),
                UmbraSettingRow(label: "更新", value: UmbraTime.absolute(iso(it.updatedAt)))
            ]))
            .padding(.horizontal, -UmbraMetric.pagePadX)

            Text("敏感值显示 8 秒后会自动重新遮盖；复制出来的内容 60 秒后自动清空剪贴板。删除请到右上角「编辑」里。")
                .font(UmbraFont.sans(12, .w400))
                .foregroundColor(UmbraColor.faint)
                .lineSpacing(12 * 0.65)
        }
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.top, UmbraMetric.pagePadX)
        .padding(.bottom, UmbraMetric.sp8)
    }

    private func iso(_ ms: Double) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    @ViewBuilder
    private func blockCard(_ b: VBlock, item: VItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                UmbraIcon(d: UmbraVaultBlock.icon(b.type), size: 14, strokeWidth: 1.9)
                    .foregroundColor(UmbraColor.faint)
                UmbraFieldLabel(text: b.label ?? UmbraVaultBlock.name(b.type))
            }
            VStack(spacing: 0) {
                ForEach(Array(fieldRows(b, item: item).enumerated()), id: \.offset) { idx, row in
                    if idx > 0 { UmbraRowDivider() }
                    row
                }
            }
            .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                    .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
            )
        }
    }

    /// 一个控件展开成若干字段行。
    private func fieldRows(_ b: VBlock, item: VItem) -> [AnyView] {
        switch b.type {
        case "account":
            var out: [AnyView] = [
                AnyView(UmbraFieldRow(label: "账号", value: b.data["username"]?.string ?? "", mono: true)),
                AnyView(UmbraFieldRow(label: "密码", value: b.data["password"]?.string ?? "",
                                      secret: true, showStrength: true))
            ]
            let url = b.data["url"]?.string ?? ""
            if !url.isEmpty { out.append(AnyView(UmbraFieldRow(label: "网址", value: url, mono: true))) }
            // 两步验证：数据模型里只有一个布尔标记，没有 TOTP 密钥，所以只能显示状态。
            // 设计稿那个会跳的 6 位数字要先在电脑端存下密钥才谈得上。
            out.append(AnyView(twoFactorRow(b.data["otp"]?.bool == true)))
            return out
        case "secret":
            return [AnyView(UmbraFieldRow(label: b.label ?? "密文", value: b.data["value"]?.string ?? "",
                                          secret: true, showStrength: true))]
        case "field":
            return [AnyView(UmbraFieldRow(label: b.label ?? "字段", value: b.data["value"]?.string ?? ""))]
        case "text":
            return [AnyView(UmbraFieldRow(label: b.label ?? "文本", value: b.data["value"]?.string ?? "",
                                          multiline: true))]
        case "images", "files":
            let ids = b.data["atts"]?.strings ?? []
            if ids.isEmpty {
                return [AnyView(UmbraFieldRow(label: b.label ?? "附件", value: ""))]
            }
            return ids.map { aid in
                AnyView(UmbraFieldRow(label: b.type == "images" ? "图片" : "文件",
                                      value: store.attName(aid), mono: false))
            }
        default:
            return [AnyView(UmbraFieldRow(label: b.label ?? b.type, value: ""))]
        }
    }

    private func twoFactorRow(_ on: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                UmbraFieldLabel(text: "两步验证")
                HStack(spacing: 5) {
                    UmbraIcon(d: on ? UmbraIconPath.shieldCheck : UmbraIconPath.shield,
                              size: 13, strokeWidth: 2)
                    Text(on ? "已启用两步验证 (2FA)" : "未启用")
                        .font(UmbraFont.sans(15, .w400))
                }
                .foregroundColor(on ? UmbraColor.success : UmbraColor.muted)
                if on {
                    Text("验证码要在存了密钥的那台设备上看 —— 这条记录里只存了「已启用」这个标记。")
                        .font(UmbraFont.sans(11.5, .w400))
                        .foregroundColor(UmbraColor.faint)
                        .lineSpacing(11.5 * 0.5)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }
}

// MARK: - 控件类型元数据

enum UmbraVaultBlock {
    /// 可添加的控件类型，与电脑端一致（account / secret / field / text / images / files）。
    static let all: [(type: String, name: String)] = [
        ("account", "账号"), ("secret", "密文"), ("field", "字段"),
        ("text", "文本"), ("images", "图片"), ("files", "文件")
    ]

    static func name(_ type: String) -> String {
        all.first { $0.type == type }?.name ?? type
    }

    static func icon(_ type: String) -> String {
        switch type {
        case "account": return UmbraIconPath.user
        case "secret": return UmbraIconPath.key
        case "field": return UmbraIconPath.textLines
        case "text": return UmbraIconPath.messageText
        case "images": return UmbraIconPath.image
        case "files": return UmbraIconPath.file
        default: return UmbraIconPath.file
        }
    }

    /// 新建一个空控件。字段形状必须和电脑端一致，否则两端读同一条记录会缺字段。
    static func make(_ type: String) -> VBlock {
        let data: [String: VJSON]
        switch type {
        case "account":
            data = ["username": VJSON(.s("")), "password": VJSON(.s("")),
                    "url": VJSON(.s("")), "otp": VJSON(.b(false))]
        case "images", "files":
            data = ["atts": VJSON(.a([]))]
        default:
            data = ["value": VJSON(.s(""))]
        }
        return VBlock(id: "b" + UUID().uuidString.prefix(8).lowercased(),
                      type: type, label: name(type), data: data)
    }
}

// MARK: - 记录编辑

struct UmbraVaultEditView: View {
    /// nil = 新建
    let id: String?

    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var session: UmbraVaultSession

    @State private var title = ""
    @State private var typeId = ""
    @State private var blocks: [VBlock] = []
    @State private var loaded = false

    private var existing: VItem? { id.flatMap { rid in store.items.first { $0.id == rid } } }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        UmbraScreen(content: {
            VStack(alignment: .leading, spacing: UmbraMetric.sp5) {
                field("名称") {
                    input("例如「GitHub」", text: $title)
                }

                UmbraSettingSectionView(section: UmbraSettingSection(rows: [
                    UmbraSettingRow(label: "分组", value: groupName, chevron: true) { pickGroup() }
                ]))
                .padding(.horizontal, -UmbraMetric.pagePadX)

                ForEach(Array(blocks.enumerated()), id: \.element.id) { idx, b in
                    blockEditor(idx: idx, block: b)
                }

                Button { addBlock() } label: {
                    Text("添加控件")
                        .font(UmbraFont.sans(15.5, .w560))
                        .foregroundColor(UmbraColor.orange)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                .foregroundColor(UmbraColor.border)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !canSave {
                    Text("名称还是空的，写一个才能存。")
                        .font(UmbraFont.sans(12, .w400))
                        .foregroundColor(UmbraColor.faint)
                }

                Text("图片与文件附件要在电脑上添加 —— 手机端只做查看。控件顺序按添加顺序排。")
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(UmbraColor.faint)
                    .lineSpacing(12 * 0.65)

                if let it = existing {
                    UmbraButton(title: "删除这条记录", kind: .dangerOutline) {
                        router.confirm(UmbraAlert(
                            title: "删除「\(it.title)」？",
                            body: "会同步删除到所有设备。这一版没有回收站，删了找不回来。",
                            confirmLabel: "删除",
                            confirmDestructive: true,
                            onConfirm: {
                                Task { await store.deleteItem(it.id) }
                                router.back()
                                router.showToast("已删除")
                            }))
                    }
                }
            }
            .padding(UmbraMetric.pagePadX)
        })
        .navigationTitle(id == nil ? "存一条新的" : "编辑记录")
        .navigationBarTitleDisplayMode(.inline)
        // 左上角是「取消」不是返回箭头 —— 放弃这次编辑，不是回上一页。
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { router.back() }
                    .tint(UmbraColor.text)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { save() } label: {
                    Text("保存").font(UmbraFont.sans(16, .w600))
                }
                .tint(canSave ? UmbraColor.orange : UmbraColor.faint)
            }
        }
        .onAppear {
            session.touch()
            guard !loaded else { return }
            loaded = true
            if let it = existing {
                title = it.title; typeId = it.typeId; blocks = it.blocks
            } else {
                typeId = store.types.first?.id ?? ""
                blocks = [UmbraVaultBlock.make("account")]
            }
        }
    }

    private var groupName: String {
        store.types.first { $0.id == typeId }?.name ?? "未分组"
    }

    private func pickGroup() {
        router.present(UmbraSheet(title: "分组", items: store.types.map { t in
            UmbraSheetItem(label: t.name, checked: t.id == typeId) { typeId = t.id }
        }))
    }

    private func addBlock() {
        router.present(UmbraSheet(
            title: "添加控件",
            subtitle: "图片与文件只能在电脑上添加，这里加了也是空的。",
            items: UmbraVaultBlock.all.map { t in
                UmbraSheetItem(label: t.name) { blocks.append(UmbraVaultBlock.make(t.type)) }
            }))
    }

    @ViewBuilder
    private func blockEditor(idx: Int, block b: VBlock) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                UmbraIcon(d: UmbraVaultBlock.icon(b.type), size: 14, strokeWidth: 1.9)
                    .foregroundColor(UmbraColor.faint)
                UmbraFieldLabel(text: b.label ?? UmbraVaultBlock.name(b.type))
                Spacer(minLength: 0)
                Button {
                    blocks.remove(at: idx)
                } label: {
                    Text("移除")
                        .font(UmbraFont.sans(12.5, .w560))
                        .foregroundColor(UmbraColor.danger)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 10) {
                switch b.type {
                case "account":
                    editField("账号", idx: idx, key: "username", mono: true)
                    editField("密码", idx: idx, key: "password", mono: true, secure: true)
                    editField("网址", idx: idx, key: "url", mono: true)
                    Toggle(isOn: boolBinding(idx: idx, key: "otp")) {
                        Text("含两步验证 (2FA)")
                            .font(UmbraFont.sans(15, .w400))
                            .foregroundColor(UmbraColor.text)
                    }
                    .tint(UmbraColor.orange)
                case "images", "files":
                    Text(attachmentNote(b))
                        .font(UmbraFont.sans(13, .w400))
                        .foregroundColor(UmbraColor.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case "text":
                    editField(b.label ?? "文本", idx: idx, key: "value", multiline: true)
                default:
                    editField(b.label ?? UmbraVaultBlock.name(b.type), idx: idx, key: "value",
                              mono: b.type == "secret", secure: b.type == "secret")
                }
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                    .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
            )
        }
    }

    private func attachmentNote(_ b: VBlock) -> String {
        let n = (b.data["atts"]?.strings ?? []).count
        return n == 0 ? "还没有附件。附件要在电脑上添加。" : "有 \(n) 个附件，在详情页查看。附件要在电脑上增删。"
    }

    @ViewBuilder
    private func editField(_ label: String, idx: Int, key: String,
                           mono: Bool = false, secure: Bool = false, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: UmbraMetric.sp2) {
            UmbraFieldLabel(text: label)
            // 密码用普通输入框而不是 SecureField：编辑时看不见自己在打什么最容易出错，
            // 而这一屏本来就在解锁态里。真正要遮的是**详情页**的展示，那里做了遮罩 + 8 秒自动盖回。
            if multiline {
                TextField("", text: stringBinding(idx: idx, key: key), axis: .vertical)
                    .font(mono ? UmbraFont.mono(15) : UmbraFont.sans(15, .w400))
                    .lineLimit(3...)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .frame(minHeight: 88, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous).fill(UmbraColor.bg))
                    .overlay(
                        RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous)
                            .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                    )
            } else {
                HStack(spacing: 8) {
                    TextField("", text: stringBinding(idx: idx, key: key))
                        .font(mono ? UmbraFont.mono(15) : UmbraFont.sans(15, .w400))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .textFieldStyle(.plain)
                    if secure {
                        // 就地生成，**不跳到生成器页** —— 跳走再回来这一页的编辑状态会重建，
                        // 用户刚填的东西全没了。生成器页留着单独用。
                        Button { stringBinding(idx: idx, key: key).wrappedValue = UmbraPasswordGen.make(.init()) } label: {
                            Text("生成")
                                .font(UmbraFont.sans(12.5, .w560))
                                .foregroundColor(UmbraColor.orange)
                                .frame(minHeight: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous).fill(UmbraColor.bg))
                .overlay(
                    RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous)
                        .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                )
            }
        }
    }

    private func stringBinding(idx: Int, key: String) -> Binding<String> {
        Binding(
            get: { idx < blocks.count ? (blocks[idx].data[key]?.string ?? "") : "" },
            set: { v in
                guard idx < blocks.count else { return }
                blocks[idx].data[key] = VJSON(.s(v))
                session.touch()
            })
    }

    private func boolBinding(idx: Int, key: String) -> Binding<Bool> {
        Binding(
            get: { idx < blocks.count ? (blocks[idx].data[key]?.bool ?? false) : false },
            set: { v in
                guard idx < blocks.count else { return }
                blocks[idx].data[key] = VJSON(.b(v))
                session.touch()
            })
    }

    @ViewBuilder
    private func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: UmbraMetric.sp2) {
            UmbraFieldLabel(text: label)
            content()
        }
    }

    private func input(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(UmbraFont.sans(16, .w400))
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(UmbraColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
            )
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var item = existing ?? VItem(id: "i" + UUID().uuidString.prefix(10).lowercased(),
                                     typeId: typeId, title: t, icon: nil, favorite: false,
                                     tags: [], blocks: [], attachments: [],
                                     createdAt: 0, updatedAt: 0, revision: 0, deleted: false)
        item.title = t
        item.typeId = typeId
        item.blocks = blocks
        Task { await store.saveItem(item) }
        router.back()
        router.showToast("已存下")
    }
}
