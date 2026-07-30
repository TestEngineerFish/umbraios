// Umbra 基础组件（第一批）：卡片、列表行、分区标题、按钮、分段控件、状态徽标、进度条、
// 状态点、连接状态行、标签胶囊、底部动作条。
//
// 取值全部来自主设计稿 Umbra iOS.dc.html 的内联样式，逐个抄的，不是目测。
// 几处和 ios.css 的通用 token 不一致，是设计稿里的实际值，注释里标了出处：
//   · 按钮圆角 11px（不是 --radius-md:10px）
//   · 分段控件外 9px / 内 7px（增补规范里点名「圆角 9/7，高 30」）
// 通用 token 用于新写的东西，这些具名组件按设计稿的实测值走。
import SwiftUI

// MARK: - 卡片
//
// **无阴影**。分层靠 1px 描边 + 底色差 —— 交接文档的硬规则，自查清单里也有一条。
struct UmbraCard<Content: View>: View {
    var pad: CGFloat = UmbraMetric.cardPad
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(pad)
            .background(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                    .fill(UmbraColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                    .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
            )
    }
}

/// 列表分组容器：一张卡里若干行，行之间是 --border-soft 的发丝线。
/// 行本身不画描边，只有容器画 —— 每行都描边会出现双线。
struct UmbraGroupCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                    .fill(UmbraColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                    .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
            )
            .clipShape(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous))
    }
}

/// 组内分隔线。放在行与行之间，第一行前面不放。
struct UmbraRowDivider: View {
    var inset: CGFloat = 0
    var body: some View {
        Rectangle()
            .fill(UmbraColor.borderSoft)
            .frame(height: UmbraMetric.borderW)
            .padding(.leading, inset)
    }
}

// MARK: - 列表行
//
// 主文 16/560、副文 13/400/--muted。最小高度 44，带副文 60 —— 这两个值是触达底线，
// 不是留白偏好，改小会直接违反自查清单里的「所有点击区 ≥ 44×44」。
struct UmbraListRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    /// 是否画右侧的 chevron。可点进二级页的行都要画，不能靠用户猜。
    var showsChevron: Bool = false
    var action: (() -> Void)? = nil
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let row = HStack(spacing: UmbraMetric.sp3) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(UmbraFont.rowTitle)
                    .foregroundColor(UmbraColor.text)
                if let s = subtitle, !s.isEmpty {
                    Text(s)
                        .font(UmbraFont.rowSub)
                        .foregroundColor(UmbraColor.muted)
                }
            }
            Spacer(minLength: UmbraMetric.sp2)
            trailing()
            if showsChevron {
                UmbraIcon(d: UmbraIconPath.chevronRight, size: 16)
                    .foregroundColor(UmbraColor.faint)
            }
        }
        .padding(.horizontal, UmbraMetric.sp4)
        .padding(.vertical, UmbraMetric.sp3)
        .frame(minHeight: subtitle == nil ? UmbraMetric.rowMinH : UmbraMetric.rowMinHSub)
        .contentShape(Rectangle())   // 整行可点，不是只有文字可点

        if let action {
            Button(action: action) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }
}

extension UmbraListRow where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, showsChevron: Bool = false, action: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, showsChevron: showsChevron, action: action,
                  leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

// MARK: - 标题
//
// 页面标题 27/650；分区小标题 11.5/600 + .06em 字距 + --faint。
struct UmbraPageTitle: View {
    let text: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(UmbraFont.pageTitle).foregroundColor(UmbraColor.text)
            if let s = subtitle {
                Text(s).font(UmbraFont.rowSub).foregroundColor(UmbraColor.muted)
            }
        }
    }
}

struct UmbraSectionLabel: View {
    let text: String
    var color: Color = UmbraColor.faint
    var body: some View {
        Text(text)
            .font(UmbraFont.sans(11.5, .w600))
            .tracking(UmbraFont.labelTracking(11.5))
            .foregroundColor(color)
    }
}

