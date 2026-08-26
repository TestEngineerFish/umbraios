import Foundation

// MARK: - Tasks ViewModel
// B 批改名：Job → TaskItem、/jobs → /tasks。属性名跟着换（jobs → items 等），
// 让"任务"从表到接口到端上只有一套名字。
@MainActor
class TasksViewModel: ObservableObject {
    @Published var items: [TaskItem] = []
    @Published var loading: Bool = false
    @Published var refreshing: Bool = false
    @Published var selectedTaskId: String?
    @Published var detail: TaskDetail?

    private var pollTimer: Timer?

    func loadTasks() async {
        if items.isEmpty { loading = true }
        let fetched = await HTTPService.shared.fetchTasks(limit: 30)
        await MainActor.run {
            // 拉失败（nil）就保留旧列表 —— 刷新失败不该把已经在屏幕上的东西抹掉。
            if let fetched {
                self.items = fetched
                // 每次拉到新列表就同步小组件快照 + 灵动岛/锁屏实况 ——
                // 三处显示的任务和这里是同一份数据、同一个 tick（规范 4.3）。
                UmbraWidgetBridge.syncTasks(fetched)
            }
            self.loading = false
            // 详情开着的话一并刷新
            if let selectedTaskId = self.selectedTaskId {
                Task { await self.loadTaskDetail(id: selectedTaskId) }
            }
        }
    }

    func refreshTasks() async {
        guard !refreshing else { return }   // 防止重复点击导致状态卡住
        refreshing = true
        await loadTasks()                   // 接口返回即停止转动，不再固定等待
        refreshing = false
    }

    func loadTaskDetail(id: String) async {
        selectedTaskId = id
        // 只有切换到不同任务时才清空，避免后台轮询刷新同一任务时把详情置空导致 sheet 收起再弹出。
        if detail?.task.id != id { detail = nil }
        if let d = await HTTPService.shared.fetchTaskDetail(id: id) {
            // 确认用户没有在等待期间关闭详情
            if selectedTaskId == id { detail = d }
        }
    }

    func closeTaskDetail() {
        selectedTaskId = nil
        detail = nil
    }

    // 强制结束一个正在跑/挂起中的任务，然后刷新列表。
    func stopTask(id: String) async {
        await HTTPService.shared.stopTask(id: id)
        await loadTasks()
    }

    // 是否可「结束任务」：运行/待执行/挂起中才显示按钮（任务模型就这三个非终态）。
    static func isActive(_ status: String) -> Bool {
        ["running", "pending", "suspended"].contains(status)
    }

    func startPolling() {
        stopPolling()
        Task { await loadTasks() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { _ in
            Task { @MainActor [weak self] in
                await self?.loadTasks()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
