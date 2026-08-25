// 密码保险箱的工具页：生成器、安全体检、分组、身份库、回收站、导入、
// 创建、恢复、Secret Key 备份、设置、修改主密码。
//
// 哪些是真做、哪些是如实说明，一条条写在各自的注释里。判断标准只有一条：
// **这台手机上做得到吗。** 做得到就做真的；做不到（要么服务端没接口，要么风险不该由手机承担）
// 就给一个说清楚状况、并且指出下一步在哪的承接页 —— 不摆点了没反应的按钮。
import SwiftUI
import UIKit
import Security

// MARK: - 密码生成器（真做）

enum UmbraPasswordGen {
    struct Options {
        var length = 20
        var upper = true
        var digit = true
        var symbol = true
        /// 避免易混字符 l 1 I O 0。
        var noAmbiguous = true
    }

    /// 用 SecRandomCopyBytes，不是 Int.random —— 生成密码这件事上，
    /// 「看起来随机」和「密码学随机」是两回事。
    static func make(_ o: Options) -> String {
        var pool = "abcdefghijkmnpqrstuvwxyz"
        if o.upper { pool += "ABCDEFGHJKLMNPQRSTUVWXYZ" }
        if o.digit { pool += o.noAmbiguous ? "23456789" : "0123456789" }
        if o.symbol { pool += "!@#$%^&*-_=+?" }
        if !o.noAmbiguous { pool += "ilo01O" }
        let chars = Array(pool)
        guard !chars.isEmpty else { return "" }
        var bytes = [UInt8](repeating: 0, count: max(1, o.length))
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // 取模会让靠前的字符略微偏多。字符集最多 70 出头、模 256 的偏差在这个用途下可以忽略，
        // 但仍然把它写出来，免得以后有人以为这里是严格均匀的。
        return String(bytes.map { chars[Int($0) % chars.count] })
    }
}

struct UmbraVaultGenView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var session: UmbraVaultSession

    @State private var opts = UmbraPasswordGen.Options()
    @State private var value = ""

    var body: some View {
        UmbraScreen(content: {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 11) {
                    Text(value)
                        .font(UmbraFont.mono(17))
                        .foregroundColor(UmbraColor.text)
                        .lineSpacing(17 * 0.7)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        let lv = UmbraPasswordStrength.level(value)
                        UmbraProgressBar(progress: UmbraPasswordStrength.ratio(lv),
                                         color: UmbraPasswordStrength.color(lv))
                        Text("强度 \(UmbraPasswordStrength.label(lv))")
                            .font(UmbraFont.sans(11.5, .w560))
                            .foregroundColor(UmbraPasswordStrength.color(lv))
                            .fixedSize()
                        Button { regen() } label: {
                            Text("换一个")
                                .font(UmbraFont.sans(12.5, .w560))
                                .foregroundColor(UmbraColor.orange)
                                .frame(minHeight: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
                .overlay(
                    RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                        .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        UmbraFieldLabel(text: "长度")
                        Spacer(minLength: 0)
                        Text("\(opts.length)").font(UmbraFont.mono(14, .w560)).foregroundColor(UmbraColor.text)
                    }
                    Slider(value: Binding(
                        get: { Double(opts.length) },
                        set: { opts.length = Int($0); regen() }
                    ), in: 8...40, step: 1)
                    .tint(UmbraColor.orange)
                }

                UmbraSettingSectionView(section: UmbraSettingSection(rows: [
                    toggleRow("包含大写字母", opts.upper) { opts.upper.toggle(); regen() },
                    toggleRow("包含数字", opts.digit) { opts.digit.toggle(); regen() },
                    toggleRow("包含符号", opts.symbol) { opts.symbol.toggle(); regen() },
                    toggleRow("避免易混字符 l 1 I O 0", opts.noAmbiguous) { opts.noAmbiguous.toggle(); regen() }
                ]))
                .padding(.horizontal, -UmbraMetric.pagePadX)

                Text("生成的密码不会自动保存。复制之后回到记录里粘进密码字段，再存一次。")
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(UmbraColor.faint)
                    .lineSpacing(12 * 0.65)

                UmbraButton(title: "复制这个密码", kind: .primary, height: 52) {
                    UmbraClipboard.copySensitive(value)
                    router.showToast("已复制 · 60 秒后自动清除")
                }
            }
            .padding(UmbraMetric.pagePadX)
        })
        .navigationTitle("密码生成器")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            session.touch()
            if value.isEmpty { regen() }
        }
    }

    private func toggleRow(_ label: String, _ on: Bool, _ act: @escaping () -> Void) -> UmbraSettingRow {
        UmbraSettingRow(label: label, toggle: on, action: act)
    }

    private func regen() {
        // 四个开关全关时字符池只剩小写，这时仍然能生成 —— 但强度条会如实显示「弱」。
        value = UmbraPasswordGen.make(opts)
        session.touch()
    }
}

// MARK: - 安全体检（真做，全在本机算）