/// 字段标签（保险箱记录、表单）：12/560 + .06em + --faint。
struct UmbraFieldLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(UmbraFont.fieldLabel)
            .tracking(UmbraFont.labelTracking(12))
            .foregroundColor(UmbraColor.faint)
    }
}

// MARK: - 按钮
//
// 设计稿实测值：高 48、圆角 11。文案是动词 2–4 字（「开始执行」「重试任务」「停止」），
// 禁用「确定」「提交」——文案规则在交接文档的 Voice 一节，这里只管样式。
enum UmbraButtonKind {
    /// 橙实底 + 白字 600/16。一屏只该有一个（橙色「一屏三处」规则的第 ① 处）。
    case primary
    /// 描边 + card 底 + 主文色 560/15.5。
    case secondary
    /// 描边 + card 底 + --danger 字 560/16。**描边**红，不是实心红 ——
    /// 实心红只允许出现在确认弹窗的最终动作上。
    case dangerOutline
    /// 实心红。只给确认弹窗的最终动作用。
    case dangerSolid
    /// 置灰不可点：--chip 底 + --faint 字。旁边必须有一行说明为什么不能点，
    /// 「必答未答时提交键置灰并给一行原因，不弹 alert」是设计稿明写的。
    case disabled
}

struct UmbraButton: View {
    let title: String
    var kind: UmbraButtonKind = .primary
    var height: CGFloat = 48
    var action: () -> Void = {}

    private var bg: Color {
        switch kind {
        case .primary: return UmbraColor.orange
        case .dangerSolid: return UmbraColor.danger
        case .disabled: return UmbraColor.chip
        case .secondary, .dangerOutline: return UmbraColor.card
        }
    }
    private var fg: Color {
        switch kind {
        case .primary, .dangerSolid: return .white
        case .disabled: return UmbraColor.faint
        case .secondary: return UmbraColor.text
        case .dangerOutline: return UmbraColor.danger
        }
    }
    private var stroked: Bool {
        switch kind { case .secondary, .dangerOutline: return true; default: return false }
    }
    private var font: Font {
        switch kind {
        case .secondary: return UmbraFont.sans(15.5, .w560)
        case .primary, .dangerSolid: return UmbraFont.sans(16, .w600)
        default: return UmbraFont.sans(16, .w560)
        }
    }

    var body: some View {
        Button(action: { if kind != .disabled { action() } }) {
            Text(title)
                .font(font)
                .foregroundColor(fg)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(bg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(stroked ? UmbraColor.border : .clear, lineWidth: UmbraMetric.borderW)
                )
        }
        .buttonStyle(.plain)
        .disabled(kind == .disabled)
    }
}

/// 底部动作条：贴底、上描边、左右 16、上 10 下 14、间距 8。
/// 破坏性操作**不许**放这里 —— 收进右上菜单 / 长按菜单 / 左滑。
struct UmbraBottomBar<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.top, 10)
            .padding(.bottom, UmbraMetric.sp5)
            .background(UmbraColor.bg)
            .overlay(alignment: .top) {
                Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
            }
    }
}

// MARK: - 分段控件
//
// iOS 特有组件（桌面端没有）。外层 --chip 底 + 2px 内边距 + 圆角 9；
// 选中片是 --card 白片 + 圆角 7；行高 30；文字 560/13.5；计数用等宽 12 + 70% 透明。
// 刻意不用系统的 Picker(.segmented)：它的高度、圆角、选中片配色都改不到设计值。
struct UmbraSegmentedControl<T: Hashable>: View {
    struct Item: Identifiable {
        let value: T
        let label: String
        /// 右侧计数，nil = 不显示。设计稿里提醒和灵感都带计数。
        var count: Int? = nil
        // 用具体类型而不是 `some Hashable`：opaque 类型满足 associatedtype 需要
        // 较新的编译器，而工程的 SWIFT_VERSION 是 5.0，没必要在这种地方赌。
        var id: T { value }
    }

