// 任务 Live Activity：灵动岛（胶囊 / 展开 / minimal）+ 锁屏实况卡。
//
// 形态按规范增补 4.3：
//   胶囊态 = 橙色进度弧 + 百分比（等宽字）；
//   展开态 = 橙色字标「U」+ 任务名 + 一句事件 + 40px 进度环；
//   锁屏卡 = 深色玻璃：进度弧 + 任务名 + 事件 + 百分比。
// 数据全部来自主 App 推的 ContentState（TasksViewModel 轮询 → UmbraLiveActivityController），
// 和小组件同源同 tick；服务端没给步骤数时不显示百分比（percentText = "…"）。
// 收尾态（finished）：环换成绿勾/红叉语义色，停 4 秒自动消失（控制器里定的）。
import ActivityKit
import WidgetKit
import SwiftUI

struct UmbraTaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UmbraTaskActivityAttributes.self) { context in
            lockCard(context)
        } dynamicIsland: { context in
            DynamicIsland {
                // 展开态
                DynamicIslandExpandedRegion(.leading) {
                    logo.padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.attributes.goal)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(context.state.statusLine)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ZStack {
                        ring(context.state, size: 40, lineWidth: 4)
                        Text(context.state.percentText)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundColor(.white)
                    }
                    .padding(.trailing, 4)
                }
            } compactLeading: {
                ring(context.state, size: 16, lineWidth: 2.5)
            } compactTrailing: {
                Text(context.state.percentText)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(stateColor(context.state))
            } minimal: {
                ring(context.state, size: 16, lineWidth: 2.5)
            }
            // 点任意形态 → 直达这条任务的详情页。
            .widgetURL(URL(string: "umbra://task/\(context.attributes.taskId)"))
            .keylineTint(WTheme.orange)
        }
    }

    // MARK: 锁屏卡（深色玻璃，规范：锁屏通知卡两个主题都深色）

    private func lockCard(_ context: ActivityViewContext<UmbraTaskActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            ZStack {
                ring(context.state, size: 36, lineWidth: 3.5, track: Color.white.opacity(0.16))
                if context.state.finished {
                    Image(systemName: context.state.failed ? "xmark" : "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(context.state.failed ? WTheme.danger : WTheme.success)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.goal)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(context.state.statusLine)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !context.state.finished {
                Text(context.state.percentText)
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .activityBackgroundTint(WTheme.activityBg.opacity(0.85))
        .activitySystemActionForegroundColor(.white)
        .widgetURL(URL(string: "umbra://task/\(context.attributes.taskId)"))
    }

    // MARK: 小件

    /// 橙色字标「U」（展开态左侧，规范 4.3）。
    private var logo: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(WTheme.orange)
            .frame(width: 28, height: 28)
            .overlay(Text("U").font(.system(size: 14, weight: .bold)).foregroundColor(.white))
    }

    private func ring(_ state: UmbraTaskActivityAttributes.ContentState,
                      size: CGFloat, lineWidth: CGFloat,
                      track: Color = Color.white.opacity(0.22)) -> some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: state.finished ? 1 : CGFloat(state.percent ?? 0.3))
                .stroke(state.finished ? (state.failed ? WTheme.danger : WTheme.success) : WTheme.orange,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }

    private func stateColor(_ state: UmbraTaskActivityAttributes.ContentState) -> Color {
        state.finished ? (state.failed ? WTheme.danger : WTheme.success) : WTheme.orange
    }
}