struct UmbraVaultCheckView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var session: UmbraVaultSession

    var body: some View {
        let audit = UmbraVaultAudit(items: store.items)
        UmbraScreen(content: {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    UmbraScoreRing(score: audit.score, size: 72)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(audit.total == 0 ? "没有发现问题" : "\(audit.total) 项需要处理")
                            .font(UmbraFont.sans(16, .w560))
                            .foregroundColor(UmbraColor.text)
                        Text("共 \(store.items.count) 条记录 · 只在本机计算，不上传")
                            .font(UmbraFont.sans(13, .w400))
                            .foregroundColor(UmbraColor.muted)
                            .lineSpacing(13 * 0.6)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
                .overlay(
                    RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                        .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                )

                if audit.groups.isEmpty {
                    Text(store.items.isEmpty
                         ? "还没有记录，体检没什么可看的。"
                         : "重复密码、弱密码、没开两步验证、长期未更新 —— 四项都没问题。")
                        .font(UmbraFont.sans(13, .w400))
                        .foregroundColor(UmbraColor.muted)
                        .lineSpacing(13 * 0.65)
                }

                ForEach(audit.groups) { g in groupCard(g) }

                Text("体检只看密码本身的强度、重复与更新时间，不会去任何网站校验，也不查泄漏库 —— 那要把密码发出去。")
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(UmbraColor.faint)
                    .lineSpacing(12 * 0.65)
            }
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.top, UmbraMetric.pagePadX)
            .padding(.bottom, UmbraMetric.sp8)
        })
        .navigationTitle("安全体检")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { session.touch() }
    }

    private func groupCard(_ g: UmbraVaultAudit.Group) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                UmbraIcon(d: g.iconPath, size: 14, strokeWidth: 1.9)
                    .foregroundColor(g.color)
                Text(g.name)
                    .font(UmbraFont.sans(12, .w560))
                    .tracking(UmbraFont.labelTracking(12))
                    .foregroundColor(g.color)
                Spacer(minLength: 0)
                Text("\(g.findings.count) 条")
                    .font(UmbraFont.mono(12))
                    .foregroundColor(UmbraColor.faint)
            }
            VStack(spacing: 0) {
                ForEach(Array(g.findings.enumerated()), id: \.element.id) { idx, f in
                    if idx > 0 { UmbraRowDivider() }
                    Button {
                        router.go(.vaultRecord(id: f.item.id))
                    } label: {
                        HStack(spacing: 11) {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(UmbraColor.chip)
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Text(String(f.item.title.prefix(1)))
                                        .font(UmbraFont.sans(14, .w600))
                                        .foregroundColor(UmbraColor.muted)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.item.title)
                                    .font(UmbraFont.sans(15, .w560))
                                    .foregroundColor(UmbraColor.text)
                                Text(f.why)
                                    .font(UmbraFont.sans(12.5, .w400))
                                    .foregroundColor(UmbraColor.faint)
                            }
                            Spacer(minLength: 0)
                            UmbraIcon(d: UmbraIconPath.chevronRight, size: 15, strokeWidth: 2.2)
                                .foregroundColor(UmbraColor.faint)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                    .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
            )
        }
    }
}

// MARK: - 分组（只读 + 移动记录）

struct UmbraVaultGroupsView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var store: VaultStore

    var body: some View {
        UmbraSettingsPage(
            backLabel: "返回", title: "分组", onBack: { router.back() },
            intro: "分组是记录的分类（登录、密钥、证件…）。手机上可以把记录移到别的分组里，新建、改名、删除分组要去电脑上做 —— 那会改到快照结构，风险不该由手机端承担。",
            sections: [
                UmbraSettingSection(
                    header: "共 \(store.types.count) 个",
                    footer: "在记录列表长按一条记录，选「移动到分组」就能换组。",
                    rows: store.types.isEmpty
                        ? [UmbraSettingRow(label: "（还没有分组）", tint: UmbraColor.faint)]
                        : store.types.map { t in
                            UmbraSettingRow(label: t.name,
                                            value: "\(store.items.filter { $0.typeId == t.id }.count) 条")
                        })
            ])
    }
}

// MARK: - 身份库（只读 + 切换）

struct UmbraVaultProfilesView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var store: VaultStore

    var body: some View {
        UmbraSettingsPage(
            backLabel: "返回", title: "身份库", onBack: { router.back() },
            intro: "身份库之间数据隔离，同一时刻只有一个是当前库。手机上可以切换，新建、改名、删除要去电脑上做。",
            sections: [
                UmbraSettingSection(
                    header: "共 \(store.vaults.count) 个",
                    footer: "切换后列表、搜索、体检都只看当前库。",
                    rows: store.vaults.map { v in
                        UmbraSettingRow(label: v.name,
                                        sub: v.id == store.curVaultId ? "当前库" : nil,
                                        value: v.id == store.curVaultId ? "使用中" : "切到这个",
                                        chevron: v.id != store.curVaultId) {
                            guard v.id != store.curVaultId else { return }
                            store.switchVault(v.id)
                            router.showToast("已切到身份库「\(v.name)」")
                        }
                    })
            ])
    }
}

