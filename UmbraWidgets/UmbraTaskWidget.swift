// 小号主屏小组件 · 任务（规范增补 4.3）。
//
// 有执行中任务：进度环 + 百分比 + 任务名，点击直达任务详情；
// 没有：显示今天完成数（也是真实数据，不摆假任务）。
// 数据只读主 App 写进 App Group 的快照；快照超过 10 分钟没更新要显示「更新于」——
// 规范原话：「数据超过 10 分钟未更新时显示更新于时间」。
import WidgetKit
import SwiftUI

struct UmbraTaskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: UmbraShared.taskWidgetKind, provider: TaskProvider()) { entry in
            TaskWidgetView(entry: entry)
                .containerBackground(for: .widget) { WTheme.card }
        }
        .configurationDisplayName("任务")
        .description("执行中任务的进度；没有时显示今天完成数。")
        .supportedFamilies([.systemSmall])
    }
}

struct TaskEntry: TimelineEntry {
    let date: Date
    /// nil = App Group 里还没有快照（App 还没打开过任务页）。
    let snap: UmbraTaskSnapshot?
}

struct TaskProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaskEntry {
        // 占位帧只给系统的模糊预览用（redacted），不会当真数据显示。
        TaskEntry(date: Date(),
                  snap: UmbraTaskSnapshot(runningId: "x", runningGoal: "整理季度汇报的图表",
                                          stepsDone: 2, stepsTotal: 5, todayDone: 3, savedAt: Date()))
    }
    func getSnapshot(in context: Context, completion: @escaping (TaskEntry) -> Void) {
        completion(TaskEntry(date: Date(), snap: UmbraShared.loadTaskSnapshot()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TaskEntry>) -> Void) {
        // 数据驱动的刷新靠主 App 的 reloadTimelines；这里只兜一个 15 分钟的底
        //（到点重读快照，主要为了让「更新于」的口径跟上）。
        let entry = TaskEntry(date: Date(), snap: UmbraShared.loadTaskSnapshot())
        completion(Timeline(entries: [entry],
                            policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct TaskWidgetView: View {
    let entry: TaskEntry

    var body: some View {
        Group {
            if let s = entry.snap {
                if let goal = s.runningGoal {
                    running(s, goal: goal)
                        .widgetURL(URL(string: "umbra://task/\(s.runningId ?? "")"))
                } else {
                    idle(s)
                        .widgetURL(URL(string: "umbra://tasks"))
                }
            } else {
                empty
                    .widgetURL(URL(string: "umbra://tasks"))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(WTheme.orange)
                .frame(width: 16, height: 16)
                .overlay(Text("U").font(.system(size: 9, weight: .bold)).foregroundColor(.white))
            Text("任务")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .foregroundColor(WTheme.faint)
            Spacer(minLength: 0)
        }
    }

    private func running(_ s: UmbraTaskSnapshot, goal: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 4)
            HStack {
                Spacer(minLength: 0)
                ZStack {
                    WProgressRing(percent: s.percent, size: 58, lineWidth: 6)
                    Text(s.percent.map { "\(Int(($0 * 100).rounded()))%" } ?? "…")
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundColor(WTheme.orangeText)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 4)
            Text(goal)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(WTheme.text)
                .lineLimit(1)
            staleLine(s)
        }
    }

    private func idle(_ s: UmbraTaskSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 0)
            Text("\(s.todayDone)")
                .font(.system(size: 34, weight: .bold).monospacedDigit())
                .foregroundColor(WTheme.text)
            Text("今天完成")
                .font(.system(size: 12))
                .foregroundColor(WTheme.muted)
            staleLine(s)
        }
    }

    /// 快照超过 10 分钟没更新：亮出「更新于」。过期数据必须自己承认过期。
    @ViewBuilder
    private func staleLine(_ s: UmbraTaskSnapshot) -> some View {
        if Date().timeIntervalSince(s.savedAt) > 10 * 60 {
            Text("更新于 \(s.savedAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 10))
                .foregroundColor(WTheme.faint)
                .padding(.top, 2)
        }
    }

    /// 还没有任何快照（App 没打开过任务页）：说清楚，不摆假数据。
    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            Text("打开 App 的任务页后，这里会显示执行中任务的进度。")
                .font(.system(size: 12))
                .foregroundColor(WTheme.muted)
        }
    }
}
