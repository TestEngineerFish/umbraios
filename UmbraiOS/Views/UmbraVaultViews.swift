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

    private var locked: Bool { !store.unlocked || session.softLocked }

    var body: some View {
        UmbraPage(navBar: {
            UmbraNavBar(backLabel: "我", title: "密码保险箱", onBack: { router.back() })
        }, content: {
            if locked { lockedBody } else { unlockedBody }
        })
        .task { await store.pullRecord() }
        .onAppear { session.startAutoLock() }
        .onDisappear { session.stopAutoLock() }
    }

    // MARK: 上锁态

    @ViewBuilder
    private var lockedBody: some View {
        VStack(spacing: 16) {
            UmbraIcon(d: UmbraIconPath.faceId, size: 56, strokeWidth: 1.4)
                .foregroundColor(session.faceIDEnabled && session.biometryAvailable ? UmbraColor.orange : UmbraColor.faint)
                .padding(.top, 30)

            VStack(spacing: 7) {
                Text(session.softLocked ? "保险箱已自动上锁" : "保险箱已上锁")
                    .font(UmbraFont.sans(20, .w600))
                    .foregroundColor(UmbraColor.text)
                Text(session.softLocked
                     ? "\(session.autoLockMinutes) 分钟没动了，验证一下继续。"
                     : "用主密码解锁。主密码不保存、不上传，忘记无法找回。")
                    .font(UmbraFont.sans(13, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineSpacing(13 * 0.65)
                    .multilineTextAlignment(.center)
            }

            // 软锁只要验证身份，不必再输主密码 —— AUK 还在内存里。
            if session.softLocked {
                if session.faceIDEnabled && session.biometryAvailable {
                    UmbraButton(title: "用 \(session.biometryName) 解锁", kind: .primary, height: 52) {
                        session.unlockWithBiometry()
                    }
                }
                if let e = session.faceError { faceErrorCard(e) }
                UmbraButton(title: "改用主密码（会完全上锁）", kind: .secondary, height: 48) {
                    store.lock()
                    session.softLocked = false
                    session.faceError = nil
                }
            } else {
                SecureField("主密码", text: $password)
                    .font(UmbraFont.mono(15))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 13)
                    .frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous).fill(UmbraColor.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous)
                            .strokeBorder(store.error.isEmpty ? UmbraColor.border : UmbraColor.danger, lineWidth: UmbraMetric.borderW)
                    )

                // 本机第一次解锁要 Secret Key（电脑端的 Emergency Kit 里那串）。
                // 存过一次之后进 Keychain，就不再问了。
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

                if !store.error.isEmpty { errorCard(store.error) }

                UmbraButton(title: store.loading ? "解锁中…" : "解锁保险箱",
                            kind: store.loading ? .disabled : .primary, height: 52) {
                    Task {
                        await store.unlock(password: password, secretKey: secretKey)
                        if store.unlocked { password = ""; secretKey = ""; session.touch() }
                    }
                }

                VStack(spacing: 9) {
                    linkText("换了新设备？输入 Secret Key") { router.go(.vaultRecover) }
                    linkText("还没有保险箱？看看怎么建") { router.go(.vaultCreate) }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity)
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

    /// 解锁失败走错误三段式：发生了什么 → 为什么 → 现在能做什么。
    /// store.error 已经是「为什么」那一段（令牌不对 / 连不上 / 主密码不对…），
    /// 第三段是两个真按钮，不是一句「请重试」。
    private func errorCard(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                UmbraIcon(d: UmbraIconPath.xCircle, size: 15, strokeWidth: 2.1)
                Text("没能解锁").font(UmbraFont.sans(14.5, .w560))
            }
            .foregroundColor(UmbraColor.danger)
            Text(why)
                .font(UmbraFont.sans(13, .w400))
                .foregroundColor(UmbraColor.muted)
                .lineSpacing(13 * 0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 7) {
                UmbraButton(title: "重新输入", kind: .secondary, height: 40) {
                    password = ""
                    store.error = ""
                }
                UmbraButton(title: "用 Secret Key 恢复", kind: .secondary, height: 40) {
                    router.go(.vaultRecover)
                }
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous).fill(UmbraColor.dangerSoft))
    }

    private func faceErrorCard(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                UmbraIcon(d: UmbraIconPath.alertTriangle, size: 15, strokeWidth: 2.1)
                Text("\(session.biometryName) 没通过").font(UmbraFont.sans(14.5, .w560))
            }
            .foregroundColor(UmbraColor.warning)
            Text(why)
                .font(UmbraFont.sans(13, .w400))
                .foregroundColor(UmbraColor.muted)
                .lineSpacing(13 * 0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
            UmbraButton(title: "再试一次", kind: .secondary, height: 40) {
                session.unlockWithBiometry()
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous).fill(UmbraColor.warningSoft))
    }

    // MARK: 解锁态

    @ViewBuilder
    private var unlockedBody: some View {
        let audit = UmbraVaultAudit(items: store.items)

        VStack(alignment: .leading, spacing: UmbraMetric.sp4) {
            unlockedNote
            profileCard

            UmbraSearchField(placeholder: "搜名称、账号或网址", text: $query)
                .onChange(of: query) { _ in session.touch() }

            catRow

            if rows.isEmpty {
                emptyState
            } else {
                ForEach(groups) { g in groupCard(g) }
            }

            checkupCard(audit)
            toolsCard

            if !store.items.isEmpty {
                Button { addRecord() } label: {
                    Text("存一条新的")
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
            }

            Text("主密码派生走 PBKDF2-SHA256，参数与电脑端一致，两端能互相解开同一份密文。复制出来的内容 60 秒后自动清空剪贴板。")
                .font(UmbraFont.sans(12, .w400))
                .foregroundColor(UmbraColor.faint)
                .lineSpacing(12 * 0.65)
        }
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.top, UmbraMetric.sp5)
        .padding(.bottom, UmbraMetric.sp7)
    }

    private var unlockedNote: some View {
        HStack(spacing: 9) {
            UmbraIcon(d: UmbraIconPath.check, size: 15, strokeWidth: 2.2)
            Text("已解锁 · \(session.autoLockMinutes) 分钟后自动上锁")
                .font(UmbraFont.sans(12.5, .w560))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                store.lock()
                session.softLocked = false
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
        UmbraFilterChips(items: catItems, selection: $cat)
            .padding(.horizontal, -UmbraMetric.pagePadX)   // 抵消外层的 16，胶囊要贴边横滑
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

    private func groupCard(_ g: RowGroup) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                UmbraFieldLabel(text: g.name)
                Spacer(minLength: 0)
                Text("\(g.items.count) 条")
                    .font(UmbraFont.mono(12))
                    .foregroundColor(UmbraColor.faint)
            }
            VStack(spacing: 0) {
                ForEach(Array(g.items.enumerated()), id: \.element.id) { idx, it in
                    if idx > 0 { UmbraRowDivider() }
                    recordRow(it)
                }
            }
            .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                    .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
            )
        }
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
        items.append(UmbraSheetItem(label: "删除", destructive: true) {
            router.confirm(UmbraAlert(
                title: "删除「\(it.title)」？",
                body: "会同步删除到所有设备。这一版没有回收站，删了找不回来。",
                confirmLabel: "删除",
                confirmDestructive: true,
                onConfirm: {
                    Task { await store.deleteItem(it.id) }
                    router.showToast("已删除")
                }))
        })
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

    private func checkupCard(_ audit: UmbraVaultAudit) -> some View {
        Button {
            session.touch()
            router.go(.vaultCheck)
        } label: {
            HStack(spacing: 13) {
                UmbraScoreRing(score: audit.score, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("安全体检")
                        .font(UmbraFont.sans(16, .w560))
                        .foregroundColor(UmbraColor.text)
                    Text(audit.total == 0 ? "没有发现问题 · 只在本机计算，不上传"
                                          : "\(audit.total) 项需要处理 · 只在本机计算，不上传")
                        .font(UmbraFont.sans(13, .w400))
                        .foregroundColor(UmbraColor.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                UmbraIcon(d: UmbraIconPath.chevronRight, size: 16, strokeWidth: 2.2)
                    .foregroundColor(UmbraColor.faint)
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                    .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var toolsCard: some View {
        VStack(spacing: 0) {
            toolRow(UmbraIconPath.key, "密码生成器", nil) { router.go(.vaultGen) }
            UmbraRowDivider()
            toolRow(UmbraIconPath.trash, "回收站", "在电脑上") { router.go(.vaultTrash) }
            UmbraRowDivider()
            toolRow(UmbraIconPath.settings, "保险箱设置", "\(session.autoLockMinutes) 分钟自动锁定") { router.go(.vaultSettings) }
        }
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
        .overlay(
            RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
        )
    }

    private func toolRow(_ icon: String, _ label: String, _ value: String?, _ act: @escaping () -> Void) -> some View {
        Button {
            session.touch()
            act()
        } label: {
            HStack(spacing: 11) {
                UmbraIcon(d: icon, size: 17, strokeWidth: 1.9)
                    .foregroundColor(UmbraColor.muted)
                Text(label)
                    .font(UmbraFont.sans(16, .w400))
                    .foregroundColor(UmbraColor.text)
                Spacer(minLength: 0)
                if let v = value {
                    Text(v).font(UmbraFont.sans(14, .w400)).foregroundColor(UmbraColor.faint)
                }
                UmbraIcon(d: UmbraIconPath.chevronRight, size: 15, strokeWidth: 2.2)
                    .foregroundColor(UmbraColor.faint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        UmbraPage(navBar: {
            UmbraNavBar(backLabel: "密码保险箱", title: "", onBack: { router.back() }) {
                if let it = item {
                    Button {
                        session.touch()
                        Task { await store.toggleFav(it.id) }
                    } label: {
                        UmbraIcon(d: UmbraIconPath.star, size: 19, strokeWidth: 2)
                            .foregroundColor(it.favorite == true ? UmbraColor.orange : UmbraColor.faint)
                            .frame(width: UmbraMetric.tapMin, height: UmbraMetric.tapMin)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    UmbraNavAction(title: "编辑") {
                        session.touch()
                        router.go(.vaultEdit(id: it.id))
                    }
                }
            }
        }, content: {
            if let it = item { content(it) } else { missing }
        })
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
        UmbraPage(navBar: {
            UmbraNavBar(backLabel: "取消", title: id == nil ? "存一条新的" : "编辑记录",
                        onBack: { router.back() }, backChevron: false) {
                UmbraNavAction(title: "存下", weight: .w600, enabled: canSave, action: save)
            }
        }, content: {
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
