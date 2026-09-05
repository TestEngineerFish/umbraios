// 常用语（me.phrases）：本地一份 + 服务端一份，按条目合并、以最后一次写入为准。
//
// 同步约定和 PC 端完全一样（服务端 /phrases 与 /phrases/sync）：
//   · 每条带毫秒级 updatedAt，合并时逐条比大小（last-write-wins），没有冲突弹窗；
//   · 删除留**墓碑**（id + deletedAt）。没有墓碑的话，A 端删掉的条目会被 B 端一推又复活；
//   · 一次往返：推本地全量 + 墓碑上去，服务端合并后回全量。常用语条数少，这样最省心。
//
// 本地存 UserDefaults 的一段 JSON。用 UserDefaults 而不是 Keychain：
// 常用语是**明文**内容（页面上也这么写了），密钥类要放密码保险箱。
//
// v2 界面按设计稿 me.phrases / phrase.edit 重做：
//   列表 = 系统 List + 左滑（编辑 / 删除进确认弹窗）+ 长按拖动排序；
//   新建/编辑 = 独立推入页（名称 / 标签 chips / 内容大输入区），不再是系统输入弹窗 ——
//   常用语内容常常是好几段话，alert 里那条单行输入框根本放不下。
import SwiftUI
// UIPasteboard 在 UIKit 里，SwiftUI 不转出口它 —— 复制钮（2026-09-02 稿）要用。
import UIKit

// MARK: - 本地存储 + 同步

@MainActor
final class PhraseStore: ObservableObject {
    /// 列表页和编辑页是两个路由、各自建 store 会各存各的账 —— 共用这一份。
    static let shared = PhraseStore()

    @Published private(set) var items: [Phrase] = []
    @Published private(set) var tombs: [PhraseTomb] = []
    /// 同步状态的一行说明。同步是后台行为，用户唯一能看到的就是这行字，所以要具体。
    @Published private(set) var syncNote = "还没同步过"
    @Published private(set) var syncing = false

    private let key = "umbra.phrases.local"
    private let noteKey = "umbra.phrases.syncedAt"

    init() {
        load()
        if let at = UserDefaults.standard.object(forKey: noteKey) as? Double, at > 0 {
            syncNote = "上次同步 " + UmbraTime.relative(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: at)))
        }
    }

    // MARK: 本地

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let b = try? JSONDecoder().decode(PhraseBundle.self, from: data) else { return }
        items = b.items.sorted { $0.order < $1.order }
        tombs = b.deleted
    }

    private func persist() {
        let b = PhraseBundle(items: items, deleted: tombs)
        if let data = try? JSONEncoder().encode(b) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private var nowMs: Int { Int(Date().timeIntervalSince1970 * 1000) }

    func add(name: String, content: String, keyword: String?) {
        let p = Phrase(id: UUID().uuidString, name: name, content: content,
                       keyword: keyword, order: (items.map(\.order).max() ?? 0) + 1,
                       updatedAt: nowMs)
        items.append(p)
        persist()
        Task { await sync() }
    }

    func update(_ p: Phrase) {
        guard let i = items.firstIndex(where: { $0.id == p.id }) else { return }
        var v = p
        v.updatedAt = nowMs
        items[i] = v
        persist()
        Task { await sync() }
    }

    func delete(id: String) {
        items.removeAll { $0.id == id }
        // 墓碑要留着，直到服务端也知道这条没了。这里不做过期清理 ——
        // 常用语条数少，墓碑攒着的代价远小于「删了又活过来」。
        if !tombs.contains(where: { $0.id == id }) {
            tombs.append(PhraseTomb(id: id, deletedAt: nowMs))
        }
        persist()
        Task { await sync() }
    }

    /// 拖动排序后重排 order。order 也要更新 updatedAt，否则别的端不会采纳新顺序。
    func reorder(from source: IndexSet, to destination: Int) {
        var list = items
        list.move(fromOffsets: source, toOffset: destination)
        let t = nowMs
        for i in list.indices {
            list[i].order = i
            list[i].updatedAt = t
        }
        items = list
        persist()
        Task { await sync() }
    }

    // MARK: 同步

    func sync() async {
        guard !syncing else { return }
        syncing = true
        syncNote = "同步中…"
        let merged = await HTTPService.shared.syncPhrases(items: items, deleted: tombs)
        syncing = false
        guard let merged else {
            // 失败要说清楚是什么失败了，并且**保留本地数据**——下次还会再推一次。
            syncNote = "同步失败，本地改动已留着，下次会再试"
            return
        }
        items = merged.items.sorted { $0.order < $1.order }
        tombs = merged.deleted
        persist()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: noteKey)
        syncNote = "刚刚同步"
    }
}

