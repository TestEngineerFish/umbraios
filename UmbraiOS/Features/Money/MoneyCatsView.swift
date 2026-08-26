// 分类管理（money.cats）+ 单个分类的子类管理（money.cat，第二批落地）。
//
// 结构照稿：一级行**点进** money.cat（子类的看/加/改名/删都在那页），
// 行上左滑 = 改名 / 停用（批次 003 定稿的交互）；右上角 + 新增分类
// （先选记在哪一边，再起名字 —— 稿的两步弹层）。
//
// 三条不变的口径：
//   · slug 永不变，改名只改显示名，历史数据不动；
//   · 停用不是删除：选择器里不再出现，历史流水照旧归它，随时能恢复；
//     locked（其他 / 其他-收入）是兜底分类，不给停用；
//   · 子类只是**选择器候选**：加/改名/删都只影响以后记账 —— 流水里存的是
//     中文字符串，历史行一个字不动（稿把这句写进了每个确认弹层）。
import SwiftUI

struct UmbraMoneyCatsView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var money: MoneyStore

    @State private var renaming: MoneyCatDTO?
    @State private var renameText = ""
    /// 新增分类的第二步（第一步在底部选择器里选方向）。非 nil = 名字弹层开着。
    @State private var addingDir: String?
    @State private var addText = ""
    @State private var busy = false

    // 列表 = 系统 List + 系统 .swipeActions（提醒列表是模板，CLAUDE.md 有铁律）。
    var body: some View {
        List {
            catSection("支出", cats: money.cats.filter { $0.direction == "expense" && $0.enabled })
            catSection("收入", cats: money.cats.filter { $0.direction == "income" && $0.enabled })
            disabledSection
            Section {
                Text("点分类进子类管理；左滑分类行可以改名、停用。改名只改显示名，不影响历史数据 —— 流水里存的是稳定标识。停用的分类不再出现在选择器里，历史账目仍归它，统计不变。")
                    .font(UmbraFont.sans(12)).foregroundColor(UmbraColor.faint)
                    .lineSpacing(12 * 0.65)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UmbraColor.bg)
        .navigationTitle("分类管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { askAdd() } label: { Image(systemName: "plus") }
                    .tint(UmbraColor.orange)
            }
        }
        .refreshable { await money.reload(silent: true) }
        .onAppear { money.loadIfNeeded() }
        // iOS 16 的 alert 允许放 TextField —— 一个改名/起名不值一整张自定义弹层。
        .alert("重命名「\(renaming?.name ?? "")」", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("显示名", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") { commitRename() }
        } message: {
            Text("改名不影响历史数据。")
        }
        .alert("新增\(addingDir == "income" ? "收入" : "支出")分类", isPresented: Binding(
            get: { addingDir != nil },
            set: { if !$0 { addingDir = nil } }
        )) {
            TextField("分类名，例如「宠物」", text: $addText)
            Button("取消", role: .cancel) { addingDir = nil }
            Button("创建分类") { commitAdd() }
        } message: {
            // 批次 006 拍板：iOS 新建**不加图标步**（建分类常在记账中途发生，两步是上限），
            // 图标收进「换图标」；这句副文案要把「没丢东西，只是挪了地方」说出来。
            Text("先起个名字。图标和子类都能之后在分类管理里改。")
        }
    }

    /// 「换图标」sheet（批次 006 稿）：八格网格，当前项橙描边；选中即换、就地生效。
    /// 列表页左滑和 money.cat 右上菜单共用这一个入口。
    private func askIcon(_ c: MoneyCatDTO) {
        router.present(UmbraSheet(
            title: "换图标",
            subtitle: "只换样子，名字和已记的账不动。",
            icons: MoneyCatArt.pickList.map { p in
                UmbraSheetIcon(d: p.d, on: p.k == (c.icon ?? "")) {
                    run(toast: "已换成「\(p.label)」") {
                        await money.updateCat(slug: c.slug, icon: p.k)
                    }
                }
            }))
    }

    // MARK: 分组

    private func catSection(_ title: String, cats: [MoneyCatDTO]) -> some View {
        Section {
            ForEach(cats) { c in catRow(c) }
        } header: {
            Text(title).font(UmbraFont.sans(12, .w600)).foregroundColor(UmbraColor.faint)
                .textCase(nil)
        }
    }

    /// 一级行：**点进 money.cat**（稿 mcVM 的 open）；左滑 = 改名 / 停用。
    /// 兜底分类左滑只有改名 —— 没有停用键比「有键但点了报错」诚实。
    private func catRow(_ c: MoneyCatDTO) -> some View {
        Button { router.go(.moneyCat(slug: c.slug)) } label: {
            HStack(spacing: 11) {
                // 分类色块（批次 003）：同色 tint 底 + 色槽色描边图标。
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MoneyCatArt.tint(c.slot))
                    .frame(width: 34, height: 34)
                    .overlay(UmbraIcon(d: MoneyCatArt.icon(c.slug, stored: c.icon), size: 18, strokeWidth: 1.9)
                        .foregroundColor(MoneyCatArt.slotColor(c.slot)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(c.name).font(UmbraFont.sans(15, .w560)).foregroundColor(UmbraColor.text)
                        if c.locked {
                            Text("兜底分类")
                                .font(UmbraFont.sans(10.5, .w600)).foregroundColor(UmbraColor.faint)
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .background(Capsule().fill(UmbraColor.chip))
                        }
                    }
                    Text(meta(c)).font(UmbraFont.sans(12)).foregroundColor(UmbraColor.muted)
                }
                Spacer(minLength: 6)
                UmbraIcon(d: UmbraIconPath.chevronRight, size: 15, strokeWidth: 2.2)
                    .foregroundColor(UmbraColor.faint)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(UmbraColor.card)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !c.locked {
                Button { confirmDisable(c) } label: { Label("停用", systemImage: "nosign") }
                    .tint(UmbraColor.danger)
            }
            // 换图标（批次 006）：图标不进新建流程，入口就在这（和 money.cat 右上菜单）。
            Button { askIcon(c) } label: { Label("换图标", systemImage: "photo") }
                .tint(UmbraColor.orange)
            Button { startRename(c) } label: { Label("改名", systemImage: "pencil") }
                .tint(UmbraColor.warning)
        }
    }

    /// meta：子类数 + 本月笔数。「本月」两个字不能省 —— 手机上只有本月数据，
    /// 光写「N 笔账」会被读成历史总数。
    private func meta(_ c: MoneyCatDTO) -> String {
        let subs = c.subList.count
        let used = money.entries.filter { $0.cat == c.slug }.count
        let subText = subs > 0 ? "\(subs) 个子类" : "没有子类"
        return "\(subText) · 本月 \(used) 笔"
    }

    @ViewBuilder
    private var disabledSection: some View {
        let hidden = money.cats.filter { !$0.enabled }
        if !hidden.isEmpty {
            Section {
                ForEach(hidden) { c in
                    HStack(spacing: 11) {
                        // ban（圆 + 斜杠）：批次 003 新增的「停用」图标 ——
                        // 只表示停用，不表示失败（失败仍是 alert-circle）。
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(UmbraColor.chip)
                            .frame(width: 30, height: 30)
                            .overlay(UmbraIcon(d: UmbraIconPath.ban, size: 15, strokeWidth: 1.9)
                                .foregroundColor(UmbraColor.faint))
                        Text(c.name).font(UmbraFont.sans(15)).foregroundColor(UmbraColor.muted)
                        Spacer()
                        UmbraButton(title: "恢复", kind: .secondary, height: 32) {
                            run(toast: "已恢复「\(c.name)」") {
                                await money.updateCat(slug: c.slug, enabled: true)
                            }
                        }
                        .frame(width: 72)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(UmbraColor.card)
                }
            } header: {
                Text("已停用").font(UmbraFont.sans(12, .w600)).foregroundColor(UmbraColor.faint)
                    .textCase(nil)
            }
        }
    }

    // MARK: 新增分类（稿的两步：先选边，再起名）

    private func askAdd() {
        router.present(UmbraSheet(title: "新增分类", subtitle: "先选记在哪一边。", items: [
            UmbraSheetItem(label: "支出分类") { addText = ""; addingDir = "expense" },
            UmbraSheetItem(label: "收入分类") { addText = ""; addingDir = "income" },
        ]))
    }

    private func commitAdd() {
        guard let dir = addingDir else { return }
        let name = addText.trimmingCharacters(in: .whitespacesAndNewlines)
        addingDir = nil
        guard !name.isEmpty else { router.showToast("分类得有个名字"); return }
        // 重名先在本地拦（跨方向查 —— 两个「宠物」会让流水列表没法读）；服务端还有一道。
        guard !money.cats.contains(where: { $0.name == name }) else {
            router.showToast("已经有一个叫「\(name)」的分类了")
            return
        }
        run(toast: "已加上分类「\(name)」") {
            await money.createCat(name: name, direction: dir) != nil
        }
    }

    // MARK: 操作（左滑与 money.cat 页的菜单共用同一套函数，两个入口不会走岔）

    private func startRename(_ c: MoneyCatDTO) {
        renameText = c.name
        renaming = c
    }

    /// 停用前确认，文案按批次 003 定稿逐句抄；「N 笔账」补了「本月」限定 ——
    /// 手机上只有本月数据，报总数会是编的。
    private func confirmDisable(_ c: MoneyCatDTO) {
        let used = money.entries.filter { $0.cat == c.slug }.count
        router.confirm(UmbraAlert(
            title: "停用「\(c.name)」？",
            body: "以后记账选不到它。已经记在它下面的账照旧（本月 \(used) 笔），统计也不变。随时能在分类管理里恢复。",
            confirmLabel: "停用",
            confirmDestructive: true,
            onConfirm: {
                run(toast: "已停用「\(c.name)」，随时能在分类管理里恢复") {
                    await money.updateCat(slug: c.slug, enabled: false)
                }
            }))
    }

    private func commitRename() {
        guard let c = renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != c.name else { return }
        run(toast: "已改名为「\(name)」") {
            await money.updateCat(slug: c.slug, name: name)
        }
    }

    /// 统一的写操作壳：防连点 + 成败吐司。失败文案不甩锅给用户，只说下一步。
    private func run(toast: String, _ op: @escaping () async -> Bool) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            let ok = await op()
            busy = false
            router.showToast(ok ? toast : "没存上，检查网络后再试")
        }
    }
}