    let items: [Item]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let on = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    HStack(spacing: 6) {
                        Text(item.label).font(UmbraFont.sans(13.5, .w560))
                        if let c = item.count {
                            Text("\(c)").font(UmbraFont.mono(12)).opacity(0.7)
                        }
                    }
                    .foregroundColor(on ? UmbraColor.text : UmbraColor.muted)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: UmbraMetric.segmentH)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(on ? UmbraColor.card : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UmbraColor.chip))
        .animation(UmbraMotion.tint, value: selection)
    }
}

// MARK: - 状态
//
// **状态永不只靠颜色**：徽标一律图标 + 文字。自查清单里有这一条，
// 所以 UmbraStatusBadge 不提供「只有颜色点」的形态。
enum UmbraStatus: String {
    case running, done, awaitingReview, failed, pending, cancelled, suspended

    /// 固定映射，来自交接文档：运行中 = 旋转弧、已完成 = 对勾、需确认 = 三角感叹、
    /// 失败 = 圆叉、排队中 = 时钟。改这里等于改全站语义。
    var iconPath: String {
        switch self {
        case .running: return UmbraIconPath.spinnerArc
        case .done: return UmbraIconPath.check
        case .awaitingReview, .suspended: return UmbraIconPath.alertTriangle
        case .failed: return UmbraIconPath.xCircle
        case .pending, .cancelled: return UmbraIconPath.clock
        }
    }
    var label: String {
        switch self {
        case .running: return "执行中"
        case .done: return "已完成"
        case .awaitingReview: return "待确认"
        case .failed: return "失败"
        case .pending: return "待执行"
        case .cancelled: return "已取消"
        case .suspended: return "已挂起"
        }
    }
    var fg: Color {
        switch self {
        case .running: return UmbraColor.orangeText
        case .done: return UmbraColor.success
        case .awaitingReview, .suspended: return UmbraColor.warning
        case .failed: return UmbraColor.danger
        case .pending, .cancelled: return UmbraColor.muted
        }
    }
    var soft: Color {
        switch self {
        case .running: return UmbraColor.orangeSoft
        case .done: return UmbraColor.successSoft
        case .awaitingReview, .suspended: return UmbraColor.warningSoft
        case .failed: return UmbraColor.dangerSoft
        case .pending, .cancelled: return UmbraColor.chip
        }
    }
    /// 进度条颜色跟状态走。
    var bar: Color {
        switch self {
        case .running: return UmbraColor.orange
        case .done: return UmbraColor.success
        case .awaitingReview, .suspended: return UmbraColor.warning
        case .failed: return UmbraColor.danger
        case .pending, .cancelled: return UmbraColor.muted
        }
    }
}

struct UmbraStatusBadge: View {
    let status: UmbraStatus
    /// 详情页用大一档（3/9 内边距），列表用小一档（2/8）。
    var compact: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            if status == .running {
                UmbraSpinningIcon(d: status.iconPath, size: compact ? 11 : 12, strokeWidth: 2.1)
            } else {
                UmbraIcon(d: status.iconPath, size: compact ? 11 : 12, strokeWidth: 2.1)
            }
            Text(status.label).font(UmbraFont.sans(compact ? 11.5 : 12.5, .w600))
        }
        .foregroundColor(status.fg)
        .padding(.horizontal, compact ? 8 : 9)
        .padding(.vertical, compact ? 2 : 3)
        .background(Capsule().fill(status.soft))
    }
}

/// 状态点 7px。实心 = 在线 / 启用；空心圈 = 离线 / 停用。
/// 只在旁边有文字时使用 —— 单独一个点不构成状态表达。
struct UmbraStatusDot: View {
    var on: Bool
    var color: Color = UmbraColor.success
    var body: some View {
        Group {
            if on {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(UmbraColor.border, lineWidth: 1.5)
            }
        }
        .frame(width: UmbraMetric.statusDot, height: UmbraMetric.statusDot)
    }
}