// MARK: - 回收站
//
// **界面一页，存储两套。** 这是这个页面唯一需要记住的事：
//   通用区（灵感 / 任务 / 提醒）—— 存在服务端，走 HTTPService 的 /trash 三个接口
//   保险箱区                   —— 端到端加密，走 VaultStore，服务端连它有几条都不知道
//
// 保险箱那一区**锁着时读不出标题**（没有密钥），只显示一个条数 ——
// 那个数字来自本机缓存里的明文字段。这不是「藏起来了」，是密码学事实：解不开就是解不开。
//
// 手机上刻意**不做多选**：一屏就三四张卡，每张自带「恢复 / 彻底删除」，
// 比先进多选态再点批量条快。电脑端那一套多选是为了一次处理十几条，手机上用不上。

struct UmbraVaultTrashView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var store: VaultStore

    @State private var generic: [TrashItem] = []
    @State private var keepDays = 30
    @State private var loading = true

    private var vaultRows: [VaultStore.TrashRow] { store.unlocked ? store.trashRows() : [] }
    private var vaultCount: Int { store.unlocked ? vaultRows.count : store.trashCount }
    private var isEmpty: Bool { generic.isEmpty && vaultCount == 0 }

    var body: some View {
        UmbraSettingsPage(
            backLabel: "返回", title: "回收站", onBack: { router.back() },
            intro: isEmpty ? nil
                : "删除的东西在这里保留 \(keepDays) 天，到期彻底删除。密码保险箱的条目单独加密，锁着时只能看到条数。",
            sections: [],
            footnote: isEmpty ? nil : "恢复会把条目放回原来的位置。彻底删除不进任何地方，也没有恢复的路。",
            extra: {
                VStack(alignment: .leading, spacing: UmbraMetric.sp6) {
                    if isEmpty && !loading {
                        UmbraEmptyState(
                            iconPath: UmbraIconPath.trash,
                            title: "回收站是空的",
                            hint: "删掉的任务、灵感、提醒会先放进来，保留 \(keepDays) 天。保险箱的条目也在这里，锁着时只显示条数。")
                            .padding(.horizontal, UmbraMetric.pagePadX)
                    } else {
                        genericZone
                        vaultZone
                    }
                }
            })
        .task { await reload() }
        .refreshable { await reload() }
    }

    // MARK: 通用区

    @ViewBuilder private var genericZone: some View {
        VStack(alignment: .leading, spacing: UmbraMetric.sp3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                UmbraSectionLabel(text: "通用")
                Text("\(generic.count) 项")
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(UmbraColor.faint)
                Spacer(minLength: 0)
                if !generic.isEmpty {
                    Button("清空") { askPurgeAll() }
                        .font(UmbraFont.sans(13, .w400))
                        .foregroundColor(UmbraColor.danger)
                        .frame(minHeight: 44)          // 44 是可点区下限，不是视觉高度
                }
            }
            .padding(.horizontal, UmbraMetric.pagePadX + 4)

            if generic.isEmpty {
                UmbraCard {
                    Text("通用区没有东西")
                        .font(UmbraFont.sans(13, .w400))
                        .foregroundColor(UmbraColor.faint)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, UmbraMetric.pagePadX)
            } else {
                ForEach(generic) { it in
                    row(icon: kindIcon(it.kind), title: it.title,
                        meta: "\(kindName(it.kind)) · \(whenText(it.deleted_at_ms))",
                        leftDays: it.left_days,
                        onRestore: { askRestoreGeneric(it) },
                        onPurge: { askPurgeGeneric(it) })
                        .padding(.horizontal, UmbraMetric.pagePadX)
                }
            }
        }
    }

    // MARK: 保险箱区

    @ViewBuilder private var vaultZone: some View {
        // 条数为 0 就整区不画。没建过保险箱、或者里面本来就没删过东西时，
        // 常驻一个空区只是在提醒用户「你没有的东西是空的」。
        if vaultCount > 0 {
            VStack(alignment: .leading, spacing: UmbraMetric.sp3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    UmbraSectionLabel(text: "密码保险箱")
                    Text("\(vaultCount) 项")
                        .font(UmbraFont.sans(12, .w400))
                        .foregroundColor(UmbraColor.faint)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, UmbraMetric.pagePadX + 4)

                if store.unlocked {
                    ForEach(vaultRows) { r in
                        row(icon: UmbraIconPath.lock, title: r.title,
                            meta: "\(r.from) · \(whenText(r.deletedAtMs))",
                            leftDays: r.leftDays,
                            onRestore: { askRestoreVault(r) },
                            onPurge: { askPurgeVault(r) })
                            .padding(.horizontal, UmbraMetric.pagePadX)
                    }
                } else {
                    lockedCard.padding(.horizontal, UmbraMetric.pagePadX)
                }
            }
        }
    }

    private var lockedCard: some View {
        UmbraCard {
            HStack(spacing: UmbraMetric.sp3) {
                UmbraIconBlock(d: UmbraIconPath.lock, block: 34, icon: 17)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(store.trashCount) 项 · 解锁后可查看")
                        .font(UmbraFont.sans(14.5, .w560))
                        .foregroundColor(UmbraColor.text)
                    Text("这些条目是端到端加密的，锁着时读不出标题。")
                        .font(UmbraFont.sans(12, .w400))
                        .foregroundColor(UmbraColor.faint)
                        .lineSpacing(12 * 0.55)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("解锁") { router.go(.vaultHome) }
                    .font(UmbraFont.sans(14, .w560))
                    .foregroundColor(UmbraColor.orange)
                    .frame(minHeight: 44)
            }
        }
    }

    // MARK: 一张条目卡

    private func row(icon: String, title: String, meta: String, leftDays: Int,
                     onRestore: @escaping () -> Void, onPurge: @escaping () -> Void) -> some View {
        UmbraCard {
            VStack(alignment: .leading, spacing: UmbraMetric.sp3) {
                HStack(spacing: UmbraMetric.sp3) {
                    UmbraIconBlock(d: icon, block: 34, icon: 17)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(UmbraFont.sans(16, .w560))
                            .foregroundColor(UmbraColor.text)
                            .lineLimit(1)
                        Text("\(meta) · 还剩 \(leftDays) 天")
                            .font(UmbraFont.sans(12.5, .w400))
                            // 稿：剩余 ≤ 7 天转 warning。这是这一页**唯一**的紧迫信号，
                            // 没有别的红点角标，所以这一档不能省。
                            .foregroundColor(leftDays <= 7 ? UmbraColor.warning : UmbraColor.faint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    UmbraButton(title: "恢复", kind: .secondary, height: 44, action: onRestore)
                    UmbraButton(title: "彻底删除", kind: .dangerOutline, height: 44, action: onPurge)
                }
            }
        }
    }

    // MARK: 动作

    @MainActor private func reload() async {
        loading = true
        defer { loading = false }
        if let dto = await HTTPService.shared.fetchTrash() {
            generic = dto.items
            keepDays = dto.keep_days ?? 30
        }
    }

    /// 恢复也过确认（老板验收点名）：恢复不是破坏性操作，但它会把条目放回
    /// 列表并改动统计 —— 回收站里挨着「彻底删除」，手滑点错的成本要挡一道。
    private func askRestoreGeneric(_ it: TrashItem) {
        router.confirm(UmbraAlert(
            title: "恢复「\(it.title)」？",
            body: "条目会回到原来的位置，统计也会跟着回来。",
            confirmLabel: "恢复",
            onConfirm: { Task { await restoreGeneric(it) } }))
    }

    private func askRestoreVault(_ r: VaultStore.TrashRow) {
        router.confirm(UmbraAlert(
            title: "恢复「\(r.title)」？",
            body: "条目会回到保险箱原来的分组。",
            confirmLabel: "恢复",
            onConfirm: { Task { await store.restoreTrash(vaultId: r.vaultId, itemId: r.itemId) } }))
    }

    @MainActor private func restoreGeneric(_ it: TrashItem) async {
        guard await HTTPService.shared.restoreTrash([it.entry]) else {
            router.showToast("恢复失败，服务端没有响应"); return
        }
        await reload()
        router.showToast("已恢复「\(it.title)」")
    }

    private func askPurgeGeneric(_ it: TrashItem) {
        router.confirm(UmbraAlert(
            title: "彻底删除「\(it.title)」？",
            body: "不再进回收站，也没有恢复的路。",
            confirmLabel: "彻底删除",
            confirmDestructive: true,
            onConfirm: {
                Task {
                    _ = await HTTPService.shared.purgeTrash([it.entry])
                    await reload()
                    router.showToast("已彻底删除")
                }
            }))
    }

    private func askPurgeVault(_ r: VaultStore.TrashRow) {
        router.confirm(UmbraAlert(
            title: "彻底删除「\(r.title)」？",
            body: "密文与附件一并擦掉，其它设备下次同步后同样消失。没有恢复的路。",
            confirmLabel: "彻底删除",
            confirmDestructive: true,
            onConfirm: {
                Task {
                    await store.purgeTrash(vaultId: r.vaultId, itemId: r.itemId)
                    router.showToast("已彻底删除")
                }
            }))
    }

    private func askPurgeAll() {
        // 稿里这句点名了「保险箱那一区要解锁后单独清」——
        // 那不是界面上的取舍，是服务端确实碰不到那一区。
        let body = vaultCount > 0
            ? "通用区 \(generic.count) 项会被彻底删除。保险箱那 \(vaultCount) 项要解锁后单独清，这里动不了。"
            : "通用区 \(generic.count) 项会被彻底删除，没有恢复的路。"
        router.confirm(UmbraAlert(
            title: "清空回收站？", body: body,
            confirmLabel: "清空", confirmDestructive: true,
            onConfirm: {
                Task {
                    _ = await HTTPService.shared.purgeAllTrash()
                    await reload()
                    router.showToast("已清空通用区")
                }
            }))
    }

    // MARK: 小工具

    private func kindIcon(_ kind: String) -> String {
        switch kind {
        case "idea": return UmbraIconPath.bulb
        case "reminder": return UmbraIconPath.bell
        case "money": return UmbraIconPath.wallet
        default: return UmbraIconPath.task
        }
    }

    private func kindName(_ kind: String) -> String {
        switch kind {
        case "idea": return "灵感"
        case "reminder": return "提醒"
        // 记账一期加的：流水删除也进统一回收站（2026-08-24 拍板保留）。
        case "money": return "记账"
        default: return "任务"
        }
    }

    /// 删除时刻 → 「今天 14:02」「昨天 22:10」「8月17日」。
    private func whenText(_ ms: Double) -> String {
        guard ms > 0 else { return "" }
        let d = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(d) { f.dateFormat = "今天 HH:mm" }
        else if cal.isDateInYesterday(d) { f.dateFormat = "昨天 HH:mm" }
        else if cal.isDate(d, equalTo: Date(), toGranularity: .year) { f.dateFormat = "M月d日" }
        else { f.dateFormat = "yyyy年M月d日" }
        return f.string(from: d) + "删除"
    }
}

