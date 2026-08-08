// 应用外框：v2 起导航栏与 tab bar 全部交给系统，这里只剩页面骨架 UmbraScreen。
// 自绘的玻璃导航按钮也删了 —— 系统工具栏在 iOS 26 上自带玻璃形态，
// 再叠一层自绘玻璃就是「按钮下面好几层背景」（用户实测点名）。
// 一期的自绘 UmbraNavBar / UmbraNavDots / UmbraNavAction / UmbraNavIcon / UmbraTabBar
// 已随全部页面迁到系统导航后删除。
import SwiftUI
import UIKit

// MARK: - 键盘

/// 主动收起键盘。
///
/// SwiftUI 到 iOS 17 也没给一个「不持有 FocusState 就能收键盘」的口子，
/// 而表单里每个输入框各挂一个 @FocusState 是明显的过度设计 ——
/// 直接让当前第一响应者辞职是这件事最省的写法。
enum UmbraKeyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

// MARK: - v2 页面骨架（系统导航栏版）
//
// v2 的页面容器：只管「可滚动内容 + 底部动作条 + 页面底色 + 键盘行为」，
// 标题与导航按钮交给系统（.navigationTitle / .toolbar 由页面自己挂）。
// 大标题 34/700、上滑小标题渐显、玻璃栏背景都是系统 bar 的默认行为，不再自绘。
struct UmbraScreen<Content: View, Bottom: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var bottom: () -> Bottom

    var body: some View {
        Group {
            // 没有底部动作条时 ScrollView 必须自己当根视图：包在 VStack 里会让它的
            // 边界停在安全区上沿（= tab bar 顶），内容滚到底就被裁掉、穿不到 tab bar
            // 底下（实机复现：列表底只到 tab bar 顶）。只有真的带底栏才包 VStack。
            if Bottom.self == EmptyView.self {
                scroll
            } else {
                VStack(spacing: 0) {
                    scroll
                    bottom()
                }
            }
        }
        .background(UmbraColor.bg)
        // 玻璃栏：滚动到顶时透明、有内容滚过时系统自动上材质 —— 无分隔线，靠分层。
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
    }

    private var scroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, UmbraMetric.sp8)
                // 点空白处收键盘。原来只有「往下拖」这一条路，而键盘一旦弹出来
                // 就把保存按钮顶到屏幕外，用户想收起来只能连蒙带猜（点名反馈）。
                // 放在内容层而不是 ScrollView 上：子控件（输入框、按钮、滚轮行）
                // 仍然优先吃自己的点击，只有落在空白处的那一下才会走到这里。
                .contentShape(Rectangle())
                .onTapGesture { UmbraKeyboard.dismiss() }
        }
        // 往下拖就收键盘。iOS 上这是所有带输入框的滚动页面的默认预期。
        .scrollDismissesKeyboard(.interactively)
    }
}

extension UmbraScreen where Bottom == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content) {
        self.init(content: content, bottom: { EmptyView() })
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