/// 连接状态行（StatusBarChip）：分组标题右侧的「状态点 + 一行小字」，
/// 替代占一整行的状态卡。
struct UmbraStatusBarChip: View {
    var online: Bool
    var text: String
    var body: some View {
        HStack(spacing: 6) {
            UmbraStatusDot(on: online, color: online ? UmbraColor.success : UmbraColor.faint)
            Text(text)
                .font(UmbraFont.sans(12, .w400))
                .foregroundColor(online ? UmbraColor.success : UmbraColor.faint)
                .lineLimit(1)
                .truncationMode(.middle)   // 服务端地址中间截断，头尾都要看得见
        }
    }
}

// MARK: - 进度条
//
// 高 4、槽 --track、全圆角。progress 会被夹在 0…1 —— 传进来的百分比出界时
// 宁可画满/画空，也不要画出容器（那种溢出在截图评审里很难看出来）。
struct UmbraProgressBar: View {
    var progress: Double
    var color: Color = UmbraColor.orange
    /// 默认 4（token 值）。任务详情的「总进度」在设计稿里是 8 ——
    /// 同一个组件两个高度，所以做成参数而不是复制一份组件。
    var height: CGFloat = UmbraMetric.progressH

    var body: some View {
        GeometryReader { geo in
            let p = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(UmbraColor.track)
                Capsule().fill(color).frame(width: geo.size.width * p)
            }
        }
        .frame(height: height)
    }
}

/// 密码强度（StrengthMeter）：4px 条 + 文字标签，**永不只靠颜色**。
struct UmbraStrengthMeter: View {
    /// 0…3 四档
    let level: Int
    var body: some View {
        let (label, color, ratio): (String, Color, Double) = {
            switch max(0, min(level, 3)) {
            case 0: return ("弱", UmbraColor.danger, 0.25)
            case 1: return ("一般", UmbraColor.warning, 0.5)
            case 2: return ("强", UmbraColor.success, 0.75)
            default: return ("很强", UmbraColor.success, 1.0)
            }
        }()
        HStack(spacing: UmbraMetric.sp3) {
            UmbraProgressBar(progress: ratio, color: color)
            Text("强度 \(label)")
                .font(UmbraFont.sans(12, .w560))
                .foregroundColor(color)
                .fixedSize()
        }
    }
}

// MARK: - 胶囊 / 标签
//
// 标签筛选条用：高 27、左右 10、全圆角、文字 12.5。
struct UmbraTagPill: View {
    let text: String
    var selected: Bool = false
    var count: Int? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        let pill = HStack(spacing: 5) {
            Text(text).font(UmbraFont.sans(12.5, selected ? .w560 : .w400))
            if let c = count {
                Text("\(c)").font(UmbraFont.mono(11)).opacity(0.75)
            }
        }
        .foregroundColor(selected ? UmbraColor.orangeText : UmbraColor.muted)
        .padding(.horizontal, 10)
        .frame(height: 27)
        .background(Capsule().fill(selected ? UmbraColor.orangeSoft : UmbraColor.card))
        .overlay(Capsule().strokeBorder(selected ? UmbraColor.orange : UmbraColor.border, lineWidth: UmbraMetric.borderW))
        .contentShape(Capsule())

        if let action {
            // 胶囊本身只有 27 高，够不到 44 —— 用垂直留白把点击区撑起来，
            // 而不是把胶囊画大（画大就偏离设计值了）。
            Button(action: action) { pill.padding(.vertical, 9) }
                .buttonStyle(.plain)
        } else {
            pill
        }
    }
}

