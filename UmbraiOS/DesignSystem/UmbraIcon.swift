// Umbra 图标：把 SVG path 数据画成 SwiftUI 描边图形。
//
// 为什么不用 SF Symbols：交接文档要求「fill:none、stroke:currentColor、stroke-width 1.8–2.2、
// 圆头、viewBox 0 0 24 24」，并明确禁止填充图标 / 彩色图标 / emoji 当图标 / 用 ✓ ✗ ⚠ 代替图标。
// SF Symbols 的线宽和视觉重心跟 Lucide 对不上，混用会让同一屏里的图标看起来不是一套。
// 也不引第三方包：图标路径本来就在设计稿里，抄过来比拉一个依赖轻。
//
// 解析器只认 M / L / C / Z ——路径数据在生成阶段已经归一化过（见 UmbraIconPath 的说明），
// 弧和相对坐标都不会出现在这里。这是刻意的：少一个分支就少一处能静默画错的地方。
import SwiftUI

// MARK: - 路径解析

/// 把归一化后的 SVG path（只含 M/L/C/Z，绝对坐标）解析成 CGPath 上的绘制指令。
/// 解析失败（遇到不认识的命令、数字不够）时**丢掉该段并继续**，而不是整条路径返回空：
/// 图标少一笔还能看出是什么，整个消失就只是一块空白 —— 后者更难定位。
struct UmbraSVGPath {

    static func path(from d: String, in rect: CGRect, viewBox: CGFloat = 24) -> Path {
        let sx = rect.width / viewBox
        let sy = rect.height / viewBox
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()
        var i = d.startIndex
        var nums: [CGFloat] = []

        // 逐字符扫：命令字母之间的所有数字先攒起来，遇到下一个命令再消费。
        var cmd: Character? = nil

        func flush() {
            guard let c = cmd else { nums.removeAll(); return }
            switch c {
            case "M":
                if nums.count >= 2 { path.move(to: pt(nums[0], nums[1])) }
                // SVG 允许 M 后面跟多组坐标，第二组起视作 L
                var k = 2
                while k + 1 < nums.count { path.addLine(to: pt(nums[k], nums[k + 1])); k += 2 }
            case "L":
                var k = 0
                while k + 1 < nums.count { path.addLine(to: pt(nums[k], nums[k + 1])); k += 2 }
            case "C":
                var k = 0
                while k + 5 < nums.count {
                    path.addCurve(to: pt(nums[k + 4], nums[k + 5]),
                                  control1: pt(nums[k], nums[k + 1]),
                                  control2: pt(nums[k + 2], nums[k + 3]))
                    k += 6
                }
            case "Z":
                path.closeSubpath()
            default:
                break   // 归一化之后不该出现；出现了就跳过这一段
            }
            nums.removeAll()
        }

        while i < d.endIndex {
            let ch = d[i]
            if ch == "M" || ch == "L" || ch == "C" || ch == "Z" {
                flush()
                cmd = ch
                i = d.index(after: i)
            } else if ch == "-" || ch == "." || ch.isNumber {
                // 抠一个数字：允许前导负号、一个小数点、以及 1e-3 这种指数形式
                var j = i
                if d[j] == "-" { j = d.index(after: j) }
                var dot = false, exp = false
                while j < d.endIndex {
                    let c = d[j]
                    if c.isNumber { j = d.index(after: j) }
                    else if c == "." && !dot && !exp { dot = true; j = d.index(after: j) }
                    else if (c == "e" || c == "E") && !exp {
                        exp = true; j = d.index(after: j)
                        if j < d.endIndex && (d[j] == "-" || d[j] == "+") { j = d.index(after: j) }
                    } else { break }
                }
                if let v = Double(d[i..<j]) { nums.append(CGFloat(v)) }
                i = j
            } else {
                i = d.index(after: i)   // 空格、逗号
            }
        }
        flush()
        return path
    }
}

// MARK: - 图标视图

/// 图标形状。做成 Shape 而不是 Canvas 是有原因的：
/// Canvas 里要显式指定 Shading，拿不到外层的 .foregroundColor —— 只能靠 .primary 去猜，
/// 而 .primary 在 Canvas 里未必解析成调用方设的前景色。Shape 的 .stroke() 天然吃当前前景样式，
/// 所以 `UmbraIcon(...).foregroundColor(UmbraColor.faint)` 这种最常见的写法一定生效。
struct UmbraIconShape: Shape {
    let d: String
    func path(in rect: CGRect) -> Path {
        UmbraSVGPath.path(from: d, in: rect)
    }
}

/// 线性图标。描边宽度按 24 的 viewBox 等比缩放，所以 12px 和 26px 的观感一致 ——
/// 固定 lineWidth 会让小尺寸图标显得过粗，那是最容易被忽略的失真。
struct UmbraIcon: View {
    let d: String
    var size: CGFloat = 16
    /// 交接文档要求 1.8–2.2（按 24 viewBox 计）。默认 1.9，和主设计稿的 tab 栏一致。
    var strokeWidth: CGFloat = 1.9

    var body: some View {
        UmbraIconShape(d: d)
            .stroke(style: StrokeStyle(lineWidth: strokeWidth * size / 24,
                                       lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)   // 图标一律配文字，语义由文字承载
    }
}

/// 运行中状态用的匀速旋转图标（1s linear infinite）。
/// 单独成一个组件是因为「看起来在动的东西必须真的在动」是自查清单里的一条 ——
/// 写成 modifier 很容易在某个页面忘了加。
struct UmbraSpinningIcon: View {
    let d: String
    var size: CGFloat = 16
    var strokeWidth: CGFloat = 1.9
    @State private var turning = false

    var body: some View {
        UmbraIcon(d: d, size: size, strokeWidth: strokeWidth)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(UmbraMotion.spin, value: turning)
            .onAppear { turning = true }
    }
}

/// 圆角方块里的图标（记录行徽标 34、表单/详情头 44、48）。
/// bg / fg 由调用方给，因为同一个尺寸在不同语境下配色不同（选中态、语义色）。
struct UmbraIconBlock: View {
    let d: String
    var block: CGFloat = UmbraMetric.iconBlockMD
    var icon: CGFloat? = nil
    var bg: Color = UmbraColor.chip
    var fg: Color = UmbraColor.muted
    var corner: CGFloat? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: corner ?? (block >= 40 ? UmbraMetric.radiusCard : UmbraMetric.radiusControl),
                         style: .continuous)
            .fill(bg)
            .frame(width: block, height: block)
            .overlay(
                UmbraIcon(d: d, size: icon ?? block * 0.45)
                    .foregroundColor(fg)
            )
    }
}

/// 字标：橙色圆角方块 + 白色「U」。**没有正式 logo**，需要标志的位置一律用这个，
/// 不要自行绘制标志（交接文档明确要求）。
struct UmbraWordmark: View {
    var size: CGFloat = 26
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(UmbraColor.orange)
            .frame(width: size, height: size)
            .overlay(
                Text("U")
                    .font(UmbraFont.sans(size * 0.54, .w650))
                    .foregroundColor(.white)
            )
    }
}
