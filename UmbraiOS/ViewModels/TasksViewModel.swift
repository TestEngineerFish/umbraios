import Foundation

// MARK: - Tasks ViewModel
@MainActor
class TasksViewModel: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var loading: Bool = false
    @Published var refreshing: Bool = false
    @Published var selectedJobId: String?
    @Published var jobDetail: JobDetail?

    private var pollTimer: Timer?

    func loadJobs() async {
        if jobs.isEmpty { loading = true }
        let fetched = await HTTPService.shared.fetchJobs(limit: 30)
        await MainActor.run {
            self.jobs = fetched
            self.loading = false
            // If detail is open, refresh it too
            if let selectedJobId = self.selectedJobId {
                Task { await self.loadJobDetail(id: selectedJobId) }
            }
        }
    }

    func refreshJobs() async {
        guard !refreshing else { return }   // 防止重复点击导致状态卡住
        refreshing = true
        await loadJobs()                    // 接口返回即停止转动，不再固定等待
        refreshing = false
    }

    func loadJobDetail(id: String) async {
        selectedJobId = id
        // 只有切换到不同任务时才清空，避免后台轮询刷新同一任务时把详情置空导致 sheet 收起再弹出。
        if jobDetail?.job.id != id { jobDetail = nil }
        if let detail = await HTTPService.shared.fetchJobDetail(id: id) {
            // 确认用户没有在等待期间关闭详情
            if selectedJobId == id { jobDetail = detail }
        }
    }

    func closeJobDetail() {
        selectedJobId = nil
        jobDetail = nil
    }

    func startPolling() {
        stopPolling()
        Task { await loadJobs() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { _ in
            Task { @MainActor [weak self] in
                await self?.loadJobs()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func statusBadgeColor(_ status: String) -> String {
        switch status {
        case "done": return "var(--success)"
        case "failed": return "var(--danger)"
        case "running", "pending": return "var(--orange)"
        default: return "var(--muted)"
        }
    }

    func statusBadgeText(_ status: String) -> String {
        switch status {
        case "done": return L("tasks.done")
        case "running": return L("tasks.running")
        case "pending": return L("tasks.pending")
        case "failed": return L("tasks.failed")
        case "cancelled": return L("tasks.cancelled")
        default: return status
        }
    }
}