// MARK: - 单个分类（money.cat）：子类管理

/// 子类的看 / 加 / 改名 / 删（第二批，照稿 mcdVM）。右上角菜单里是分类级
/// 操作（改名 / 停用）—— 和列表页左滑**共用同一对语义**，只是入口不同。
struct UmbraMoneyCatDetailView: View {
    let slug: String

    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var money: MoneyStore

    /// 「N 笔在用」按全部历史数（服务端口径），进页拉一次、每次改动后重拉。
    /// 和列表页「本月 N 笔」是两个口径 —— 删除确认说的是这个子类名下一共有多少账。
    @State private var used: [String: Int] = [:]
    @State private var renamingSub: String?
    @State private var renameText = ""
    @State private var adding = false
    @State private var addText = ""
    @State private var renamingCat = false
    @State private var catNameText = ""
    @State private var busy = false

    private var cat: MoneyCatDTO? { money.cats.first { $0.slug == slug } }
    private var subs: [String] { cat?.subList ?? [] }

    // body 拆成小块不是洁癖：原来 List + 八个修饰符 + 三张带 TextField 的 alert
    // 连成一条链，Swift 对整条链一次性做类型推导，编译器直接报「type-check 超时」。
    // 列表一块、右上角按钮一块、每张 alert 的按钮各一块，每段都在编译器的能力圈内。
    var body: some View {
        listBody
            .navigationTitle(cat?.name ?? "分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { trailingButtons }
            }
            .refreshable { await money.reload(silent: true); await loadUsed() }
            .task { await loadUsed() }
            .alert("新增子类", isPresented: $adding) {
                addAlertButtons
            } message: {
                Text("加在「\(cat?.name ?? "")」下面。")
            }
            .alert("子类改名", isPresented: Binding(
                get: { renamingSub != nil },
                set: { if !$0 { renamingSub = nil } }
            )) {
                renameSubAlertButtons
            } message: {
                Text("只影响以后记账，已经记下的账目还写着「\(renamingSub ?? "")」。")
            }
            .alert("分类改名", isPresented: $renamingCat) {
                renameCatAlertButtons
            } message: {
                Text("改名不影响历史数据。")
            }
    }