// MARK: - 导入（如实说明）

struct UmbraVaultImportView: View {
    @EnvironmentObject private var router: UmbraRouter

    var body: some View {
        UmbraSettingsPage(
            backLabel: "返回", title: "导入", onBack: { router.back() },
            intro: "从浏览器导出的密码 CSV 是**明文**。手机上不做导入 —— 明文文件在手机里过一遍，风险远大于省下的那点事。",
            sections: [
                UmbraSettingSection(header: "在电脑上怎么做", rows: [
                    UmbraSettingRow(label: "1. 从 Chrome / Safari 导出密码 CSV"),
                    UmbraSettingRow(label: "2. 在电脑端保险箱里选「从浏览器导入」"),
                    UmbraSettingRow(label: "3. 导入完成后删掉那个 CSV 文件"),
                    UmbraSettingRow(label: "4. 手机上下拉一次就同步过来了")
                ])
            ],
            footnote: "导出明文备份同理，只在电脑端可用。")
    }
}

// MARK: - 创建保险箱（如实说明）

struct UmbraVaultCreateView: View {
    @EnvironmentObject private var router: UmbraRouter

    var body: some View {
        UmbraSettingsPage(
            backLabel: "返回", title: "创建保险箱", onBack: { router.back() },
            intro: "保险箱要在电脑端创建。创建时会生成 Secret Key 与主密码派生参数，并把第一份密文推到服务端 —— 这几步在手机上做，出错就意味着数据永远打不开。",
            sections: [
                UmbraSettingSection(header: "在电脑上怎么做", rows: [
                    UmbraSettingRow(label: "1. 打开电脑端 Umbra 的「密码保险箱」"),
                    UmbraSettingRow(label: "2. 设一个主密码（不保存、不上传，忘记无法找回）"),
                    UmbraSettingRow(label: "3. 保存好 Emergency Kit 里的 Secret Key"),
                    UmbraSettingRow(label: "4. 点一次「立即同步」")
                ]),
                UmbraSettingSection(header: "然后回到这里", footer: "两端用同一个访问 Token（在「我 › 连接」里填）。", rows: [
                    UmbraSettingRow(label: "输入主密码 + Secret Key 解锁", chevron: true)
                ])
            ])
    }
}

