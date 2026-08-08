// 主 App → Widget/灵动岛的桥（**只属于主 App target**，不勾扩展）。
//
// 职责就两件：
//   1. 数据一变就把快照写进 App Group，并指名重载对应小组件；
//   2. 把执行中任务同步给 Live Activity（灵动岛 + 锁屏实况是同一个 Activity）。
// 数据源：任务 = TasksViewModel 的轮询结果；提醒 = ReminderStore 的本机存储。
// 三处（灵动岛/锁屏/小组件）显示的同一任务因此天然同源同 tick。
//
// 诚实边界：任务轮询只在任务页打开时跑（startPolling/stopPolling），
// 所以 Live Activity 的进度目前**跟随 App 内轮询**更新；退到后台后要继续动，
// 得等服务端有推送（ActivityKit push token）—— 见接入文档「后续」一节，这里不装。
import Foundation
import WidgetKit
import ActivityKit

enum UmbraWidgetBridge {

    // MARK: 任务

    @MainActor
    static func syncTasks(_ jobs: [Job]) {
        let running = jobs.first { $0.status == "running" }
        let todayDone = jobs.filter { $0.status == "done" && UmbraShared.isToday($0.updated_at) }.count
        UmbraShared.save(UmbraTaskSnapshot(
            runningId: running?.id,
            // 存短标题：小组件那块地方放不下整段描述（Job.title 会在没有短标题时退回 goal）。
            runningTitle: running?.title,
            stepsDone: running?.steps_done ?? 0,
            stepsTotal: running?.steps_total ?? 0,
            todayDone: todayDone,
            savedAt: Date()))
        print("[UmbraWidget] 任务快照已写：appGroup生效=\(UmbraShared.appGroupReady) 执行中=\(running?.id ?? "无") 今天完成=\(todayDone)")
        WidgetCenter.shared.reloadTimelines(ofKind: UmbraShared.taskWidgetKind)
        UmbraLiveActivityController.shared.sync(with: jobs)
    }

    // MARK: 提醒

    @MainActor
    static func syncReminders(_ items: [UmbraReminder]) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        // 只放「已过期 + 今天」的未完成项 —— 中号小组件就是「今天的提醒」，
        // 「更远」的放进去只会把今天的挤出屏（和底栏角标同一套口径）。
        let rows = items
            .filter { !$0.done && ($0.group == "已过期" || $0.group == "今天") }
            .sorted { $0.at < $1.at }
            .prefix(6)
            .map { UmbraReminderSnapshot.Row(id: $0.id, text: $0.text,
                                             time: df.string(from: $0.at),
                                             overdue: $0.overdue) }
        UmbraShared.save(UmbraReminderSnapshot(rows: Array(rows), savedAt: Date()))
        // appGroup生效=false 就是两个 target 的 App Groups 没配对上（entitlement 缺失），
        // 主 App 和小组件各写各的沙盒，小组件永远读不到 —— 去 Xcode 两边核对同一个组。
        print("[UmbraWidget] 提醒快照已写：appGroup生效=\(UmbraShared.appGroupReady) 今天/过期条数=\(rows.count)（提醒总数 \(items.count)）")
        WidgetCenter.shared.reloadTimelines(ofKind: UmbraShared.reminderWidgetKind)
    }
}

// MARK: - Live Activity（灵动岛 + 锁屏实况）

/// 一次只跟一个执行中任务（设计稿：胶囊态就是「当前那个任务」）。
/// 任务切换 = 结束旧的再开新的；任务完成/失败 = 推一帧收尾态，几秒后自动消失。
@MainActor
final class UmbraLiveActivityController {
    static let shared = UmbraLiveActivityController()
    private init() {}

    private var activity: Activity<UmbraTaskActivityAttributes>?

    func sync(with jobs: [Job]) {
        if let job = jobs.first(where: { $0.status == "running" }) {
            let state = UmbraTaskActivityAttributes.ContentState(
                stepsDone: job.steps_done ?? 0,
                stepsTotal: job.steps_total ?? 0,
                statusLine: line(for: job),
                finished: false, failed: false)

            if let act = activity, act.attributes.jobId == job.id {
                Task { await act.update(ActivityContent(state: state, staleDate: nil)) }
            } else {
                // 换了任务：结束旧的（不留收尾帧，旧任务的状态在列表里看）。
                endCurrent(with: nil)
                // 用户在系统设置里关了实况就不请求 —— 请求也只会抛错。
                guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
                activity = try? Activity.request(
                    attributes: UmbraTaskActivityAttributes(jobId: job.id, goal: job.goal),
                    content: ActivityContent(state: state, staleDate: nil))
            }
        } else if let act = activity {
            // 没有执行中任务了：找到刚跟丢的那条，推收尾帧（完成绿勾/失败）再结束。
            let ended = jobs.first { $0.id == act.attributes.jobId }
            let failed = ended?.status == "failed"
            let final = UmbraTaskActivityAttributes.ContentState(
                stepsDone: ended?.steps_done ?? 0,
                stepsTotal: ended?.steps_total ?? 0,
                statusLine: failed ? "任务失败" : "任务完成",
                finished: true, failed: failed)
            endCurrent(with: final)
        }
    }

    private func endCurrent(with final: UmbraTaskActivityAttributes.ContentState?) {
        guard let act = activity else { return }
        activity = nil
        Task {
            if let final {
                // 收尾帧停 4 秒再消失 —— 「做完了」值得被看见一眼，但不赖着。
                await act.end(ActivityContent(state: final, staleDate: nil),
                              dismissalPolicy: .after(Date().addingTimeInterval(4)))
            } else {
                await act.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// 「第 3/5 步」；服务端没给步骤数就用状态词，不编进度。
    private func line(for job: Job) -> String {
        if let t = job.steps_total, t > 0 {
            return "第 \(min((job.steps_done ?? 0) + 1, t))/\(t) 步"
        }
        return "执行中"
    }
}