    private var listBody: some View {
        List {
            if subs.isEmpty {
                Section {
                    Text("还没有子类。右上角 + 加一个 —— 记账时它会出现在分类下面的一排小胶囊里。")
                        .font(UmbraFont.sans(13)).foregroundColor(UmbraColor.faint)
                        .lineSpacing(13 * 0.6)
                        .listRowBackground(UmbraColor.card)
                }
            } else {
                Section {
                    ForEach(subs, id: \.self) { s in subRow(s) }
                }
            }
            Section {
                Text(footerText)
                    .font(UmbraFont.sans(12)).foregroundColor(UmbraColor.faint)
                    .lineSpacing(12 * 0.65)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UmbraColor.bg)
    }

    private var trailingButtons: some View {
        HStack(spacing: 2) {
            Button { addText = ""; adding = true } label: { Image(systemName: "plus") }
                .tint(UmbraColor.orange)
            Button { openMenu() } label: { Image(systemName: "ellipsis.circle") }
                .tint(UmbraColor.muted)
        }
    }

    @ViewBuilder private var addAlertButtons: some View {
        TextField("子类名，例如「夜宵」", text: $addText)
        Button("取消", role: .cancel) { adding = false }
        Button("加上") { commitAddSub() }
    }

    @ViewBuilder private var renameSubAlertButtons: some View {
        TextField("新名字", text: $renameText)
        Button("取消", role: .cancel) { renamingSub = nil }
        Button("改名") { commitRenameSub() }
    }

    @ViewBuilder private var renameCatAlertButtons: some View {
        TextField("显示名", text: $catNameText)
        Button("取消", role: .cancel) { renamingCat = false }
        Button("保存") { commitRenameCat() }
    }

    /// 页脚照稿的意思，「N 笔账」带「本月」限定（手机上只有本月数据，同分类管理）。
    private var footerText: String {
        let n = money.entries.filter { $0.cat == slug }.count
        return "左滑一行可以改名或删除。「\(cat?.name ?? "")」名下本月有 \(n) 笔账，改名、删子类、停用分类都不会动它们。"
    }

    private func subRow(_ s: String) -> some View {
        HStack(spacing: 10) {
            Text(s).font(UmbraFont.sans(15)).foregroundColor(UmbraColor.text)
            Spacer()
            Text(usedText(s)).font(UmbraFont.sans(12)).foregroundColor(UmbraColor.faint)
        }
        .padding(.vertical, 6)
        .listRowBackground(UmbraColor.card)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { confirmDeleteSub(s) } label: { Label("删除", systemImage: "trash") }
                .tint(UmbraColor.danger)
            Button { renameText = s; renamingSub = s } label: { Label("改名", systemImage: "pencil") }
                .tint(UmbraColor.warning)
        }
    }

