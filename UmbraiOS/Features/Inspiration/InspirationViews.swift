// 灵感 · 列表（insp.list）/ 详情（insp.detail）/ 编辑（insp.edit）。
//
// 数据来自既有的 InspirationsViewModel（GET/POST/PATCH/DELETE /inspirations）。
// 服务端的状态取值是 open / done / archived；设计稿写的是 todo / done / archived，
// 「待办」对应 open。这里以**服务端取值**为准，界面文案用设计稿的中文。
//
// 设计稿里有、服务端没有的：「关联任务」（Inspiration 结构里没有 task_id）。
// 那一节整块不画 —— 画一个永远为空的分节等于告诉用户功能坏了。
import SwiftUI

// MARK: - 列表

struct UmbraInspirationListView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var insp: InspirationsViewModel

    /// "" = 全部
    @State private var status = ""
    @State private var tag: String? = nil
    @State private var query = ""
    @State private var sort = UmbraInspSort.recent
    /// 搜索框焦点放在页面上（不塞组件里）：「点空白处收键盘」得由页面来收。
    @FocusState private var searchFocused: Bool

    var body: some View {
        UmbraScreen {
            UmbraFilterChips(items: statusChips, selection: $status)
                .padding(.top, 2)
                .padding(.bottom, 10)

            tagRow

            // 默认收成一个搜索图标，点开才占一行（用户点名；任务列表同款）。
            UmbraCollapsingSearch(placeholder: "搜索灵感", text: $query,
                                  trailingNote: sort.label, focused: $searchFocused)
                .padding(.horizontal, UmbraMetric.pagePadX)
                .padding(.bottom, UmbraMetric.sp4)

            if rows.isEmpty {
                // 原来一句「这个筛选下还没有灵感」通吃两个态，而正文讲的却是「怎么开始」——
                // 一个人明明只是搜了个词没搜到，却被教了一遍怎么记灵感。
                // `states.emptyVsNoResult`：空态说「怎么开始」，无结果说「改什么条件」。
                if isFiltered {
                    UmbraEmptyState(
                        iconPath: UmbraIconPath.filter,
                        title: searchQ.isEmpty ? "这个筛选下没有灵感" : "没有匹配「\(searchQ)」的灵感",
                        hint: "灵感是有的，只是不符合当前的状态、标签或关键词。",
                        actionTitle: "清掉筛选",
                        // 三个筛选条件一起清 —— 只清一个的话人点完还是空屏，
                        // 会以为按钮坏了。
                        action: { query = ""; tag = nil; status = "" })
                } else {
                    UmbraEmptyState(
                        iconPath: UmbraIconPath.bulb,
                        title: "还没有灵感",
                        hint: "在任意端发一条「记个灵感：…」，秘书会自动补标题和标签；也可以点右上角手动添加。",
                        actionTitle: "记一条灵感",
                        action: { router.go(.inspEdit(id: nil)) })
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(rows) { i in card(i) }
                }
                .padding(.horizontal, UmbraMetric.pagePadX)

            }
        }
        .navigationTitle("灵感")
        // 骨架规矩 `iosShell.titleMode`：**按「是不是 tab 根屏」分，不看内容多少**。
        // 灵感是从工具页推出来的，是 push 屏 → 内联标题。不写的话它会跟着上级根屏
        // 继承成大标题，同一个 tab 里就出现「有的屏有大标题、有的没有」，人会以为换了地方。
        .navigationBarTitleDisplayMode(.inline)
        // 列表页不参与键盘避让：搜索框在页面上方用不着避让，
        // 反而搜索键盘收起后底部 inset 可能留着不走，让页面短一截（同保险箱首页的坑）。
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // 点内容区任意空白收键盘。只在真有焦点时动手，不和别的点击抢。
        .simultaneousGesture(TapGesture().onEnded { if searchFocused { searchFocused = false } })
        // 右侧动作组的顺序是规矩不是习惯（`iosShell.toolbar.right`）：
        // 从右往左固定 ⋯ 更多 → 齿轮 → 次级 0–1 颗 → 主动作 1 颗，缺哪项空哪项、剩下的不移。
        // 所以**主动作「＋」写在前（更靠左），次级「排序」写在后（更靠右）** ——
        // SwiftUI 的 topBarTrailing 是按声明顺序从左往右排的，原来两块的顺序正好是反的。
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.go(.inspEdit(id: nil)) } label: { Image(systemName: "plus") }
                    .tint(UmbraColor.orange)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // 排序 = 系统 Menu 锚定弹出（≤6 项纯选择不用底部弹层）。
                Menu {
                    ForEach(UmbraInspSort.allCases, id: \.self) { o in
                        Button {
                            sort = o
                        } label: {
                            if sort == o { Label(o.label, systemImage: "checkmark") } else { Text(o.label) }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .tint(UmbraColor.orange)
            }
        }
        .refreshable { await insp.refresh() }
        .onAppear { insp.startPolling() }
        .onDisappear { insp.stopPolling() }
    }

    // MARK: 筛选

    private var statusChips: [UmbraFilterChips<String>.Item] {
        [("", "全部"), ("open", "待办"), ("done", "已实现"), ("archived", "归档")].map { key, label in
            .init(value: key, label: label,
                  count: key.isEmpty ? insp.list.count : insp.list.filter { $0.status == key }.count)
        }
    }

    private var allTags: [String] {
        var seen: [String] = []
        for i in insp.list {
            for t in i.tags where !seen.contains(t) { seen.append(t) }
        }
        return seen
    }

    @ViewBuilder
    private var tagRow: some View {
        if !allTags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    Text("标签")
                        .font(UmbraFont.sans(11.5, .w600))
                        .tracking(UmbraFont.labelTracking(11.5))
                        .foregroundColor(UmbraColor.faint)
                    ForEach(allTags, id: \.self) { t in
                        UmbraTagPill(text: t, selected: tag == t) { tag = (tag == t) ? nil : t }
                    }
                    if tag != nil {
                        Button { tag = nil } label: {
                            Text("清除")
                                .font(UmbraFont.sans(12.5, .w560))
                                .foregroundColor(UmbraColor.orange)
                                .padding(.horizontal, 10)
                                .frame(height: UmbraMetric.tapMin)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, UmbraMetric.pagePadX)
            }
            .padding(.bottom, 10)
        }
    }

    /// 去空白后的搜索词。空态文案和 `isFiltered` 都要用，别在两处各 trim 一遍。
    private var searchQ: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 这一屏空，是「真没有」还是「被条件挡住了」。三个条件任一生效都算被挡住。
    private var isFiltered: Bool { !searchQ.isEmpty || tag != nil || !status.isEmpty }

    private var rows: [Inspiration] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = insp.list.filter { i in
            if !status.isEmpty && i.status != status { return false }
            if let t = tag, !i.tags.contains(t) { return false }
            if !q.isEmpty && !(i.title + i.raw + i.summary).localizedCaseInsensitiveContains(q) { return false }
            return true
        }
        switch sort {
        case .recent: break                       // 服务端已经按最近记录排好
        case .updated: out.sort { ($0.updated_at ?? "") > ($1.updated_at ?? "") }
        case .tag: out.sort { ($0.tags.first ?? "") < ($1.tags.first ?? "") }
        }
        return out
    }

    private func openSort() {
        router.present(UmbraSheet(title: "排序", items: UmbraInspSort.allCases.map { s in
            UmbraSheetItem(label: s.label, checked: sort == s) { sort = s }
        }))
    }

    // MARK: 卡片

    private func card(_ i: Inspiration) -> some View {
        Button {
            router.go(.inspDetail(id: String(i.id)))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: UmbraMetric.sp3) {
                    // 标题空着时用原文前 20 字顶着（displayTitle）——
                    // 手动记的条目要等后台补整理，这几秒里显示「（还没有标题）」
                    // 会让人以为没记上。
                    Text(i.displayTitle)
                        .font(UmbraFont.sans(16, .w560))
                        .foregroundColor(UmbraColor.text)
                        .lineSpacing(16 * 0.4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if i.status != "open" { statusBadge(i.status) }
                }

                Text(i.summary.isEmpty ? i.raw : i.summary)
                    .font(UmbraFont.sans(14, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineSpacing(14 * 0.55)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    // 后台正在补标题/标签时给一个轻提示，免得用户以为标签功能坏了。
                    if i.organizeState == "pending" { softChip("整理中") }
                    if i.researchInFlight { softChip("调研中") }
                    ForEach(i.tags, id: \.self) { t in
                        Text(t)
                            .font(UmbraFont.sans(11.5, .w400))
                            .foregroundColor(UmbraColor.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(UmbraColor.chip))
                    }
                    Spacer(minLength: 0)
                    Text("\(sourceLabel(i.source_channel)) · \(UmbraTime.relative(i.created_at))")
                        .font(UmbraFont.sans(11.5, .w400))
                        .foregroundColor(UmbraColor.faint)
                }
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
        // 长按 = 快捷菜单。v2 换系统 contextMenu：锚定卡片、带预览缩放，
        // 破坏性项系统自动红色；删除仍必进确认弹窗。
        .contextMenu {
            Button {
                Task { await insp.setStatus(id: i.id, status: i.status == "done" ? "open" : "done") }
            } label: {
                Label(i.status == "done" ? "标回待办" : "标记已实现", systemImage: "checkmark.circle")
            }
            Button {
                Task { await insp.setStatus(id: i.id, status: i.status == "archived" ? "open" : "archived") }
            } label: {
                Label(i.status == "archived" ? "取消归档" : "归档", systemImage: "archivebox")
            }
            Button {
                router.go(.inspEdit(id: String(i.id)))
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive) {
                router.confirm(UmbraAlert(
                    title: "确认删除这条灵感？",
                    body: "删除后移入回收站，保留 30 天，之后彻底删除。",
                    confirmLabel: "移入回收站",
                    confirmDestructive: true,
                    onConfirm: {
                        Task { await insp.delete(id: i.id) }
                        router.showToast("已移入回收站 · 保留 30 天")
                    }))
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 「整理中 / 调研中」这类进行时提示。刻意用 faint 字 + chip 底：
    /// 它是状态说明，不是标签，不该和用户自己打的标签抢注意力。
    private func softChip(_ text: String) -> some View {
        Text(text)
            .font(UmbraFont.sans(11.5, .w400))
            .foregroundColor(UmbraColor.faint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(UmbraColor.chip))
    }

    private func statusBadge(_ s: String) -> some View {
        let (label, bg, fg) = UmbraInspStatus.chrome(s)
        return Text(label)
            .font(UmbraFont.sans(11, .w600))
            .foregroundColor(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
    }


    /// 来源渠道 → 中文。认不出来的照原样显示，不要一律写成「未知来源」——
    /// 服务端以后加了新渠道，原样显示至少还能看出是什么。
    private func sourceLabel(_ raw: String?) -> String {
        switch raw {
        case "chat", "assistant": return "聊天"
        case "ios", "mobile": return "手机端"
        case "pc", "desktop": return "电脑端"
        case "hotkey": return "快捷键"
        case .none, .some(""): return "未知来源"
        case .some(let s): return s
        }
    }
}

enum UmbraInspSort: CaseIterable, Hashable {
    case recent, updated, tag
    var label: String {
        switch self {
        case .recent: return "最近记录"
        case .updated: return "最近更新"
        case .tag: return "标签分组"
        }
    }
}

enum UmbraInspStatus {
    /// 状态 → （中文, 底色, 字色）。open 也给一份，详情页要显示「待办」徽标。
    static func chrome(_ s: String) -> (String, Color, Color) {
        switch s {
        case "done": return ("已实现", UmbraColor.successSoft, UmbraColor.success)
        case "archived": return ("归档", UmbraColor.chip, UmbraColor.faint)
        default: return ("待办", UmbraColor.warningSoft, UmbraColor.warning)
        }
    }
}

// MARK: - 详情

struct UmbraInspirationDetailView: View {
    let id: String

    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var insp: InspirationsViewModel
    @EnvironmentObject private var chat: ChatViewModel

    private var item: Inspiration? { insp.list.first { String($0.id) == id } }

    /// 编辑草稿。非 nil = 编辑态。**就地编辑**：同页切换，不推新页（v2 交接清单）。
    @State private var dRaw = ""
    @State private var dTitle = ""
    @State private var dTags = ""
    @State private var editing = false

    var body: some View {
        UmbraScreen(content: {
            if editing {
                UmbraInspForm(raw: $dRaw, title: $dTitle, tagsText: $dTags,
                              allTags: allTags, isNew: false)
            } else if let i = item {
                content(i)
            } else {
                missing
            }
        }, bottom: {
            if !editing, let i = item { bottomBar(i) }
        })
        .navigationTitle(editing ? "编辑灵感" : "灵感详情")
        .navigationBarTitleDisplayMode(.inline)
        // 编辑态藏系统返回：会丢改动的出口只留「取消」一个。
        .navigationBarBackButtonHidden(editing)
        .toolbar {
            if editing {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { editing = false }
                        .tint(UmbraColor.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { saveEdit() } label: {
                        Text("保存").font(UmbraFont.sans(16, .w600))
                    }
                    .tint(UmbraColor.orange)
                }
            } else if let i = item {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("编辑") { startEdit(i) }
                        .tint(UmbraColor.orange)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // 「⋯」。破坏性操作不占详情页底部，收进这里 —— iOS 增补规范的硬规则。
                    Menu {
                        Button(role: .destructive) {
                            router.confirm(UmbraAlert(
                                title: "确认删除这条灵感？",
                                body: "删除后移入回收站，保留 30 天，之后彻底删除。",
                                confirmLabel: "移入回收站",
                                confirmDestructive: true,
                                onConfirm: {
                                    Task { await insp.delete(id: i.id) }
                                    router.back()
                                    router.showToast("已移入回收站 · 保留 30 天")
                                }))
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .tint(UmbraColor.orange)
                }
            }
        }
        // 只在「有活儿在跑」时开轮询。主渠道其实是 WS 的 inspiration_updated
        // （ChatViewModel 收到后发 .inspirationChanged，VM 就地重载），
        // 轮询是**兜底** —— socket 断了或恰好在重连时，用户会干等一个几十秒的调研
        // 却什么都不动。没活儿在跑的时候常开轮询纯属浪费电，所以按需开关。
        .onAppear {
            Task { await insp.load() }
            if item?.researchInFlight == true || item?.organizeState == "pending" {
                insp.startPolling()
            }
        }
        // 两参数版是 iOS 17 起的写法（工程 target 17.0），别照着老文件改回单参数版——
        // 那个在 17 上是 deprecated。
        .onChange(of: watching) { _, now in
            if now { insp.startPolling() } else { insp.stopPolling() }
        }
        .onDisappear { insp.stopPolling() }
    }

    /// 有没有后台活儿在跑（调研排队/进行中，或标题还没补上）。
    private var watching: Bool {
        guard let i = item else { return false }
        return i.researchInFlight || i.organizeState == "pending"
    }

    private var allTags: [String] {
        var seen: [String] = []
        for i in insp.list {
            for t in i.tags where !seen.contains(t) { seen.append(t) }
        }
        return seen
    }

    private func startEdit(_ i: Inspiration) {
        dRaw = i.raw
        dTitle = i.title
        dTags = i.tags.joined(separator: "，")
        editing = true
    }

    private func saveEdit() {
        guard let i = item else { editing = false; return }
        let body = dRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { router.showToast("内容不能是空的"); return }
        let tags = UmbraInspForm.parseTags(dTags)
        Task { await insp.update(id: i.id, raw: body,
                                 title: dTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                                 tags: tags, note: i.summary) }
        editing = false
        router.showToast("已保存")
    }

    /// 灵感被别的端删了：如实说明并给出口，而不是留一个空白页。
    private var missing: some View {
        UmbraEmptyState(
            iconPath: UmbraIconPath.bulb,
            title: "这条灵感不在了",
            hint: "可能是在别的设备上删掉了。",
            actionTitle: "回到灵感列表",
            action: { router.back() })
    }

    @ViewBuilder
    private func content(_ i: Inspiration) -> some View {
        let (label, bg, fg) = UmbraInspStatus.chrome(i.status)

        VStack(alignment: .leading, spacing: UmbraMetric.sp3) {
            Text(i.displayTitle)
                .font(UmbraFont.sans(23, .w600))
                .foregroundColor(UmbraColor.text)
                .lineSpacing(23 * 0.4)
            HStack(spacing: 7) {
                Text(label)
                    .font(UmbraFont.sans(11.5, .w600))
                    .foregroundColor(fg)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(bg))
                Text(UmbraTime.absolute(i.created_at))
                    .font(UmbraFont.sans(12.5, .w400))
                    .foregroundColor(UmbraColor.faint)
            }
        }
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.top, UmbraMetric.sp6)
        .padding(.bottom, 16)

        section("原文") {
            Text(i.raw)
                .font(UmbraFont.sans(15.5, .w400))
                .foregroundColor(UmbraColor.text)
                .lineSpacing(15.5 * 0.65)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
                .overlay(
                    RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                        .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                )
        }

        // 秘书整理是异步补的。**正在补的时候要说一句**：手动记完立刻进详情，
        // 这一节空着会让人以为没在整理，转头就手动去填标题了。
        if i.summary.isEmpty && i.organizeState == "pending" {
            section("秘书整理") {
                HStack(spacing: 9) {
                    ProgressView().scaleEffect(0.8).tint(UmbraColor.orange)
                    Text("秘书正在补标题和标签…")
                        .font(UmbraFont.sans(14, .w400))
                        .foregroundColor(UmbraColor.muted)
                    Spacer(minLength: 0)
                }
            }
        } else if !i.summary.isEmpty {
            section("秘书整理") {
                Text(i.summary)
                    .font(UmbraFont.sans(15, .w400))
                    .foregroundColor(UmbraColor.text)
                    .lineSpacing(15 * 0.65)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
                    .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.orangeSoft))
            }
        }

        researchSection(i)

        section("标签") {
            if i.tags.isEmpty {
                Text("还没有标签。编辑里可以加。")
                    .font(UmbraFont.sans(13, .w400))
                    .foregroundColor(UmbraColor.muted)
            } else {
                // 标签不多，横着排就行；一行放不下 SwiftUI 会自己压缩，所以用可滚动的一行。
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(i.tags, id: \.self) { t in
                            Text(t)
                                .font(UmbraFont.sans(13, .w400))
                                .foregroundColor(UmbraColor.muted)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(UmbraColor.chip))
                        }
                    }
                }
            }
        }
    }

    // MARK: 调研
    //
    // 四个状态各画各的，**不合并成一个「有内容就显示」**：
    // 「还没查过」和「查了但失败了」对用户是完全不同的两件事，前者该给按钮，
    // 后者该说清楚为什么、再给重试。合成一个的话失败会静默成「没查过」。
    @ViewBuilder
    private func researchSection(_ i: Inspiration) -> some View {
        section("秘书调研") {
            switch i.researchState {
            case "queued", "running":
                HStack(spacing: 9) {
                    ProgressView().scaleEffect(0.8).tint(UmbraColor.orange)
                    Text(i.researchState == "queued" ? "排队中，马上开始…" : "正在查，通常几十秒。可以先去别处，回来再看。")
                        .font(UmbraFont.sans(14, .w400))
                        .foregroundColor(UmbraColor.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(13)
                .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))

            case "done" where !i.researchText.isEmpty:
                VStack(alignment: .leading, spacing: 10) {
                    // 服务端产出的是 Markdown（要点 + 链接），直接复用聊天那套渲染器。
                    UmbraMarkdownText(raw: i.researchText, size: 15)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(i.research_at.map { "查于 " + UmbraTime.relative($0) } ?? "")
                            .font(UmbraFont.sans(11.5, .w400))
                            .foregroundColor(UmbraColor.faint)
                        Spacer(minLength: 0)
                        Button("重新查一次") { research(i) }
                            .font(UmbraFont.sans(12.5, .w560))
                            .tint(UmbraColor.orange)
                    }
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
                .overlay(
                    RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                        .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                )

            case "failed":
                VStack(alignment: .leading, spacing: 9) {
                    // 失败原因是服务端写进 research 字段的（没配搜索 key？模型限流？）——
                    // 原样显示，别翻译成「出错了」这种等于没说的话。
                    Text(i.researchText.isEmpty ? "调研没能完成。" : i.researchText)
                        .font(UmbraFont.sans(14, .w400))
                        .foregroundColor(UmbraColor.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    UmbraButton(title: "再试一次", kind: .secondary, height: 40) { research(i) }
                }
                .padding(13)
                .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
                .overlay(
                    RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                        .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                )

            default:
                VStack(alignment: .leading, spacing: 9) {
                    Text("让秘书上网摸个底：已经有什么现成的、坑在哪、值不值得做。几条要点加参考链接，不写长报告。")
                        .font(UmbraFont.sans(13.5, .w400))
                        .foregroundColor(UmbraColor.muted)
                        .lineSpacing(13.5 * 0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    UmbraButton(title: "帮我查查", kind: .secondary, height: 40) { research(i) }
                }
            }
        }
    }

    private func research(_ i: Inspiration) {
        Task { await insp.requestResearch(id: i.id) }
        router.showToast("已交给秘书，查完会更新到这里")
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: UmbraMetric.sp2) {
            UmbraFieldLabel(text: title)
            content()
        }
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.bottom, 16)
    }

    private func bottomBar(_ i: Inspiration) -> some View {
        VStack(spacing: 7) {
            UmbraButton(title: "让 Umbra 去做这件事", kind: .primary) {
                // 跳到与秘书的会话，挂「创建任务」芯片 + 填灵感原文 + 亮来源横幅
                //（批次 005：模式撤了，预填走芯片）。**不自动发送** —— 发之前让用户
                // 能改一句，这是 PC 端定下的行为。横幅本身就是「填好了」的反馈，
                // 原来的 toast 撤掉 —— 两个提示叠着说同一句话。
                chat.prefillTaskFromIdea(
                    i.raw.isEmpty ? i.title : i.raw,
                    sourceTitle: i.title.isEmpty ? String(i.raw.prefix(18)) : i.title)
                router.jump(.chatThread(conv: ChatViewModel.mainConv))
            }
            HStack(spacing: 8) {
                UmbraButton(title: i.status == "done" ? "标回待办" : "标记已实现", kind: .secondary, height: 44) {
                    Task { await insp.setStatus(id: i.id, status: i.status == "done" ? "open" : "done") }
                }
                UmbraButton(title: i.status == "archived" ? "取消归档" : "归档", kind: .secondary, height: 44) {
                    Task { await insp.setStatus(id: i.id, status: i.status == "archived" ? "open" : "archived") }
                }
            }
        }
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.top, 10)
        .padding(.bottom, UmbraMetric.sp5)
        .background(UmbraColor.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
        }
    }
}