// MARK: - 列表页

struct UmbraPhrasesView: View {
    @EnvironmentObject private var router: UmbraRouter
    @ObservedObject private var store = PhraseStore.shared

    /// 刚复制过的那条（2026-09-02 稿）：图标换勾 + 「已复制」，两秒后复位。
    /// 只记 id 不记布尔 —— 连着复制两条时，前一条的勾要立刻让位给后一条。
    @State private var copiedId: String?
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        Group {
            if store.items.isEmpty {
                UmbraScreen {
                    UmbraEmptyState(
                        iconPath: UmbraIconPath.messageText,
                        title: "还没有常用语",
                        hint: "把经常要说的话存成一条，之后在任意端直接拿来用。",
                        actionTitle: "新建一条",
                        action: { router.go(.mePhraseEdit(id: nil)) })
                        .padding(.horizontal, UmbraMetric.pagePadX)
                        .padding(.top, UmbraMetric.sp7)
                }
            } else {
                list
            }
        }
        .navigationTitle("常用语")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.go(.mePhraseEdit(id: nil)) } label: { Image(systemName: "plus") }
                    .tint(UmbraColor.orange)
            }
        }
        .onAppear { Task { await store.sync() } }
    }

    private var list: some View {
        List {
            // 数量 + 同步按钮：设计稿里这一行在卡片外，所以背景透明、不占行样式。
            header
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                .listRowSeparator(.hidden)

            Section {
                ForEach(store.items) { p in row(p) }
                    // 长按拖动排序（系统 List 不进编辑模式也能拖）。
                    .onMove { store.reorder(from: $0, to: $1) }
            } footer: {
                footerNotes
            }
        }
        .listStyle(.insetGrouped)
        // 下拉刷新（2026-08-22 稿：iOS 端所有列表都给）。这里也是拉**真同步**而不是重读本地 ——
        // 本地数据是 @Published 的，改完界面自己就更新了，重读一遍等于什么都没发生。
        // 页面上那颗同步按钮保留：下拉是手势入口，按钮是能看见状态（转圈）的那个入口，两者不冲突。
        .refreshable { await store.sync() }
        .scrollContentBackground(.hidden)
        .background(UmbraColor.bg)
        // 这页没有输入框，键盘避让纯属多余；从编辑页收着键盘弹回来时
        // List 可能带着键盘 inset 布局又不还（同保险箱首页的坑），干脆不参与。
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(store.items.count) 条")
                    .font(UmbraFont.sans(13, .w400))
                    .foregroundColor(UmbraColor.muted)
                // 失败信息不能只藏在按钮态里 —— 失败时补一行说明，平时不占地方。
                if store.syncNote.hasPrefix("同步失败") {
                    Text(store.syncNote)
                        .font(UmbraFont.sans(12, .w400))
                        .foregroundColor(UmbraColor.warning)
                }
            }
            Spacer(minLength: 0)
            syncButton
        }
    }

    /// 同步按钮的三态（设计稿 phVM）：同步中（橙、转圈）/ 刚刚同步 / 立即同步。
    private var syncButton: some View {
        Button {
            Task { await store.sync() }
        } label: {
            HStack(spacing: 6) {
                if store.syncing {
                    UmbraSpinningIcon(d: UmbraIconPath.spinnerArc, size: 13, strokeWidth: 2.2)
                }
                Text(store.syncing ? "同步中…" : (store.syncNote == "刚刚同步" ? "刚刚同步" : "立即同步"))
                    .font(UmbraFont.sans(13, .w560))
            }
            .foregroundColor(store.syncing ? UmbraColor.orangeText : UmbraColor.text)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(Capsule().fill(store.syncing ? UmbraColor.orangeSoft : UmbraColor.card))
            .overlay(Capsule().strokeBorder(store.syncing ? UmbraColor.orange : UmbraColor.border,
                                            lineWidth: UmbraMetric.borderW))
            .frame(minHeight: UmbraMetric.tapMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.syncing)
    }

    /// 一行：名称 + 触发词胶囊 + 首行预览 + 右侧常驻复制钮（2026-09-02 稿）。
    /// 复制不藏在左滑里 —— 常用语八成的用法是「拿去粘到别处」，是行上的主动作；
    /// 点标题区进编辑，点右侧图标复制全文，两块热区分开、互不误触。
    private func row(_ p: Phrase) -> some View {
        HStack(spacing: 4) {
            Button {
                router.go(.mePhraseEdit(id: p.id))
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(p.name)
                            .font(UmbraFont.sans(15.5, .w560))
                            .foregroundColor(UmbraColor.text)
                            .lineLimit(1)
                        if let k = p.keyword, !k.isEmpty {
                            Text(k)
                                .font(UmbraFont.mono(11, .w600))
                                .foregroundColor(UmbraColor.muted)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(UmbraColor.chip))
                        }
                    }
                    Text(p.content.split(separator: "\n").first.map(String.init) ?? "")
                        .font(UmbraFont.sans(13, .w400))
                        .foregroundColor(UmbraColor.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            copyButton(p)
        }
        // 这一行原来既没内衬也没行高，完全吃 List 的默认值。
        // 纵向 11、行高 48 照 `iosShell.list.row`；横向不补 —— List 自己那份左右内衬
        // 已经在 14 附近，再叠一层会把复制钮挤到边上。
        .padding(.vertical, 11)
        .frame(minHeight: UmbraMetric.rowMinH)
        .listRowBackground(UmbraColor.card)
        .umbraRowSeparatorFullWidth()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // 删除必进确认弹窗，所以不用 role: .destructive ——
            // 带 role 的按钮系统会先把行划走，取消确认后行回不来。
            Button {
                router.confirm(UmbraAlert(
                    title: "删除常用语「\(p.name)」？",
                    body: "删除后无法恢复，会同步到其它设备。",
                    confirmLabel: "删除",
                    confirmDestructive: true,
                    onConfirm: {
                        withAnimation { store.delete(id: p.id) }
                        router.showToast("已删除「\(p.name)」")
                    }))
            } label: {
                Label("删除", systemImage: "trash")
            }
            .tint(UmbraColor.danger)

            Button {
                router.go(.mePhraseEdit(id: p.id))
            } label: {
                Label("编辑", systemImage: "square.and.pencil")
            }
        }
    }

    /// 44×44 热区的无底图标钮（token phraseRow）：剪贴板图标，成功后换勾 +
    /// 下方 9.5px「已复制」（--success），两秒复位 —— 和密码保险箱字段的
    /// copyFeedback 同一套手感。内容是**明文**，不做 60 秒清剪贴板
    /// （那条只管保险箱的敏感值）；toast 写「已复制「X」全文」，
    /// 把复制的是全文还是首行预览说清楚。
    private func copyButton(_ p: Phrase) -> some View {
        let copied = copiedId == p.id
        return Button {
            UIPasteboard.general.string = p.content
            withAnimation(.easeOut(duration: 0.12)) { copiedId = p.id }
            router.showToast("已复制「\(p.name)」全文")
            copyResetTask?.cancel()
            copyResetTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation { copiedId = nil }
            }
        } label: {
            VStack(spacing: 2) {
                UmbraIcon(d: copied ? UmbraIconPath.check : UmbraIconPath.copy,
                          size: 19, strokeWidth: 1.9)
                if copied {
                    Text("已复制")
                        .font(UmbraFont.sans(9.5, .w560))
                }
            }
            .foregroundColor(copied ? UmbraColor.success : UmbraColor.muted)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 明文警示 + 同步说明。放 Section footer：跟着卡片走、不参与滑动手势。
    private var footerNotes: some View {
        VStack(alignment: .leading, spacing: UmbraMetric.sp3) {
            HStack(alignment: .top, spacing: 9) {
                UmbraIcon(d: UmbraIconPath.alertTriangle, size: 15, strokeWidth: 2)
                    .padding(.top, 1)
                Text("内容为明文存储，密钥类请放密码保险箱")
                    .font(UmbraFont.sans(12.5, .w560))
                    .lineSpacing(12.5 * 0.55)
            }
            .foregroundColor(UmbraColor.warning)
            .padding(.horizontal, UmbraMetric.sp4)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(UmbraColor.warningSoft))
            // 两块热区的用法说明（2026-09-02 稿的底部说明后半句）。稿里前半句是
            // 同步机制的解释 —— 那段此前老板点名删过，不因换稿复活；明文警示照旧。
            Text("点右侧图标复制全文，点条目改内容。")
                .font(UmbraFont.sans(12, .w400))
                .foregroundColor(UmbraColor.faint)
                .padding(.horizontal, 2)
        }
        .padding(.top, UmbraMetric.sp3)
        // Section footer 自带的横向缩进去掉，跟卡片同宽。
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .textCase(nil)
    }
}

