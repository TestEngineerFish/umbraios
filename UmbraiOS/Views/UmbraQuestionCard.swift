// 问答卡（QuestionCard）：秘书在派活**之前**把歧义问清楚。
//
// 分页式多题，一次性提交 —— 一题一屏比一次列十题更容易答完，也更容易回头改。
// 作答状态存在 ChatBlock.QuestionBlock 里而不是这个 View 里：卡片会随消息列表复用，
// 状态放 @State 的话滚出屏幕再滚回来就丢了。
//
// 取值照设计稿：卡宽 300、圆角 12、头部 11/13 内边距、选项行最小高 44 / 内边距 9-12 /
// 圆角 10 / 描边 1.5、选中标记 20 且多选是 6 圆角、单选是全圆。
//
// 「必答未答时提交键置灰并给一行原因，不弹 alert」—— 这条是设计稿明写的，别改成弹窗。
import SwiftUI

struct UmbraQuestionCard: View {
    let block: ChatBlock.QuestionBlock
    @EnvironmentObject private var chat: ChatViewModel

    /// 「自己填」这一项的内部 key。它不是服务端给的选项，提交时会被换成用户填的文字。
    private static let customKey = "__custom"
    private static let customLabel = "其它（自己写）"

    private var current: ChatBlock.QuestionItem? {
        guard !block.questions.isEmpty else { return nil }
        return block.questions[min(block.at, block.questions.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: UmbraMetric.sp4) {
                if !block.title.isEmpty {
                    Text(block.title)
                        .font(UmbraFont.sans(14.5, .w560))
                        .foregroundColor(UmbraColor.text)
                        .lineSpacing(14.5 * 0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if block.done { submitted } else { pending }
            }
            .padding(13)
        }
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous).fill(UmbraColor.card))
        // 先裁剪再描边：反过来的话描边会被自己裁掉一半，圆角处看起来比直边细。
        .clipShape(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous)
                .strokeBorder(block.done ? UmbraColor.successSoft : UmbraColor.orangeSoft, lineWidth: UmbraMetric.borderW)
        )
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            UmbraIcon(d: block.done ? UmbraIconPath.check : UmbraIconPath.task, size: 16, strokeWidth: 2)
            Text(block.done ? "秘书的问题 · 已答完" : "秘书想问你几件事")
                .font(UmbraFont.sans(13.5, .w600))
                .frame(maxWidth: .infinity, alignment: .leading)
            if !block.done {
                Text("\(min(block.at + 1, block.questions.count)) / \(block.questions.count)")
                    .font(UmbraFont.mono(12, .w600))
                    .opacity(0.75)
            }
        }
        .foregroundColor(block.done ? UmbraColor.success : UmbraColor.orangeText)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(block.done ? UmbraColor.successSoft : UmbraColor.orangeSoft)
    }

    // MARK: 作答中

    @ViewBuilder
    private var pending: some View {
        if let q = current {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(q.text)
                        .font(UmbraFont.sans(15, .w560))
                        .foregroundColor(UmbraColor.text)
                        .lineSpacing(15 * 0.45)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if q.multi { tag("可多选", fg: UmbraColor.orangeText, bg: UmbraColor.orangeSoft) }
                    if q.optional { tag("可跳过", fg: UmbraColor.faint, bg: UmbraColor.chip) }
                }

                VStack(spacing: 7) {
                    ForEach(options(q)) { o in
                        optionRow(q: q, key: o.id, label: o.label)
                    }
                }

                if picked(q).contains(Self.customKey) {
                    TextField("在这里作答", text: Binding(
                        get: { block.custom[q.id] ?? "" },
                        set: { chat.setCustomAnswer(cardId: block.cardId, questionId: q.id, text: $0) }
                    ))
                    .font(UmbraFont.sans(15, .w400))
                    .foregroundColor(UmbraColor.text)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, UmbraMetric.sp4)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous).fill(UmbraColor.bg))
                    .overlay(
                        RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous)
                            .strokeBorder(UmbraColor.orange, lineWidth: 1.5)
                    )
                }

                navRow(q)

                if let h = hint(q) {
                    Text(h)
                        .font(UmbraFont.sans(12, .w400))
                        .foregroundColor(UmbraColor.faint)
                        .lineSpacing(12 * 0.55)
                }
            }
        } else {
            // 服务端给了一张没有题目的卡：如实说，不要画一张空壳。
            Text("这张问答卡没有题目，等秘书补一下。")
                .font(UmbraFont.sans(13, .w400))
                .foregroundColor(UmbraColor.muted)
        }
    }

    /// 一个可选项。用具名类型而不是元组：ForEach 的 id 走 Identifiable 最稳，
    /// 对元组元素取 KeyPath 在旧版本 Swift 上不一定成立。
    private struct Opt: Identifiable {
        let id: String
        let label: String
    }

    /// 选项 = 服务端给的选项 +（允许自定义时）一个「自己填」。
    /// 服务端已经把「其他 / 其它 / Other」这类选项过滤掉了 —— 因为每题本来就带这个口子。
    private func options(_ q: ChatBlock.QuestionItem) -> [Opt] {
        var out = q.options.map { Opt(id: $0, label: $0) }
        if q.allowCustom { out.append(Opt(id: Self.customKey, label: Self.customLabel)) }
        return out
    }

    private func picked(_ q: ChatBlock.QuestionItem) -> [String] { block.picked[q.id] ?? [] }

    private func optionRow(q: ChatBlock.QuestionItem, key: String, label: String) -> some View {
        let on = picked(q).contains(key)
        return Button {
            chat.pickAnswer(cardId: block.cardId, questionId: q.id, option: key, multi: q.multi)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: q.multi ? 6 : 999, style: .continuous)
                        .fill(on ? UmbraColor.orange : Color.clear)
                    RoundedRectangle(cornerRadius: q.multi ? 6 : 999, style: .continuous)
                        .strokeBorder(on ? UmbraColor.orange : UmbraColor.border, lineWidth: 1.5)
                    if on {
                        UmbraIcon(d: UmbraIconPath.check, size: 12, strokeWidth: 3.2)
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 20, height: 20)

                Text(label)
                    .font(UmbraFont.sans(14.5, .w400))
                    .foregroundColor(on ? UmbraColor.orangeText : UmbraColor.text)
                    .lineSpacing(14.5 * 0.4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, UmbraMetric.sp4)
            .padding(.vertical, UmbraMetric.sp3)
            .frame(minHeight: UmbraMetric.tapMin)
            .background(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous)
                    .fill(on ? UmbraColor.orangeSoft : UmbraColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous)
                    .strokeBorder(on ? UmbraColor.orange : UmbraColor.border, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(UmbraMotion.tint, value: on)
    }

    private var isLast: Bool { block.at >= block.questions.count - 1 }

    /// 能不能往下走。最后一题看**整张卡**答没答完，中间题只看当前这题 ——
    /// 中途拦住会让用户没法先跳过再回来。
    private var canGo: Bool {
        guard let q = current else { return false }
        return isLast ? block.allFilled : block.filled(q)
    }

    private func navRow(_ q: ChatBlock.QuestionItem) -> some View {
        HStack(spacing: 8) {
            if block.at > 0 {
                Button {
                    chat.moveQuestion(cardId: block.cardId, by: -1)
                } label: {
                    Text("上一题")
                        .font(UmbraFont.sans(14.5, .w560))
                        .foregroundColor(UmbraColor.text)
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous).fill(UmbraColor.card))
                        .overlay(
                            RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous)
                                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button {
                guard canGo else { return }
                if isLast { chat.submitAnswers(cardId: block.cardId) }
                else { chat.moveQuestion(cardId: block.cardId, by: 1) }
            } label: {
                Text(isLast ? "提交答案" : "下一题")
                    .font(UmbraFont.sans(15, .w600))
                    .foregroundColor(canGo ? .white : UmbraColor.faint)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous)
                            .fill(canGo ? UmbraColor.orange : UmbraColor.chip)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGo)
        }
        .padding(.top, 2)
    }

    /// 置灰时必须给出原因，就一行，不弹窗。
    private func hint(_ q: ChatBlock.QuestionItem) -> String? {
        if canGo { return nil }
        return isLast ? "还有必答的题没答，答完才能提交。" : "这题是必答的。"
    }

    // MARK: 已提交

    private var submitted: some View {
        VStack(alignment: .leading, spacing: UmbraMetric.sp3) {
            HStack(spacing: 7) {
                UmbraIcon(d: UmbraIconPath.check, size: 15, strokeWidth: 2.4)
                Text(block.answered.isEmpty ? "别的设备已经答过了" : "已提交，秘书这就去安排")
                    .font(UmbraFont.sans(13.5, .w560))
            }
            .foregroundColor(UmbraColor.success)

            // 只在本端作答时才有明细。别的端答的，我们拿不到答案 —— 那就不显示，别编。
            ForEach(Array(block.answered.enumerated()), id: \.offset) { _, a in
                HStack(alignment: .top, spacing: 8) {
                    Text(a.q)
                        .font(UmbraFont.sans(12.5, .w400))
                        .foregroundColor(UmbraColor.faint)
                        .lineSpacing(12.5 * 0.45)
                        .frame(width: 96, alignment: .leading)
                    Text(a.v)
                        .font(UmbraFont.sans(12.5, .w560))
                        .foregroundColor(UmbraColor.text)
                        .lineSpacing(12.5 * 0.45)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UmbraColor.chip))
            }
        }
    }

    private func tag(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(UmbraFont.sans(11, .w600))
            .foregroundColor(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
    }
}