// MARK: - 编辑（新建）
//
// 编辑已有灵感走详情页的就地编辑；这个页面只服务「记一条新的」。
// 路由仍接受 id（兼容旧入口），带 id 进来也能编。

struct UmbraInspirationEditView: View {
    /// nil = 新建
    let id: String?

    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var insp: InspirationsViewModel

    @State private var raw = ""
    @State private var title = ""
    @State private var tagsText = ""
    @State private var loaded = false
    @State private var research = false

    private var existing: Inspiration? {
        guard let id else { return nil }
        return insp.list.first { String($0.id) == id }
    }

    private var canSave: Bool { !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var allTags: [String] {
        var seen: [String] = []
        for i in insp.list {
            for t in i.tags where !seen.contains(t) { seen.append(t) }
        }
        return seen
    }

    var body: some View {
        UmbraScreen {
            UmbraInspForm(raw: $raw, title: $title, tagsText: $tagsText,
                          allTags: allTags, isNew: id == nil, research: $research)
        }
        .navigationTitle(id == nil ? "记一条灵感" : "编辑灵感")
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
            guard !loaded else { return }
            loaded = true
            if let e = existing {
                raw = e.raw
                title = e.title
                tagsText = e.tags.joined(separator: "，")
            }
        }
    }

    private func save() {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空内容点保存 → toast 说原因，不在页面上常驻一行小字（用户点名删）。
        guard !body.isEmpty else { router.showToast("内容还是空的，写点什么才能存"); return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = UmbraInspForm.parseTags(tagsText)
        if let e = existing {
            Task { await insp.update(id: e.id, raw: body, title: name, tags: tags, note: e.summary) }
        } else {
            Task { await insp.create(raw: body, title: name, tags: tags, note: "", research: research) }
        }
        router.back()
        // 没填标题的话，后台会补 —— 明说一句，免得用户回到列表看见原文当标题以为存错了。
        router.showToast(research ? "已记下，秘书这就去查"
                                  : (name.isEmpty ? "已记下，秘书稍后补标题" : "已保存"))
    }
}

// MARK: - 表单（详情就地编辑与新建共用）

struct UmbraInspForm: View {
    @Binding var raw: String
    @Binding var title: String
    @Binding var tagsText: String
    /// 现有全部标签，供 chips 点选（交接清单：标签输入框上方列已有标签）。
    let allTags: [String]
    let isNew: Bool
    /// 「顺便查一查」。只在新建时出现——改一条已有灵感时想查，
    /// 详情页有「帮我查查」按钮，在这儿再放一个只会让人搞不清点了会不会重查。
    var research: Binding<Bool>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: UmbraMetric.sp6) {
            field("内容") {
                TextField("想到什么就写什么，不用组织语言。", text: $raw, axis: .vertical)
                    .font(UmbraFont.sans(16, .w400))
                    .lineSpacing(16 * 0.65)
                    .lineLimit(6...12)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .frame(minHeight: 150, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusInput, style: .continuous).fill(UmbraColor.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: UmbraMetric.radiusInput, style: .continuous)
                            .strokeBorder(UmbraColor.borderSoft, lineWidth: UmbraMetric.borderW)
                    )
            }
            field("标题") { input("留空由秘书补", text: $title) }
            field("标签") {
                VStack(alignment: .leading, spacing: UmbraMetric.sp2) {
                    // 已有标签 chips：点选切换，写进输入框（选中 = 橙 soft 底 + 橙描边）。
                    if !allTags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(allTags.prefix(10), id: \.self) { t in
                                    let on = Self.parseTags(tagsText).contains(t)
                                    Button {
                                        var cur = Self.parseTags(tagsText)
                                        if on { cur.removeAll { $0 == t } } else { cur.append(t) }
                                        tagsText = cur.joined(separator: "，")
                                    } label: {
                                        Text(t)
                                            .font(UmbraFont.sans(12.5, .w400))
                                            .foregroundColor(on ? UmbraColor.orangeText : UmbraColor.muted)
                                            .padding(.horizontal, 11)
                                            .padding(.vertical, 5)
                                            .background(Capsule().fill(on ? UmbraColor.orangeSoft : UmbraColor.card))
                                            .overlay(Capsule().strokeBorder(on ? UmbraColor.orange : UmbraColor.border,
                                                                            lineWidth: UmbraMetric.borderW))
                                            .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    input("逗号分隔，可留空", text: $tagsText)
                }
            }

            if isNew, let research { researchToggle(research) }
        }
        .padding(UmbraMetric.pagePadX)
    }

    /// **默认关**（2026-08-08 与用户确认）：每条都自动查会烧 token，还会把灵感列表
    /// 变成一堆没人读的半成品报告。所以这里是「想查再勾」，不是「不想查再取消」。
    private func researchToggle(_ on: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: UmbraMetric.sp3) {
            VStack(alignment: .leading, spacing: 3) {
                Text("顺便查一查")
                    .font(UmbraFont.sans(15.5, .w560))
                    .foregroundColor(UmbraColor.text)
                Text("记完之后让秘书上网摸个底，几条要点加参考链接。也可以之后在详情里随时点。")
                    .font(UmbraFont.sans(12.5, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineSpacing(12.5 * 0.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            UmbraSwitch(on: on.wrappedValue) { on.wrappedValue.toggle() }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
        .overlay(
            RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
        )
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
            .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusInput, style: .continuous).fill(UmbraColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusInput, style: .continuous)
                    .strokeBorder(UmbraColor.borderSoft, lineWidth: UmbraMetric.borderW)
            )
    }

    /// 标签串 → 数组。全角逗号、半角逗号、顿号都当分隔符 ——
    /// 输入法给什么符号是用户控制不了的事，不该让他重打一遍。
    static func parseTags(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
