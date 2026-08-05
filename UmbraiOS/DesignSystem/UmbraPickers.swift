// 日期 / 时间滚轮选择器 —— 底部玻璃面板 + 滚轮列。
//
// 交接清单第 3 条：**禁止用浏览器原生 date/time picker 的替代品**（文本输入、
// 日历弹窗都不行），统一走滚轮；点击**整个字段区域**弹出，不是点图标。
//
// 形态：
//   日期 = 单列「8月5日 周三」（今天显示「今天」）。系统 DatePicker 的 .date 滚轮
//   在中文下是 年/月/日 三列，不是设计要的单列 —— 所以日期列用 Picker 自己排，
//   数据是「今天 ±2 年」的日序列；时间 = 时/分双列，行高与居中高亮都是系统滚轮自带。
//   「取消/确定」按按钮角色表：取消 text 400、确定橙 600。
import SwiftUI

// MARK: - 面板本体

struct UmbraWheelPanel: View {
    enum Mode {
        /// 单列日期（8月5日 周三）
        case date
        /// 双列 时 / 分
        case time
    }

    let title: String
    let mode: Mode
    /// 初值。确定时把改动合并回同一个 Date 的对应部分（改日期不动时分，反之亦然）。
    let initial: Date
    var onCancel: () -> Void
    var onConfirm: (Date) -> Void

    /// 日期模式：距今天的天数偏移；时间模式：时 / 分。
    @State private var dayOffset = 0
    @State private var hour = 9
    @State private var minute = 0

    /// 可选的日序列：今天 ±2 年。滚轮是懒加载的，行数多不影响性能。
    private let dayRange = -730...730

    var body: some View {
        VStack(spacing: 0) {
            // 头部：取消 / 标题 / 确定
            HStack {
                Button("取消", action: onCancel)
                    .font(UmbraFont.sans(16, .w400))
                    .foregroundColor(UmbraColor.text)
                Spacer(minLength: 0)
                Text(title)
                    .font(UmbraFont.sans(15, .w600))
                    .foregroundColor(UmbraColor.text)
                Spacer(minLength: 0)
                Button("确定") { onConfirm(composed) }
                    .font(UmbraFont.sans(16, .w600))
                    .foregroundColor(UmbraColor.orange)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, UmbraMetric.pagePadX)
            .frame(height: 52)

            switch mode {
            case .date:
                Picker("日期", selection: $dayOffset) {
                    ForEach(Array(dayRange), id: \.self) { off in
                        Text(Self.dayLabel(offset: off)).tag(off)
                    }
                }
                .pickerStyle(.wheel)
            case .time:
                HStack(spacing: 0) {
                    Picker("时", selection: $hour) {
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                    .pickerStyle(.wheel)
                    Picker("分", selection: $minute) {
                        ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                    .pickerStyle(.wheel)
                }
            }
        }
        .padding(.bottom, UmbraMetric.sp3)
        .onAppear(perform: seed)
    }

    /// 从 initial 拆出滚轮初值。放 onAppear 而不是 init：@State 在 init 里赋值
    /// 会被 SwiftUI 的状态恢复盖掉，这是老坑。
    private func seed() {
        let cal = Calendar.current
        dayOffset = cal.dateComponents([.day],
                                       from: cal.startOfDay(for: Date()),
                                       to: cal.startOfDay(for: initial)).day ?? 0
        hour = cal.component(.hour, from: initial)
        minute = cal.component(.minute, from: initial)
    }

    /// 把滚轮值合并回 Date：日期模式只换年月日，时间模式只换时分 ——
    /// 两个面板各管一半，谁也不覆盖谁。
    private var composed: Date {
        let cal = Calendar.current
        switch mode {
        case .date:
            let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: Date())) ?? initial
            let hm = cal.dateComponents([.hour, .minute], from: initial)
            return cal.date(bySettingHour: hm.hour ?? 9, minute: hm.minute ?? 0, second: 0, of: day) ?? initial
        case .time:
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: initial) ?? initial
        }
    }

    /// 「今天」/「明天」/「8月5日 周三」。相对词只给最近两天 —— 再远的相对词
    ///（大后天…）读起来要换算，不如直接给日期。
    static func dayLabel(offset: Int) -> String {
        switch offset {
        case 0: return "今天"
        case 1: return "明天"
        default:
            let cal = Calendar.current
            let d = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date())) ?? Date()
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "M月d日 EEE"
            return f.string(from: d)
        }
    }
}

// MARK: - 挂载扩展
//
// 页面侧一行挂上：.umbraWheelPicker(isPresented:, title:, mode:, date:)
// 玻璃底、圆角 26、固定高度 detent 都在这里统一给，各页不用重复。
extension View {
    func umbraWheelPicker(isPresented: Binding<Bool>,
                          title: String,
                          mode: UmbraWheelPanel.Mode,
                          date: Binding<Date>) -> some View {
        sheet(isPresented: isPresented) {
            UmbraWheelPanel(
                title: title,
                mode: mode,
                initial: date.wrappedValue,
                onCancel: { isPresented.wrappedValue = false },
                onConfirm: { new in
                    date.wrappedValue = new
                    isPresented.wrappedValue = false
                }
            )
            .presentationDetents([.height(300)])
            .presentationCornerRadius(UmbraMetric.radiusSheet)
            .presentationBackground(.ultraThinMaterial)
            .presentationDragIndicator(.hidden)
        }
    }
}
