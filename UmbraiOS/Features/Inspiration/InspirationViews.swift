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

    var body: some View {
        UmbraPage(navBar: { EmptyView() }, content: {
            UmbraTitleHeader(title: "灵感", subtitle: "随手记下的点子") {
                HStack(spacing: 0) {
                    Button(action: openSort) {
                        UmbraIcon(d: UmbraIconPath.filter, size: 17, strokeWidth: 2)
                            .foregroundColor(UmbraColor.muted)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(UmbraColor.card))
                            .overlay(Circle().strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW))
                            .frame(width: UmbraMetric.tapMin, height: UmbraMetric.tapMin)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    UmbraRoundPlusButton { router.go(.inspEdit(id: nil)) }
                }
            }

            UmbraFilterChips(items: statusChips, selection: $status)
                .padding(.bottom, 10)

            tagRow

            UmbraSearchField(placeholder: "搜索灵感", text: $query, trailingNote: sort.label)
                .padding(.horizontal, UmbraMetric.pagePadX)
                .padding(.bottom, UmbraMetric.sp4)

            if rows.isEmpty {
                UmbraEmptyState(
                    iconPath: UmbraIconPath.bulb,
                    title: "这个筛选下还没有灵感",
                    hint: "在任意端发一条「记个灵感：…」，秘书会自动补标题和标签；也可以点右上角手动添加。",
                    actionTitle: "记一条灵感",
                    action: { router.go(.inspEdit(id: nil)) })
            } else {
                VStack(spacing: 10) {
                    ForEach(rows) { i in card(i) }
                }
                .padding(.horizontal, UmbraMetric.pagePadX)

                Text("长按卡片可以快捷标记已实现、归档或删除。手机上记的灵感来源会标成「手机端」。")
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(UmbraColor.faint)
                    .lineSpacing(12 * 0.65)
                    .padding(.horizontal, UmbraMetric.pagePadX)
                    .padding(.top, UmbraMetric.sp4)
            }
        })
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
                    Text(i.title.isEmpty ? "（还没有标题）" : i.title)
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
            .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous).fill(UmbraColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous)
                    .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 长按 = 快捷菜单。设计稿写的是右键，手机上对应长按。
        .onLongPressGesture { openMenu(i) }
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

    private func openMenu(_ i: Inspiration) {
        router.present(UmbraSheet(title: i.title.isEmpty ? "这条灵感" : i.title, items: [
            UmbraSheetItem(label: i.status == "done" ? "标回待办" : "标记已实现") {
                Task { await insp.setStatus(id: i.id, status: i.status == "done" ? "open" : "done") }
            },
            UmbraSheetItem(label: i.status == "archived" ? "取消归档" : "归档") {
                Task { await insp.setStatus(id: i.id, status: i.status == "archived" ? "open" : "archived") }
            },
            UmbraSheetItem(label: "编辑") { router.go(.inspEdit(id: String(i.id))) },
            UmbraSheetItem(label: "删除", destructive: true) {
                router.confirm(UmbraAlert(
                    title: "确认删除这条灵感？",
                    body: "删除后无法恢复。",
                    confirmLabel: "删除",
                    confirmDestructive: true,
                    onConfirm: {
                        Task { await insp.delete(id: i.id) }
                        router.showToast("已删除")
                    }))
            }
        ]))
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

    var body: some View {
        UmbraPage(navBar: {
            UmbraNavBar(backLabel: "灵感", title: "", onBack: { router.back() }) {
                if let i = item {
                    UmbraNavAction(title: "编辑") { router.go(.inspEdit(id: id)) }
                    UmbraNavDots { openMenu(i) }
                }
            }
        }, content: {
            if let i = item { content(i) } else { missing }
        }, bottom: {
            if let i = item { bottomBar(i) }
        })
        .onAppear { Task { await insp.load() } }
    }

    /// 右上角「⋯」。破坏性操作**不占详情页底部**，收进这里 —— 这是 iOS 增补规范的硬规则。
    private func openMenu(_ i: Inspiration) {
        router.present(UmbraSheet(title: i.title.isEmpty ? "这条灵感" : i.title, items: [
            UmbraSheetItem(label: "编辑") { router.go(.inspEdit(id: id)) },
            UmbraSheetItem(label: "删除", destructive: true) {
                router.confirm(UmbraAlert(
                    title: "确认删除这条灵感？",
                    body: "删除后无法恢复。",
                    confirmLabel: "删除",
                    confirmDestructive: true,
                    onConfirm: {
                        Task { await insp.delete(id: i.id) }
                        router.back()
                        router.showToast("已删除")
                    }))
            }
        ]))
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
            Text(i.title.isEmpty ? "（还没有标题）" : i.title)
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
                .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous).fill(UmbraColor.card))
                .overlay(
                    RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous)
                        .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                )
        }

        // 秘书整理是异步补的，没补上就不画这一节。
        if !i.summary.isEmpty {
            section("秘书整理") {
                Text(i.summary)
                    .font(UmbraFont.sans(15, .w400))
                    .foregroundColor(UmbraColor.text)
                    .lineSpacing(15 * 0.65)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
                    .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous).fill(UmbraColor.orangeSoft))
            }
        }

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
                // 跳到与秘书的会话，把灵感原文填进草稿并切到「执行」模式。
                // **不自动发送** —— 发之前让用户能改一句，这是 PC 端定下的行为。
                chat.switchConversation(ChatViewModel.mainConv)
                chat.mode = .execution
                chat.draft = i.raw.isEmpty ? i.title : i.raw
                router.root(.chat)
                router.go(.chatThread(conv: ChatViewModel.mainConv))
                router.showToast("已填进聊天框，改完再发")
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

