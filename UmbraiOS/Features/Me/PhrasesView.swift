// 常用语（me.phrases）：本地一份 + 服务端一份，按条目合并、以最后一次写入为准。
//
// 同步约定和 PC 端完全一样（服务端 /phrases 与 /phrases/sync）：
//   · 每条带毫秒级 updatedAt，合并时逐条比大小（last-write-wins），没有冲突弹窗；
//   · 删除留**墓碑**（id + deletedAt）。没有墓碑的话，A 端删掉的条目会被 B 端一推又复活；
//   · 一次往返：推本地全量 + 墓碑上去，服务端合并后回全量。常用语条数少，这样最省心。
//
// 本地存 UserDefaults 的一段 JSON。用 UserDefaults 而不是 Keychain：
// 常用语是**明文**内容（页面上也这么写了），密钥类要放密码保险箱。
import SwiftUI
import UIKit

// MARK: - 本地存储 + 同步

@MainActor
final class PhraseStore: ObservableObject {
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

// MARK: - 页面

struct UmbraPhrasesView: View {
    @EnvironmentObject private var router: UmbraRouter
    @StateObject private var store = PhraseStore()

    @State private var editing: Phrase? = nil
    @State private var creating = false
    @State private var draftName = ""
    @State private var draftBody = ""
    @State private var draftKeyword = ""

    var body: some View {
        UmbraPage(navBar: {
            UmbraNavBar(backLabel: "我", title: "常用语", onBack: { router.back() }) {
                UmbraNavIcon(iconPath: UmbraIconPath.plus, size: 20, strokeWidth: 2.4) { startCreate() }
            }
        }, content: {
            VStack(alignment: .leading, spacing: UmbraMetric.sp4) {
                header

                if store.items.isEmpty {
                    UmbraEmptyState(
                        iconPath: UmbraIconPath.messageText,
                        title: "还没有常用语",
                        hint: "把经常要说的话存成一条，之后在任意端直接拿来用。",
                        actionTitle: "新建一条",
                        action: { startCreate() })
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.items.enumerated()), id: \.element.id) { idx, p in
                            if idx > 0 { UmbraRowDivider() }
                            row(p)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous).fill(UmbraColor.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous)
                            .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                    )
                }

                // 明文提醒。用 warning 而不是 danger：这不是错误，是一条需要知道的事实。
                HStack(alignment: .top, spacing: UmbraMetric.sp3) {
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

                Text("同步按条目合并、以最后一次写入为准，没有冲突弹窗。点一行内容直接复制。")
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(UmbraColor.faint)
                    .lineSpacing(12 * 0.65)
            }
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.top, UmbraMetric.sp5)
        })
        .onAppear { Task { await store.sync() } }
        .alert(editing == nil ? "新建常用语" : "编辑常用语", isPresented: sheetBinding) {
            TextField("名称，例如「日报模板」", text: $draftName)
            TextField("内容", text: $draftBody)
            TextField("触发词（可留空）", text: $draftKeyword)
                .textInputAutocapitalization(.never)
            Button("取消", role: .cancel) { closeEditor() }
            Button("存下来") { commit() }
        } message: {
            Text("秘书会把内容原文直接拿去用。")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(store.items.count) 条")
                    .font(UmbraFont.sans(13, .w400))
                    .foregroundColor(UmbraColor.muted)
                Text(store.syncNote)
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(UmbraColor.faint)
            }
            Spacer(minLength: 0)
            Button {
                Task { await store.sync() }
            } label: {
                HStack(spacing: 6) {
                    if store.syncing {
                        UmbraSpinningIcon(d: UmbraIconPath.spinnerArc, size: 13, strokeWidth: 2.1)
                    }
                    Text(store.syncing ? "同步中" : "立即同步")
                        .font(UmbraFont.sans(13, .w560))
                }
                .foregroundColor(UmbraColor.text)
                .padding(.horizontal, UmbraMetric.sp4)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UmbraColor.card))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                )
                .frame(minHeight: UmbraMetric.tapMin)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.syncing)
        }
    }

    private func row(_ p: Phrase) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Button {
                UIPasteboard.general.string = p.content
                router.showToast("已复制")
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(p.name)
                            .font(UmbraFont.sans(15.5, .w560))
                            .foregroundColor(UmbraColor.text)
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

            // 编辑 / 删除。破坏性动作在这里是一行内的小字（列表行，不是详情页底部），
            // 删除仍然要过一次确认弹窗。
            VStack(alignment: .trailing, spacing: 6) {
                Button { startEdit(p) } label: {
                    Text("编辑")
                        .font(UmbraFont.sans(12.5, .w560))
                        .foregroundColor(UmbraColor.orange)
                        .frame(minWidth: 44, minHeight: 22, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    router.confirm(UmbraAlert(
                        title: "删除「\(p.name)」？",
                        body: "会同步到其它设备。",
                        confirmLabel: "删除",
                        confirmDestructive: true,
                        onConfirm: {
                            store.delete(id: p.id)
                            router.showToast("已删除")
                        }))
                } label: {
                    Text("删除")
                        .font(UmbraFont.sans(12.5, .w560))
                        .foregroundColor(UmbraColor.danger)
                        .frame(minWidth: 44, minHeight: 22, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, UmbraMetric.sp4)
    }

    // MARK: 编辑器
    //
    // 用系统的输入 alert 而不是设计稿的两步底部选择器：Router 的 UmbraSheet 只承载选项，
    // 没有输入框。为两个入口给它加一整套字段模型不划算，而系统 alert 的多字段输入是现成的。

    private var sheetBinding: Binding<Bool> {
        Binding(get: { creating || editing != nil },
                set: { if !$0 { closeEditor() } })
    }

    private func startCreate() {
        editing = nil
        draftName = ""; draftBody = ""; draftKeyword = ""
        creating = true
    }

    private func startEdit(_ p: Phrase) {
        creating = false
        draftName = p.name
        draftBody = p.content
        draftKeyword = p.keyword ?? ""
        editing = p
    }

    private func closeEditor() {
        creating = false
        editing = nil
    }

    private func commit() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let kw = draftKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { router.showToast("常用语得有个名字"); closeEditor(); return }
        guard !body.isEmpty else { router.showToast("内容不能是空的"); closeEditor(); return }
        if var p = editing {
            p.name = name; p.content = body; p.keyword = kw.isEmpty ? nil : kw
            store.update(p)
            router.showToast("已存下")
        } else {
            store.add(name: name, content: body, keyword: kw.isEmpty ? nil : kw)
            router.showToast("已存下常用语「\(name)」")
        }
        closeEditor()
    }
}