// MARK: - 空态
//
// 空态必须有具体文案，光一句「暂无数据」不算。可给一个主动作。
struct UmbraEmptyState: View {
    var iconPath: String? = nil
    let title: String
    var hint: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: UmbraMetric.sp4) {
            if let p = iconPath {
                UmbraIcon(d: p, size: 34, strokeWidth: 1.8)
                    .foregroundColor(UmbraColor.faint)
            }
            Text(title)
                .font(UmbraFont.sans(16, .w600))
                .foregroundColor(UmbraColor.text)
            if let h = hint {
                Text(h)
                    .font(UmbraFont.sans(13, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            if let t = actionTitle, let a = action {
                UmbraButton(title: t, kind: .primary, height: 44, action: a)
                    .frame(maxWidth: 200)
                    .padding(.top, UmbraMetric.sp1)
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 搜索框
//
// 任务列表、灵感列表、保险箱都用它。高 38、--chip 底、圆角 10、左右 12、图标 16、文字 15。
// 右侧可以挂一段小字（灵感列表挂的是当前排序方式）。
struct UmbraSearchField: View {
    let placeholder: String
    @Binding var text: String
    /// 右侧的一小段说明文字，nil = 不显示。
    var trailingNote: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            UmbraIcon(d: UmbraIconPath.search, size: 16, strokeWidth: 2)
                .foregroundColor(UmbraColor.faint)
            TextField(placeholder, text: $text)
                .font(UmbraFont.sans(15, .w400))
                .foregroundColor(UmbraColor.text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
            if !text.isEmpty {
                // 清空按钮：搜索框里没有清空键的话，用户只能一个字一个字删。
                Button { text = "" } label: {
                    UmbraIcon(d: UmbraIconPath.xCircle, size: 16, strokeWidth: 1.9)
                        .foregroundColor(UmbraColor.faint)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if let note = trailingNote {
                Text(note)
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(UmbraColor.faint)
            }
        }
        .padding(.horizontal, UmbraMetric.sp4)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous).fill(UmbraColor.chip))
    }
}

// MARK: - 筛选胶囊行
//
// 横向可滚动的一排胶囊（任务的状态筛选、灵感的分类筛选）。
// 用 ScrollView 而不是换行的 FlowLayout：设计稿是「一行放不下就横滑」，
// 换行会让筛选条在标签多的时候把列表挤下去半屏。
struct UmbraFilterChips<T: Hashable>: View {
    struct Item: Identifiable {
        let value: T
        let label: String
        var count: Int? = nil
        var id: T { value }
    }

    let items: [Item]
    @Binding var selection: T

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(items) { item in
                    UmbraTagPill(text: item.label,
                                 selected: item.value == selection,
                                 count: item.count) {
                        selection = item.value
                    }
                }
            }
            .padding(.horizontal, UmbraMetric.pagePadX)
        }
    }
}

// MARK: - 左滑操作行（SwipeActionRow）
//
// 行底露出操作块，行本体 translateX，松手 .16s cubic-bezier(.2,.8,.3,1) 回弹（UmbraMotion.swipe）。
// 不用系统的 .swipeActions：它只在 List 里生效，而这里的列表是 ScrollView + VStack
//（设计稿的分组间距、卡片圆角、分组标题样式都做不到系统 List 里）。
//
// 只支持右侧操作 —— 设计稿里左滑露出的都在右边，没有左侧操作的场景。
struct UmbraSwipeAction: Identifiable {
    let id = UUID()
    let label: String
    let width: CGFloat
    let background: Color
    let action: () -> Void
}

struct UmbraSwipeRow<Content: View>: View {
    let actions: [UmbraSwipeAction]
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var opened = false

    private var total: CGFloat { actions.reduce(0) { $0 + $1.width } }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                ForEach(actions) { a in
                    Button {
                        close()
                        a.action()
                    } label: {
                        Text(a.label)
                            .font(UmbraFont.sans(12.5, .w560))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .lineSpacing(12.5 * 0.35)
                            .frame(width: a.width)
                            .frame(maxHeight: .infinity)
                            .background(a.background)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            content()
                .background(UmbraColor.bg)   // 不透明，否则滑动时能看见底下的操作块透上来
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { g in
                            // 只跟手往左；往右最多回到 0（没有左侧操作）。
                            let base = opened ? -total : 0
                            offset = min(0, max(-total - 24, base + g.translation.width))
                        }
                        .onEnded { g in
                            let shouldOpen = (offset + g.predictedEndTranslation.width * 0.2) < -total / 2
                            withAnimation(UmbraMotion.swipe) {
                                opened = shouldOpen
                                offset = shouldOpen ? -total : 0
                            }
                        }
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: UmbraMetric.radiusControl, style: .continuous))
    }

    private func close() {
        withAnimation(UmbraMotion.swipe) {
            opened = false
            offset = 0
        }
    }
}