// MARK: - 新建 / 编辑页（设计稿 phrase.edit）

struct UmbraPhraseEditView: View {
    /// nil = 新建。
    let id: String?

    @EnvironmentObject private var router: UmbraRouter
    @ObservedObject private var store = PhraseStore.shared

    @State private var name = ""
    @State private var keyword = ""
    @State private var content = ""
    /// 只在第一次出现时灌入草稿 —— 返回再进来（系统栈保留页面）不能把用户改到一半的字冲掉。
    @State private var seeded = false

    private var editing: Phrase? { id.flatMap { i in store.items.first { $0.id == i } } }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        UmbraScreen {
            VStack(alignment: .leading, spacing: UmbraMetric.sp5) {
                field(label: "名称") {
                    TextField("例如「日报模板」", text: $name)
                        .font(UmbraFont.sans(16, .w400))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(inputShape)
                }

                field(label: "标签") {
                    VStack(alignment: .leading, spacing: 7) {
                        if !existingKeywords.isEmpty {
                            // 已有触发词做成 chips 预选：点一下写进输入框（再点取消），
                            // 和灵感编辑页的标签 chips 同一套交互（横滑一行）。
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 7) {
                                    ForEach(existingKeywords.prefix(10), id: \.self) { k in
                                        UmbraTagPill(text: k, selected: keyword == k) {
                                            keyword = (keyword == k) ? "" : k
                                        }
                                    }
                                }
                            }
                        }
                        TextField("快捷标签，例如「日报」，可留空", text: $keyword)
                            .font(UmbraFont.sans(16, .w400))
                            .textInputAutocapitalization(.never)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .background(inputShape)
                    }
                }