    private func usedText(_ s: String) -> String {
        let n = used[s] ?? 0
        return n > 0 ? "\(n) 笔在用" : "还没用过"
    }

    private func loadUsed() async {
        guard let items = await HTTPService.shared.fetchMoneySubsUsed(cat: slug) else { return }
        used = Dictionary(uniqueKeysWithValues: items.map { ($0.label, $0.used) })
    }

    // MARK: 子类操作（文案照稿 mcdVM 逐句）

    private func commitAddSub() {
        adding = false
        let label = addText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { router.showToast("子类得有个名字"); return }
        guard !subs.contains(label) else { router.showToast("「\(label)」已经在这个分类里了"); return }
        run(toast: "已加上「\(label)」") { await money.addSub(cat: slug, label: label) }
    }

    private func commitRenameSub() {
        guard let old = renamingSub else { return }
        renamingSub = nil
        let new = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty else { router.showToast("名字不能空着"); return }
        guard new != old else { return }
        guard !subs.contains(new) else { router.showToast("「\(new)」已经在这个分类里了"); return }
        run(toast: "已改成「\(new)」") { await money.renameSub(cat: slug, old: old, new: new) }
    }

    private func confirmDeleteSub(_ s: String) {
        let n = used[s] ?? 0
        router.confirm(UmbraAlert(
            title: "删掉子类「\(s)」？",
            body: n > 0 ? "有 \(n) 笔账记在这个子类上，它们不会变，只是以后记账选不到了。"
                        : "以后记账就选不到它了。",
            confirmLabel: "删除",
            confirmDestructive: true,
            onConfirm: {
                run(toast: "已删掉「\(s)」") { await money.deleteSub(cat: slug, label: s) }
            }))
    }