// MARK: - 编辑

struct UmbraInspirationEditView: View {
    /// nil = 新建
    let id: String?

    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var insp: InspirationsViewModel

    @State private var raw = ""
    @State private var title = ""
    @State private var tagsText = ""
    @State private var loaded = false

    private var existing: Inspiration? {
        guard let id else { return nil }
        return insp.list.first { String($0.id) == id }
    }

    private var canSave: Bool { !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        UmbraPage(navBar: {
            UmbraNavBar(backLabel: "取消", title: id == nil ? "记一条灵感" : "编辑灵感",
                        onBack: { router.back() }, backChevron: false) {
                UmbraNavAction(title: "存下", weight: .w600, enabled: canSave, action: save)
            }
        }, content: {
            VStack(alignment: .leading, spacing: UmbraMetric.sp6) {
                field("内容") {
                    // 多行输入。iOS 16 的 TextField 支持 axis: .vertical，不必再包 UITextView。
                    TextField("想到什么就写什么，不用组织语言。", text: $raw, axis: .vertical)
                        .font(UmbraFont.sans(16, .w400))
                        .lineSpacing(16 * 0.65)
                        .lineLimit(6...)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .frame(minHeight: 150, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(UmbraColor.card))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                        )
                }
                field("标题") { input("留空由秘书补", text: $title) }
                field("标签") { input("逗号分隔，可留空", text: $tagsText) }

                Text("标题和标签留空时，秘书会读一遍内容替你补上。这条会记成「手机端」来源。")
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(UmbraColor.faint)
                    .lineSpacing(12 * 0.65)

                if !canSave {
                    // 「存下」置灰时必须给出原因，就一行。
                    Text("内容还是空的，写点什么才能存。")
                        .font(UmbraFont.sans(12, .w400))
                        .foregroundColor(UmbraColor.faint)
                }
            }
            .padding(UmbraMetric.pagePadX)
        })
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

    /// 标签串 → 数组。全角逗号、半角逗号、顿号都当分隔符 ——
    /// 输入法给什么符号是用户控制不了的事，不该让他重打一遍。
    private var tags: [String] {
        tagsText
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func save() {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let e = existing {
            Task { await insp.update(id: e.id, raw: body, title: name, tags: tags, note: e.summary) }
        } else {
            Task { await insp.create(raw: body, title: name, tags: tags, note: "") }
        }
        router.back()
        router.showToast("已存下")
    }
}
