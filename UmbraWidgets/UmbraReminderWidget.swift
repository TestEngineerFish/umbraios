// 中号主屏小组件 · 今天的提醒（规范增补 4.3）。
//
// 最多三行：勾选圈只作展示（小组件不做写操作，规范原话），点击整卡进 App 提醒列表。
// 已过期的行圈和时间转 danger 并标「已过期」。数据来自主 App 写的快照（本机提醒）。
import WidgetKit
import SwiftUI

struct UmbraReminderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: UmbraShared.reminderWidgetKind, provider: ReminderProvider()) { entry in
            ReminderWidgetView(entry: entry)
                .containerBackground(for: .widget) { WTheme.card }
        }
        .configurationDisplayName("提醒 · 今天")
        .description("今天到点和已过期的提醒。勾选要进 App。")
        .supportedFamilies([.systemMedium])
    }
}

struct ReminderEntry: TimelineEntry {
    let date: Date
    let snap: UmbraReminderSnapshot?
}

struct ReminderProvider: TimelineProvider {
    func placeholder(in context: Context) -> ReminderEntry {
        ReminderEntry(date: Date(), snap: UmbraReminderSnapshot(rows: [
            .init(id: "1", text: "给房东转房租", time: "09:00", overdue: true),
            .init(id: "2", text: "交周报", time: "18:00", overdue: false),
            .init(id: "3", text: "买猫粮", time: "21:00", overdue: false)
        ], savedAt: Date()))
    }
    func getSnapshot(in context: Context, completion: @escaping (ReminderEntry) -> Void) {
        completion(ReminderEntry(date: Date(), snap: UmbraShared.loadReminderSnapshot()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ReminderEntry>) -> Void) {
        // 主 App 每次改动都会指名重载；这里兜 30 分钟的底，跨点（如过零点）也能翻新。
        let entry = ReminderEntry(date: Date(), snap: UmbraShared.loadReminderSnapshot())
        completion(Timeline(entries: [entry],
                            policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

struct ReminderWidgetView: View {
    let entry: ReminderEntry

    /// 设计稿原型标的是 ×3，实机中号组件竖向还有一行余量 —— 放 4 行（用户实测点名）。
    /// 超过 4 条时右上角的「N 条」负责说明还有没露出来的。
    private var rows: [UmbraReminderSnapshot.Row] { Array((entry.snap?.rows ?? []).prefix(4)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(WTheme.orange)
                    .frame(width: 16, height: 16)
                    .overlay(Text("U").font(.system(size: 9, weight: .bold)).foregroundColor(.white))
                Text("提醒 · 今天")
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.6)
                    .foregroundColor(WTheme.faint)
                Spacer(minLength: 0)
                if let n = entry.snap?.rows.count, n > 0 {
                    Text("\(n) 条")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundColor(WTheme.faint)
                }
            }

            if rows.isEmpty {
                Spacer(minLength: 0)
                Text(entry.snap == nil
                     ? "打开 App 的提醒页后，这里会显示今天的提醒。"
                     : "今天没有到点的提醒。")
                    .font(.system(size: 12.5))
                    .foregroundColor(WTheme.muted)
                Spacer(minLength: 0)
            } else {
                ForEach(rows) { r in row(r) }
                Spacer(minLength: 0)
            }
        }
        .widgetURL(URL(string: "umbra://reminders"))
    }

    private func row(_ r: UmbraReminderSnapshot.Row) -> some View {
        HStack(spacing: 9) {
            Circle()
                .strokeBorder(r.overdue ? WTheme.danger : WTheme.faint, lineWidth: 1.6)
                .frame(width: 17, height: 17)
            Text(r.text)
                .font(.system(size: 13.5))
                .foregroundColor(WTheme.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(r.overdue ? "\(r.time) 已过期" : r.time)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundColor(r.overdue ? WTheme.danger : WTheme.faint)
        }
    }
}
