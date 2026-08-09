import Foundation

// 聊天里记下新灵感时，ChatViewModel 会发这个通知，灵感页据此即时刷新。
extension Notification.Name {
    static let inspirationChanged = Notification.Name("umbra.inspirationChanged")
}

// MARK: - Inspirations ViewModel（灵感速记）
@MainActor
class InspirationsViewModel: ObservableObject {
    @Published var list: [Inspiration] = []
    @Published var loading = false
    @Published var refreshing = false
    @Published var filter: String = ""            // ""/open/done/archived

    private var pollTimer: Timer?
    private var observer: NSObjectProtocol?

    init() {
        // 聊天中记下灵感 → 立即刷新（页面在前台时）。
        observer = NotificationCenter.default.addObserver(
            forName: .inspirationChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.load() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func load() async {
        if list.isEmpty { loading = true }
        let fetched = await HTTPService.shared.fetchInspirations(status: filter.isEmpty ? nil : filter)
        // 拉失败（nil）保留旧列表，刷新失败不清屏。
        if let fetched { self.list = fetched }
        self.loading = false
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        await load()
        refreshing = false
    }

    func setFilter(_ f: String) {
        filter = f
        Task { await load() }
    }

    func create(raw: String, title: String, tags: [String], note: String,
                research: Bool = false) async {
        await HTTPService.shared.createInspiration(raw: raw, title: title, summary: note,
                                                   tags: tags, research: research)
        await load()
    }

    /// 让秘书去查一查这条灵感。**乐观地先把本地状态推到 queued**：
    /// 接口返回和下一次轮询之间有几秒空窗，不先动的话用户点完按钮什么反应都没有，
    /// 只会再点一次。真实状态下一轮轮询就会覆盖回来。
    func requestResearch(id: Int) async {
        markResearch(id: id, status: "queued")
        let ok = await HTTPService.shared.requestInspirationResearch(id: id)
        if !ok {
            // 没送达就把乐观状态收回去，别让界面一直显示「排队中」骗人。
            markResearch(id: id, status: "idle")
            return
        }
        await load()
    }

    private func markResearch(id: Int, status: String) {
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        let o = list[idx]
        list[idx] = Inspiration(
            id: o.id, raw: o.raw, title: o.title, summary: o.summary, tags: o.tags,
            status: o.status, source_channel: o.source_channel,
            created_at: o.created_at, updated_at: o.updated_at,
            organize_status: o.organize_status, research: o.research,
            research_status: status, research_at: o.research_at)
    }

    func update(id: Int, raw: String, title: String, tags: [String], note: String) async {
        await HTTPService.shared.updateInspiration(id: id, patch: [
            "raw": raw, "title": title, "summary": note, "tags": tags,
        ])
        await load()
    }

    func setStatus(id: Int, status: String) async {
        await HTTPService.shared.updateInspiration(id: id, patch: ["status": status])
        await load()
    }

    func delete(id: Int) async {
        await HTTPService.shared.deleteInspiration(id: id)
        await load()
    }

    func startPolling() {
        stopPolling()
        Task { await load() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor [weak self] in await self?.load() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func statusText(_ s: String) -> String {
        switch s {
        case "done": return L("insp.statusDone")
        case "archived": return L("insp.statusArchived")
        default: return L("insp.statusOpen")
        }
    }
}