// MARK: - 用 Secret Key 恢复（真做）

struct UmbraVaultRecoverView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var session: UmbraVaultSession

    @State private var key = ""
    @State private var password = ""

    /// 格式：`A3-7KQP-XM4T-9WZR B8-2LNV-6HDC-5FYJ`。
    /// 只做**格式**校验挡一下手滑，真正对不对要靠解密结果说话。
    private var keyLooksValid: Bool {
        let pattern = "^[A-Za-z0-9]{2}(-[A-Za-z0-9]{4}){3}\\s+[A-Za-z0-9]{2}(-[A-Za-z0-9]{4}){3}$"
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: pattern, options: .regularExpression) != nil
    }

    var body: some View {
        UmbraScreen(content: {
            VStack(alignment: .leading, spacing: UmbraMetric.sp5) {
                Text("换了新设备时用。Secret Key 在电脑端的 Emergency Kit 里，和主密码一起才能解开数据 —— 两者缺一不可，服务端两样都没有。")
                    .font(UmbraFont.sans(12.5, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineSpacing(12.5 * 0.7)

                VStack(alignment: .leading, spacing: UmbraMetric.sp2) {
                    UmbraFieldLabel(text: "Secret Key")
                    TextField("A3-7KQP-XM4T-9WZR B8-2LNV-6HDC-5FYJ", text: $key)
                        .font(UmbraFont.mono(14))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 13)
                        .frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous).fill(UmbraColor.card))
                        .overlay(
                            RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous)
                                .strokeBorder(key.isEmpty ? UmbraColor.border
                                              : (keyLooksValid ? UmbraColor.orange : UmbraColor.danger),
                                              lineWidth: UmbraMetric.borderW)
                        )
                    if !key.isEmpty && !keyLooksValid {
                        Text("格式应该像 A3-7KQP-XM4T-9WZR B8-2LNV-6HDC-5FYJ（两段，各 4 组）。")
                            .font(UmbraFont.sans(12, .w400))
                            .foregroundColor(UmbraColor.danger)
                    }
                    Button {
                        if let s = UIPasteboard.general.string { key = s }
                    } label: {
                        Text("从剪贴板粘贴")
                            .font(UmbraFont.sans(13, .w560))
                            .foregroundColor(UmbraColor.orange)
                            .frame(minHeight: UmbraMetric.tapMin)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: UmbraMetric.sp2) {
                    UmbraFieldLabel(text: "主密码")
                    SecureField("原来的主密码", text: $password)
                        .font(UmbraFont.mono(15))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 13)
                        .frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous).fill(UmbraColor.card))
                        .overlay(
                            RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous)
                                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                        )
                }

                if !store.error.isEmpty {
                    Text(store.error)
                        .font(UmbraFont.sans(13, .w400))
                        .foregroundColor(UmbraColor.danger)
                        .lineSpacing(13 * 0.6)
                }

                UmbraButton(title: store.loading ? "恢复中…" : "在这台设备上恢复",
                            kind: store.loading ? .disabled : .primary, height: 52) {
                    Task {
                        await store.unlock(password: password,
                                           secretKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
                        if store.unlocked {
                            session.markUnlocked()
                            router.back()
                            router.showToast("已在这台设备上恢复保险箱")
                        }
                    }
                }

                Text("恢复成功后 Secret Key 会存进这台设备的 Keychain，以后只要主密码。")
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(UmbraColor.faint)
                    .lineSpacing(12 * 0.65)
            }
            .padding(UmbraMetric.pagePadX)
        })
        .navigationTitle("用 Secret Key 恢复")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Secret Key 备份（真做）