    // MARK: 分类级操作（右上角菜单，语义同列表页左滑）

    /// 分类改名（补上原来只被 alert 引用、忘了写的定义）。
    /// 校验口径与列表页 commitRename 一致：空名/没改不动；toast 同一句。
    private func commitRenameCat() {
        renamingCat = false
        guard let c = cat else { return }
        let name = catNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != c.name else { return }
        run(toast: "已改名为「\(name)」") { await money.updateCat(slug: slug, name: name) }
    }

    private func openMenu() {
        guard let c = cat else { return }
        var items: [UmbraSheetItem] = [
            UmbraSheetItem(label: "分类改名", note: "不影响历史数据") {
                catNameText = c.name
                renamingCat = true
            },
            // 换图标（批次 006）。sheet 里再开 sheet 要等上一层的收起动画走完 ——
            // 系统 sheet 在 dismiss 进行中收到新 present 会**静默丢弃**（真机踩过的类坑），
            // 所以延迟一拍再开，稿的原型里也是这么做的。
            UmbraSheetItem(label: "换图标", note: "只换样子，历史不变") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { askIcon(c) }
            },
        ]
        if !c.locked {
            items.append(UmbraSheetItem(label: "停用这个分类", note: "选择器里不再出现，历史不变",
                                        destructive: true) {
                confirmDisableCat(c)
            })
        }
        router.present(UmbraSheet(title: c.name, items: items))
    }

    /// 「换图标」（批次 006，和列表页左滑同一张 sheet；用本页的 run 收尾）。
    private func askIcon(_ c: MoneyCatDTO) {
        router.present(UmbraSheet(
            title: "换图标",
            subtitle: "只换样子，名字和已记的账不动。",
            icons: MoneyCatArt.pickList.map { p in
                UmbraSheetIcon(d: p.d, on: p.k == (c.icon ?? "")) {
                    run(toast: "已换成「\(p.label)」") {
                        await money.updateCat(slug: slug, icon: p.k)
                    }
                }
            }))
    }

    private func confirmDisableCat(_ c: MoneyCatDTO) {
        let used = money.entries.filter { $0.cat == c.slug }.count
        router.confirm(UmbraAlert(
            title: "停用「\(c.name)」？",
            body: "以后记账选不到它。已经记在它下面的账照旧（本月 \(used) 笔），统计也不变。随时能在分类管理里恢复。",
            confirmLabel: "停用",
            confirmDestructive: true,
            onConfirm: {
                run(toast: "已停用「\(c.name)」") {
                    let ok = await money.updateCat(slug: c.slug, enabled: false)
                    // 稿 mCatDisable(back:true)：从 money.cat 停用后退回列表 ——
                    // 停用的分类不该继续停在它自己的编辑页上。
                    if ok { router.back() }
                    return ok
                }
            }))
    }

    private func run(toast: String, _ op: @escaping () async -> Bool) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            let ok = await op()
            busy = false
            router.showToast(ok ? toast : "没存上，检查网络后再试")
            if ok { await loadUsed() }
        }
    }
}
