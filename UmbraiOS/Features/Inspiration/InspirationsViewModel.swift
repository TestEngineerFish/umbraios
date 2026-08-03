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
        self.list = fetched
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

    func create(raw: String, title: String, tags: [String], note: String) async {
        await HTTPService.shared.createInspiration(raw: raw, title: title, summary: note, tags: tags)
        await load()
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