struct UmbraVaultKeyView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var session: UmbraVaultSession

    @State private var revealed = false
    @State private var revealTask: Task<Void, Never>?

    private var secretKey: String? { VaultKeychain.load() }

    var body: some View {
        UmbraScreen(content: {
            VStack(alignment: .leading, spacing: UmbraMetric.sp5) {
                Text("Secret Key 和主密码一起才能解开数据。换设备、重装应用都要用它 —— 丢了就再也进不去，服务端帮不上忙。")
                    .font(UmbraFont.sans(12.5, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineSpacing(12.5 * 0.7)

                if let sk = secretKey {
                    VStack(alignment: .leading, spacing: 11) {
                        Text(revealed ? sk : String(repeating: "•", count: 20))
                            .font(UmbraFont.mono(16, .w560))
                            .foregroundColor(UmbraColor.text)
                            .lineSpacing(16 * 0.6)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            UmbraButton(title: revealed ? "遮起来" : "显示", kind: .secondary, height: 40) {
                                toggleReveal()
                            }
                            UmbraButton(title: "复制", kind: .secondary, height: 40) {
                                UmbraClipboard.copySensitive(sk)
                                router.showToast("已复制 Secret Key · 60 秒后自动清除")
                            }
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                            .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                    )

                    Text("显示 8 秒后会自动遮起来。别把它和主密码存在同一个地方 —— 那等于把两把钥匙拴在一起。")
                        .font(UmbraFont.sans(12, .w400))
                        .foregroundColor(UmbraColor.faint)
                        .lineSpacing(12 * 0.65)
                } else {
                    UmbraCard {
                        VStack(alignment: .leading, spacing: UmbraMetric.sp2) {
                            UmbraSectionLabel(text: "这台设备上还没有 Secret Key")
                            Text("解锁过一次之后它才会存进 Keychain。去保险箱首页用主密码 + Secret Key 解锁一次就有了。")
                                .font(UmbraFont.body)
                                .foregroundColor(UmbraColor.text)
                                .lineSpacing(UmbraFont.bodyLineSpacing)
                        }
                    }
                }
            }
            .padding(UmbraMetric.pagePadX)
        })
        .navigationTitle("Secret Key")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { session.touch() }
        .onDisappear { revealTask?.cancel() }
    }

    private func toggleReveal() {
        revealTask?.cancel()
        revealed.toggle()
        guard revealed else { return }
        revealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            revealed = false
        }
    }
}

// MARK: - 保险箱设置

