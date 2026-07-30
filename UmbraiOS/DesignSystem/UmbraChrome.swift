// 应用外框：导航栏、底部 Tab 栏、页面骨架。
//
// 取值逐个抄自主设计稿的内联样式。**没有**照抄原型里的状态栏、灵动岛和 Home 指示条 ——
// 那三样是浏览器原型为了画出一台 iPhone 才自己绘制的，真机上它们是系统的东西，
// 自己再画一层会和系统的重叠。这是设计稿与生产实现必然分叉的一处，不是漏做。
import SwiftUI

// MARK: - 导航栏
//
// 高 44、左 4 右 8、底部 1px --border-soft、底色是半透明的页面色（毛玻璃）。
// 返回按钮带**上一页的名字**（「‹ 密码保险箱」），不是统一的「‹ 返回」——
// 这是设计稿的做法：用户在深栈里能一眼看出退回哪。
struct UmbraNavBar<Trailing: View>: View {
    var backLabel: String? = nil
    var title: String = ""
    var onBack: (() -> Void)? = nil
    /// 返回箭头。编辑类页面左上角是**纯文字「取消」**（不是返回上一页，是放弃这次编辑），
    /// 设计稿里那里没有箭头 —— 加了箭头会让人以为改的东西已经存下了。
    var backChevron: Bool = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
            // 左侧：返回或占位。占位宽度和右侧一致，标题才能真正居中。
            if let label = backLabel, let onBack {
                Button(action: onBack) {
                    HStack(spacing: 1) {
                        if backChevron {
                            UmbraIcon(d: UmbraIconPath.chevronLeft, size: 20, strokeWidth: 2.4)
                        }
                        Text(label).font(UmbraFont.sans(16, .w400))
                    }
                    .foregroundColor(UmbraColor.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 44 高的栏里，点击区靠 frame 撑满高度而不是加内边距（加了会顶开栏高）
                .frame(minWidth: UmbraMetric.tapMin, minHeight: UmbraMetric.tapMin, alignment: .leading)
            } else {
                Spacer().frame(width: 44)
            }

            Text(title)
                .font(UmbraFont.sectionTitle)     // 600 / 17
                .foregroundColor(UmbraColor.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)

            HStack(spacing: 2) { trailing() }
                .frame(minWidth: 44, minHeight: UmbraMetric.tapMin, alignment: .trailing)
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(height: UmbraMetric.tapMin)
        .background(UmbraColor.bg.opacity(0.86))
        .overlay(alignment: .bottom) {
            Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
        }
    }
}

extension UmbraNavBar where Trailing == EmptyView {
    init(backLabel: String? = nil, title: String = "", onBack: (() -> Void)? = nil, backChevron: Bool = true) {
        self.init(backLabel: backLabel, title: title, onBack: onBack,
                  backChevron: backChevron, trailing: { EmptyView() })
    }
}

/// 导航栏右侧的「⋯」。设计稿这里画的是三个**实心圆点**（`<circle fill>`），
/// 不是描边图标 —— 全 App 唯一一处填充图形。
struct UmbraNavDots: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(UmbraColor.orange).frame(width: 3.8, height: 3.8)
                }
            }
            .frame(width: UmbraMetric.tapMin, height: UmbraMetric.tapMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 导航栏右侧的纯文字动作（「编辑」「存下」「取消」）。橙色 16/400。
struct UmbraNavAction: View {
    let title: String
    var weight: UmbraFont.Weight = .w400
    /// 置灰：不可点时用 --faint，并且**必须**在页面上给出原因，不要只把它变灰。
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: { if enabled { action() } }) {
            Text(title)
                .font(UmbraFont.sans(16, weight))
                .foregroundColor(enabled ? UmbraColor.orange : UmbraColor.faint)
                .padding(.horizontal, 8)
                .frame(minWidth: UmbraMetric.tapMin, minHeight: UmbraMetric.tapMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// 导航栏右侧的图标动作（「⋯」「＋」「筛选」）。
struct UmbraNavIcon: View {
    let iconPath: String
    var size: CGFloat = 20
    var strokeWidth: CGFloat = 2.0
    var color: Color = UmbraColor.orange
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            UmbraIcon(d: iconPath, size: size, strokeWidth: strokeWidth)
                .foregroundColor(color)
                .frame(width: UmbraMetric.tapMin, height: UmbraMetric.tapMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 底部 Tab 栏
//
// 高 83、上内边距 6、上描边 1px --border、底色半透明页面色。
// 图标 26 / stroke 1.9，标签 10.5（选中 560、未选中 400），选中 --orange、未选中 --faint。
// 角标：17×17 起、橙底白字 600/11，压在图标右上（top -2、水平中线右移 6）。
//
// 不用系统 TabView：它的栏高、图标尺寸、角标位置和选中色都改不到设计值，
// 而 iOS 26 之后系统底栏的观感还在变，自绘反而更稳。
struct UmbraTabBar: View {
    @Binding var selection: UmbraTab
    /// tab → 角标数字。0 或缺省不显示。
    var badges: [UmbraTab: Int] = [:]
    var onSelect: (UmbraTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(UmbraTab.allCases, id: \.self) { t in
                let on = t == selection
                Button {
                    onSelect(t)
                } label: {
                    VStack(spacing: 3) {
                        UmbraIcon(d: t.iconPath, size: 26, strokeWidth: 1.9)
                            .overlay(alignment: .topTrailing) {
                                if let n = badges[t], n > 0 {
                                    Text("\(n)")
                                        .font(UmbraFont.sans(11, .w600))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 5)
                                        .frame(minWidth: 17, minHeight: 17)
                                        .background(Capsule().fill(UmbraColor.orange))
                                        .offset(x: 12, y: -2)
                                }
                            }
                        Text(t.label).font(UmbraFont.sans(10.5, on ? .w560 : .w400))
                    }
                    .foregroundColor(on ? UmbraColor.orange : UmbraColor.faint)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
        .frame(height: UmbraMetric.tabBarH, alignment: .top)
        .background(UmbraColor.bg.opacity(0.86))
        .overlay(alignment: .top) {
            Rectangle().fill(UmbraColor.border).frame(height: UmbraMetric.borderW)
        }
        .animation(UmbraMotion.tint, value: selection)
    }
}

// MARK: - 页面骨架
//
// 一页 = 顶部栏（可选）+ 可滚动内容 + 底部动作条（可选）。
// 滚动区左右不加边距 —— 由各页自己按 16 加，因为有些块（分段控件、卡片）
// 的左右边距和正文不一样，统一加会失去这个自由度。
struct UmbraPage<Content: View, Bar: View, Bottom: View>: View {
    @ViewBuilder var navBar: () -> Bar
    @ViewBuilder var content: () -> Content
    @ViewBuilder var bottom: () -> Bottom

    var body: some View {
        VStack(spacing: 0) {
            navBar()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, UmbraMetric.sp8)
            }
            .background(UmbraColor.bg)
            bottom()
        }
        .background(UmbraColor.bg)
    }
}

extension UmbraPage where Bottom == EmptyView {
    init(@ViewBuilder navBar: @escaping () -> Bar, @ViewBuilder content: @escaping () -> Content) {
        self.init(navBar: navBar, content: content, bottom: { EmptyView() })
    }
}

/// 大标题页（Tab 根页）：没有返回箭头，用 27/650 的页面标题。
struct UmbraTitleHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: UmbraMetric.sp3) {
            UmbraPageTitle(text: title, subtitle: subtitle)
            Spacer(minLength: UmbraMetric.sp2)
            trailing()
        }
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.top, UmbraMetric.sp2)
        .padding(.bottom, UmbraMetric.sp4)
    }
}

extension UmbraTitleHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

/// 大标题页右上角那个橙色圆形「＋」（提醒、灵感列表用）。直径 34。
struct UmbraRoundPlusButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Circle()
                .fill(UmbraColor.orange)
                .frame(width: 34, height: 34)
                .overlay(
                    UmbraIcon(d: UmbraIconPath.plus, size: 18, strokeWidth: 2.4)
                        .foregroundColor(.white)
                )
                // 34 够不到 44：靠透明外框把点击区撑到触达底线，而不是把按钮画大。
                .frame(width: UmbraMetric.tapMin, height: UmbraMetric.tapMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