                field(label: "内容") {
                    TextEditor(text: $content)
                        .font(UmbraFont.sans(15.5, .w400))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(minHeight: 180)
                        .background(inputShape)
                        .overlay(alignment: .topLeading) {
                            if content.isEmpty {
                                // TextEditor 到 iOS 17 还没有占位符参数，手动垫一个。
                                Text("秘书会把这段原文直接拿去用")
                                    .font(UmbraFont.sans(15.5, .w400))
                                    .foregroundColor(UmbraColor.faint)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 14)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                Text("内容为明文存储，密钥类请放密码保险箱。")
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(UmbraColor.faint)
                    .lineSpacing(12 * 0.65)
            }
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.top, UmbraMetric.sp4)
        }
        .navigationTitle(id == nil ? "新建常用语" : "编辑常用语")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { router.back() }
                    .tint(UmbraColor.text)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // 没填够不置灰 —— 点了告诉你缺什么（设计稿行为），比灰按钮猜哑谜好。
                Button("保存") { save() }
                    .font(UmbraFont.sans(16, .w600))
                    .tint(valid ? UmbraColor.orange : UmbraColor.faint)
            }
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            if let p = editing {
                name = p.name
                keyword = p.keyword ?? ""
                content = p.content
            }
        }
    }

    private var inputShape: some View {
        RoundedRectangle(cornerRadius: UmbraMetric.radiusInput, style: .continuous)
            .fill(UmbraColor.card)
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusInput, style: .continuous)
                    .strokeBorder(UmbraColor.borderSoft, lineWidth: UmbraMetric.borderW)
            )
    }

    private func field(label: String, @ViewBuilder body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            UmbraFieldLabel(text: label)
            body()
        }
    }

    /// 其它条目已经在用的触发词（去重、按现有顺序）。
    private var existingKeywords: [String] {
        var seen: [String] = []
        for p in store.items {
            if let k = p.keyword, !k.isEmpty, !seen.contains(k) { seen.append(k) }
        }
        return seen
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { router.showToast("先给常用语起个名字"); return }
        guard !c.isEmpty else { router.showToast("内容不能是空的"); return }
        if var p = editing {
            p.name = n; p.content = c; p.keyword = k.isEmpty ? nil : k
            store.update(p)
            router.showToast("已保存")
        } else {
            store.add(name: n, content: c, keyword: k.isEmpty ? nil : k)
            router.showToast("已保存常用语「\(n)」")
        }
        router.back()
    }
}
