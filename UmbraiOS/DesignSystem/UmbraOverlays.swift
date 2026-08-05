// 浮层：底部选择器（多层）、确认弹窗、toast。
//
// v2 起的分工：
//   确认弹窗 → **系统 .alert**。规范增补的按钮角色表和系统 alert 的形态一致
//   （destructive 红、cancel 无色），没必要再自绘一份；系统的还自带动效与无障碍。
//   底部选择器 → **系统 .sheet** 装自家内容：玻璃底（.ultraThinMaterial）、
//   圆角 26、取消键独立胶囊 —— 都是规范增补 4.2 的取值。多层（「移动到分组」
//   一层进一层）在 sheet 内部换内容，头部出返回箭头。
//   toast → 仍自绘（系统没有 toast）：深色玻璃胶囊 rgba(21,17,14,.72) + blur。
//
// 简单的「≤6 项纯选择」按规范应该用锚定 popover（系统 Menu）—— 那要在**触发点**改，
// 属于各页面批次的活；这里的 sheet 只服务「带说明/带状态值的多动作」场景。
import SwiftUI

// MARK: - 底部选择器内容

struct UmbraSheetLayer: View {
    let sheet: UmbraSheet
    /// 多层时非首层显示返回箭头（回到上一层），首层不显示。
    var canBack: Bool
    var onBack: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 头部：标题 600/13，副标题 400/12
            HStack(alignment: .top, spacing: UmbraMetric.sp3) {
                if canBack {
                    Button(action: onBack) {
                        UmbraIcon(d: UmbraIconPath.chevronLeft, size: 15, strokeWidth: 2.2)
                            .foregroundColor(UmbraColor.orange)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: -4, y: -2)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(sheet.title)
                        .font(UmbraFont.sans(13, .w600))
                        .foregroundColor(UmbraColor.text)
                    if let sub = sheet.subtitle {
                        Text(sub)
                            .font(UmbraFont.sans(12, .w400))
                            .foregroundColor(UmbraColor.muted)
                            .lineSpacing(12 * 0.5)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.top, UmbraMetric.sp5)
            .padding(.bottom, UmbraMetric.sp4)

            // 项：最小高 52。玻璃底上不再画整片白卡，行与行之间用发丝线。
            ForEach(sheet.items) { item in
                Button {
                    onClose()
                    item.action()
                } label: {
                    HStack(spacing: 10) {
                        Text(item.label)
                            .font(UmbraFont.sans(16, .w400))
                            .foregroundColor(item.destructive ? UmbraColor.danger : UmbraColor.text)
                        Spacer(minLength: 0)
                        if let note = item.note {
                            Text(note)
                                .font(UmbraFont.sans(12.5, .w400))
                                .foregroundColor(UmbraColor.faint)
                        }
                        if item.checked {
                            UmbraIcon(d: UmbraIconPath.check, size: 18, strokeWidth: 2.4)
                                .foregroundColor(UmbraColor.orange)
                        }
                    }
                    .padding(.horizontal, UmbraMetric.pagePadX)
                    .padding(.vertical, 10)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) {
                    Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
                }
            }

            // 取消：独立胶囊（v2 按钮角色表：取消键玻璃底、text 色、600）。
            // **不用橙色** —— 取消不是要推销的动作。
            Button(action: onClose) {
                Text("取消")
                    .font(UmbraFont.sans(16, .w600))
                    .foregroundColor(UmbraColor.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Capsule().fill(UmbraColor.glassBg))
                    .overlay(Capsule().strokeBorder(UmbraColor.glassBrd, lineWidth: UmbraMetric.borderW))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.top, UmbraMetric.sp4)
            .padding(.bottom, UmbraMetric.sp3)
        }
    }
}