struct UmbraVaultSettingsView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var session: UmbraVaultSession

    /// 开启生物识别时的主密码确认浮层。开这个开关**当场就要验一次**：
    /// 先验主密码（证明是保险箱主人），再验面容/指纹（证明人在跟前），两关都过才写入。
    @State private var askPassword = false
    @State private var confirmPwd = ""
    @State private var confirmErr = ""
    @State private var confirmBusy = false
    @FocusState private var confirmFocused: Bool

    /// 回收站里通用区（灵感 / 任务 / 提醒）的条数。保险箱那一区的条数
    /// 直接读 store.trashCount —— 它锁着时也有值。
    @State private var genericTrash = 0

    /// 「N 项」/「没有」。**拉不到就先按只有保险箱那部分算** ——
    /// 宁可少报也不要报一个编出来的数字。
    private var trashCountLabel: String {
        let n = genericTrash + store.trashCount
        return n > 0 ? "\(n) 项" : "没有"
    }

    var body: some View {
        UmbraSettingsPage(
            backLabel: "返回", title: "保险箱设置", onBack: { router.back() },
            sections: [
                UmbraSettingSection(
                    header: "锁定",
                    footer: "切到后台时内容立刻遮盖；无操作超过设定时长就要重新验证。",
                    rows: lockRows),
                UmbraSettingSection(header: "整理", rows: [
                    UmbraSettingRow(label: "分组", value: "\(store.types.count) 个", chevron: true) { router.go(.vaultGroups) },
                    UmbraSettingRow(label: "身份库", value: "\(store.vaults.count) 个", chevron: true) { router.go(.vaultProfiles) },
                    UmbraSettingRow(label: "回收站", value: trashCountLabel, chevron: true) { router.go(.vaultTrash) }
                ]),
                UmbraSettingSection(
                    header: "主密码与恢复",
                    footer: "主密码不保存、不上传，忘记无法找回。",
                    rows: [
                        UmbraSettingRow(label: "修改主密码", sub: "要在电脑上做", chevron: true) { router.go(.vaultPwd) },
                        UmbraSettingRow(label: "查看 Secret Key", chevron: true) { router.go(.vaultKey) }
                    ]),
                UmbraSettingSection(
                    header: "导入导出",
                    footer: "导出的是明文，只在电脑上做。",
                    rows: [
                        UmbraSettingRow(label: "从浏览器导入", sub: "Chrome / Safari 的密码 CSV", chevron: true) { router.go(.vaultImport) }
                    ]),
                UmbraSettingSection(
                    header: "系统填充",
                    footer: "真的填充面板由系统在别的 App 里唤起，跑在 AutoFill 扩展里；这里是它的形态说明。",
                    rows: [
                        UmbraSettingRow(label: "看看系统填充面板长什么样", chevron: true) { router.go(.vaultAutofill) }
                    ]),
                UmbraSettingSection(
                    header: "同步与本机数据",
                    footer: store.offline
                        ? "当前离线，用的是本机那份密文缓存。缓存是加密的，没有主密码谁也读不懂。"
                        : "服务端只存密文，解不开也读不懂。本机也留一份同样的密文，断网时照样能开。",
                    rows: [
                        UmbraSettingRow(label: store.loading ? "同步中…" : "立即同步",
                                        value: store.pendingPush ? "有改动待推" : nil,
                                        tint: UmbraColor.orange) {
                            Task {
                                await store.syncNow()
                                router.showToast(store.pendingPush ? "还是没推上去，等联网" : "已同步")
                            }
                        },
                        UmbraSettingRow(label: "忘掉这台设备上的本地数据",
                                        sub: "清掉密文缓存与 Secret Key，下次要重新输一遍",
                                        tint: UmbraColor.danger) {
                            router.confirm(UmbraAlert(
                                title: "忘掉本机数据？",
                                body: "清掉本机的密文缓存和 Secret Key。云端的数据不受影响，但这台设备之后要重新输主密码和 Secret Key，而且断网时打不开保险箱。",
                                confirmLabel: "忘掉",
                                confirmDestructive: true,
                                onConfirm: {
                                    store.forgetLocalData()
                                    session.forgetPassword()
                                    router.back()
                                    router.showToast("已清掉本机数据")
                                }))
                        }
                    ])
            ])
            .onAppear { session.touch() }
            .task {
                // 回收站那一行要显示「N 项」。通用区的条数只有服务端知道，
                // 拉一次；拉不到就退回只算保险箱那部分（trashCountLabel 里那句注释）。
                if let dto = await HTTPService.shared.fetchTrash() { genericTrash = dto.items.count }
            }
            .overlay { if askPassword { passwordConfirm } }
    }

    // MARK: 开启生物识别前的主密码确认
    //
    // 用浮层而不是系统 alert：系统 alert 上塞输入框在 SwiftUI 里只能用
    // `.alert(...) { TextField }`，而这个页面已经有别的 alert 了 ——
    // 同一个视图上挂两个 .alert，SwiftUI 只认第一个（这个坑「我 › 连接」页踩过一次）。
    private var passwordConfirm: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture { closeConfirm() }
            VStack(spacing: 13) {
                VStack(spacing: 6) {
                    Text("先验一次主密码")
                        .font(UmbraFont.sans(16, .w600))
                        .foregroundColor(UmbraColor.text)
                    Text("确认之后会立刻验一次 \(session.biometryName)，两关都过才把主密码存进这台设备的安全隔区。")
                        .font(UmbraFont.sans(13, .w400))
                        .foregroundColor(UmbraColor.muted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(13 * 0.55)
                }
                SecureField("主密码", text: $confirmPwd)
                    .font(UmbraFont.mono(15))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .focused($confirmFocused)
                    .padding(.horizontal, 13)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous).fill(UmbraColor.bg))
                    .overlay(
                        RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous)
                            .strokeBorder(confirmErr.isEmpty ? UmbraColor.border : UmbraColor.danger,
                                          lineWidth: UmbraMetric.borderW)
                    )
                if !confirmErr.isEmpty {
                    Text(confirmErr)
                        .font(UmbraFont.sans(12.5, .w400))
                        .foregroundColor(UmbraColor.danger)
                        .lineSpacing(12.5 * 0.55)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 9) {
                    UmbraButton(title: "取消", kind: .secondary, height: 44) { closeConfirm() }
                    UmbraButton(title: confirmBusy ? "验证中…" : "继续",
                                kind: confirmBusy || confirmPwd.isEmpty ? .disabled : .primary,
                                height: 44) { submitConfirm() }
                }
            }
            .padding(17)
            .frame(maxWidth: 320)
            .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                    .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
            )
            .padding(.horizontal, 28)
        }
        .onAppear { confirmFocused = true }
    }

    private func closeConfirm() {
        askPassword = false
        confirmPwd = ""
        confirmErr = ""
        confirmBusy = false
    }

    private func submitConfirm() {
        guard !confirmBusy, !confirmPwd.isEmpty else { return }
        session.touch()
        confirmBusy = true
        confirmErr = ""
        let pwd = confirmPwd
        session.enableBiometry(password: pwd, verifyPassword: { store.verifyPassword($0) }) { err in
            confirmBusy = false
            if let err {
                confirmErr = err
            } else {
                closeConfirm()
                router.showToast("\(session.biometryName) 解锁已开启")
            }
        }
    }

    private var lockRows: [UmbraSettingRow] {
        var rows: [UmbraSettingRow] = [
            UmbraSettingRow(label: "自动锁定", value: "\(session.autoLockMinutes) 分钟", chevron: true) {
                router.present(UmbraSheet(title: "无操作多久自动锁定",
                                          items: [1, 5, 10, 30].map { m in
                    UmbraSheetItem(label: "\(m) 分钟", checked: session.autoLockMinutes == m) {
                        session.autoLockMinutes = m
                    }
                }))
            },
            UmbraSettingRow(label: "切到后台立即遮盖", sub: "App 切走时用字标遮住内容",
                            toggle: session.maskEnabled) { session.maskEnabled.toggle() }
        ]
        if session.biometryAvailable {
            let on = session.faceIDEnabled && session.hasBiometricCredential
            rows.append(UmbraSettingRow(
                label: "用 \(session.biometryName) 解锁",
                sub: on
                    ? "主密码存在这台设备的安全隔区里，不上传、不进备份。重新录入面容/指纹后会自动失效。"
                    : "打开时会当场验一次主密码和 \(session.biometryName)，之后才存进这台设备的安全隔区。",
                toggle: on) {
                    session.touch()
                    if on {
                        session.disableBiometry()
                        router.showToast("已关闭，存的主密码也一并清掉了")
                    } else if !store.unlocked {
                        // 没解锁就没法验主密码对不对（校验值在快照里）。
                        router.showToast("先解锁保险箱，再开这个开关")
                    } else {
                        confirmPwd = ""
                        confirmErr = ""
                        askPassword = true
                    }
                })
        } else {
            // 不可用时不给一个点不动的开关，直接说明为什么。
            rows.append(UmbraSettingRow(label: "用 \(session.biometryName) 解锁",
                                        sub: "这台设备没有可用的生物识别",
                                        value: "不可用", tint: UmbraColor.faint))
        }
        if session.hasBiometricCredential {
            rows.append(UmbraSettingRow(label: "忘掉已存的主密码", tint: UmbraColor.danger) {
                session.forgetPassword()
                router.showToast("已清掉，下次要用主密码解锁")
            })
        }
        rows.append(UmbraSettingRow(label: "立即上锁", tint: UmbraColor.orange) {
            store.lock()
            // 主动上锁这一档不自动刷脸 —— 刚锁完就弹识别面板等于没锁。
            session.markManualLock()
            router.back()
            router.showToast("已重新上锁")
        })
        return rows
    }
}

// MARK: - 修改主密码（如实说明）

struct UmbraVaultPasswordView: View {
    @EnvironmentObject private var router: UmbraRouter

    var body: some View {
        UmbraSettingsPage(
            backLabel: "返回", title: "修改主密码", onBack: { router.back() },
            intro: "改主密码要重新派生密钥、把整份数据重新加密、换掉校验值，再一次性推上去。中途任何一步出错，数据就再也打不开了 —— 这个风险不该由手机端承担，所以只在电脑上做。",
            sections: [
                UmbraSettingSection(header: "在电脑上怎么做", footer: "改完之后手机这边会解锁失败，用新主密码重新解锁一次就行（Secret Key 不变）。", rows: [
                    UmbraSettingRow(label: "1. 打开电脑端的「密码保险箱 › 设置」"),
                    UmbraSettingRow(label: "2. 选「修改主密码」，输旧密码与新密码"),
                    UmbraSettingRow(label: "3. 等它重新加密并同步完成")
                ])
            ])
    }
}