// MARK: - Toast
//
// v2：深色玻璃胶囊 rgba(21,17,14,.72) + blur，底部浮出。
// 字色仍是 onNavText（底永远是深的，字不跟主题变）。
struct UmbraToastView: View {
    let toast: UmbraToast
    var onUndo: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(toast.text)
                .font(UmbraFont.sans(13.5, .w400))
                .foregroundColor(UmbraColor.onNavText)
                .lineSpacing(13.5 * 0.45)
                .lineLimit(2)
            if let undo = toast.undo {
                Button {
                    onUndo?()
                    undo()
                } label: {
                    Text("撤销")
                        .font(UmbraFont.sans(13, .w600))
                        .foregroundColor(UmbraColor.onNavAccent)
                        .padding(.horizontal, UmbraMetric.sp4)
                        .frame(height: 30)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: UmbraMetric.borderW))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, UmbraMetric.sp6)
        .padding(.vertical, UmbraMetric.sp4)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Capsule().fill(UmbraColor.toastGlass))
        .environment(\.colorScheme, .dark)   // 深色底上材质按深色渲染，别在浅色主题下泛白
        .shadow(color: Color.black.opacity(0.28), radius: 12, x: 0, y: 8)
    }
}

// MARK: - 挂载器
//
// 把三种浮层套在页面外面。用一个 modifier 而不是各页自己写，
// 是为了保证形态与遮罩在全 App 一致 —— 这种东西一旦允许各页自行发挥就再也统一不回来。
struct UmbraOverlayHost: ViewModifier {
    @ObservedObject var router: UmbraRouter

    /// sheet 高度：头部 + 每项 52 + 取消胶囊。系统 detent 需要一个具体值 ——
    /// 给 .medium 的话矮内容会浮在半屏中间，下面一大截空玻璃。
    private var sheetHeight: CGFloat {
        guard let top = router.sheets.last else { return 200 }
        let header: CGFloat = top.subtitle == nil ? 52 : 72
        return header + CGFloat(top.items.count) * 52 + 84
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let t = router.toast {
                    UmbraToastView(toast: t) { router.toast = nil }
                        .padding(.horizontal, UmbraMetric.pagePadX)
                        // 根页要抬过系统 tab bar，子页（底栏已收起）贴底一点即可。
                        .padding(.bottom, router.canGoBack ? 40 : 100)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            // 底部选择器：系统 sheet + 玻璃底 + 圆角 26。多层在 sheet 内换内容。
            .sheet(isPresented: Binding(
                get: { !router.sheets.isEmpty },
                set: { if !$0 { router.closeSheets() } }
            )) {
                if let top = router.sheets.last {
                    UmbraSheetLayer(
                        sheet: top,
                        canBack: router.sheets.count > 1,
                        onBack: { router.popSheet() },
                        onClose: { router.closeSheets() }
                    )
                    .presentationDetents([.height(sheetHeight)])
                    .presentationCornerRadius(UmbraMetric.radiusSheet)
                    .presentationBackground(.ultraThinMaterial)
                    .presentationDragIndicator(.hidden)
                }
            }
            // 确认弹窗：系统 .alert。destructive 角色给红色 —— 这是全 App
            // 唯一允许出现红色最终动作的地方，规则不变、执行者换成系统。
            .alert(
                router.alert?.title ?? "",
                isPresented: Binding(
                    get: { router.alert != nil },
                    set: { if !$0 { router.alert = nil } }
                ),
                presenting: router.alert
            ) { a in
                Button(a.cancelLabel, role: .cancel) {}
                Button(a.confirmLabel, role: a.confirmDestructive ? .destructive : nil) {
                    a.onConfirm()
                }
            } message: { a in
                if !a.body.isEmpty { Text(a.body) }
            }
            .animation(UmbraMotion.tint, value: router.toast?.id)
    }
}

extension View {
    /// 挂上 sheet / alert / toast 三种浮层。整个 App 只在最外层挂一次。
    func umbraOverlays(_ router: UmbraRouter) -> some View {
        modifier(UmbraOverlayHost(router: router))
    }
}
