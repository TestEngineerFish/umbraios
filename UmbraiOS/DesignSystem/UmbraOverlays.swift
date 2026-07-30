// 浮层：底部选择器（多层）、确认弹窗、toast。
//
// 三个都自己画，不用系统的 .confirmationDialog / .alert / .sheet：
// 设计稿对它们的圆角、分隔线、字号字重、按钮排布都有具体取值，系统件改不到。
// 而且底部选择器要**多层**（「移动到分组」从一层进下一层，头部出现橙色返回箭头），
// 系统 sheet 表达不了这种层内前进。
//
// 遮罩一律 rgba(0,0,0,.34)。z 序按设计稿：sheet 80 < alert 90，toast 70 在两者之下 ——
// 所以这里的叠放顺序是 toast → sheet → alert，不要随手调换。
import SwiftUI

// MARK: - 底部选择器

struct UmbraSheetLayer: View {
    let sheet: UmbraSheet
    /// 多层时非首层显示返回箭头（回到上一层），首层不显示。
    var canBack: Bool
    var onBack: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 头部：12/16 内边距，标题 600/13，副标题 400/12/1.5
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
            .padding(.vertical, UmbraMetric.sp4)
            .overlay(alignment: .bottom) {
                Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
            }

            // 项：最小高 52，行间上描边
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

            // 取消：橙色 600/16。「取消」只用于关闭浮层 —— 中断任务要用「停止」。
            Button(action: onClose) {
                Text("取消")
                    .font(UmbraFont.sans(16, .w600))
                    .foregroundColor(UmbraColor.orange)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) {
                Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
            }
        }
        .background(UmbraColor.card)
        .clipShape(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous))
    }
}

// MARK: - 确认弹窗

struct UmbraAlertView: View {
    let alert: UmbraAlert
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(alert.title)
                    .font(UmbraFont.sans(16, .w600))
                    .foregroundColor(UmbraColor.text)
                    .multilineTextAlignment(.center)
                    .lineSpacing(16 * 0.4)
                if !alert.body.isEmpty {
                    Text(alert.body)
                        .font(UmbraFont.sans(13, .w400))
                        .foregroundColor(UmbraColor.muted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(13 * 0.55)
                }
            }
            .padding(.horizontal, UmbraMetric.sp6)
            .padding(.top, UmbraMetric.sp6)
            .padding(.bottom, UmbraMetric.sp5)

            // 两半按钮，中间一条竖发丝线
            HStack(spacing: 0) {
                Button(action: onCancel) {
                    Text(alert.cancelLabel)
                        .font(UmbraFont.sans(16, .w400))
                        .foregroundColor(UmbraColor.muted)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(UmbraColor.borderSoft).frame(width: UmbraMetric.borderW)
                }

                Button {
                    onCancel()
                    alert.onConfirm()
                } label: {
                    Text(alert.confirmLabel)
                        .font(UmbraFont.sans(16, .w600))
                        // 破坏性确认才用 --danger。**这是全 App 唯一允许出现红色最终动作的地方。**
                        .foregroundColor(alert.confirmDestructive ? UmbraColor.danger : UmbraColor.orange)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
            }
        }
        .background(UmbraColor.card)
        .clipShape(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous))
    }
}

// MARK: - Toast
//
// --nav 底 + #F5F2EC 字 + 菜单档阴影（0 8px 24px .28）。左右 16，贴底。
// 底部距离跟栈深走：在 Tab 根页要避开底栏（100），进了二级页没有底栏（40）。
struct UmbraToastView: View {
    let toast: UmbraToast
    var onUndo: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(toast.text)
                .font(UmbraFont.sans(13.5, .w400))
                .foregroundColor(UmbraColor.onNavText)
                .lineSpacing(13.5 * 0.45)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.25), lineWidth: UmbraMetric.borderW)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, UmbraMetric.sp5)
        .padding(.vertical, UmbraMetric.sp4)
        .background(
            RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous)
                .fill(UmbraColor.nav)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 12, x: 0, y: 8)
    }
}

// MARK: - 挂载器
//
// 把三种浮层套在页面外面。用一个 modifier 而不是各页自己写，
// 是为了保证 z 序与遮罩色在全 App 一致 —— 这种东西一旦允许各页自行发挥就再也统一不回来。
struct UmbraOverlayHost: ViewModifier {
    @ObservedObject var router: UmbraRouter

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                // toast：z 70，在 sheet / alert 之下
                if let t = router.toast {
                    UmbraToastView(toast: t) { router.toast = nil }
                        .padding(.horizontal, UmbraMetric.pagePadX)
                        .padding(.bottom, router.stack.count == 1 ? 100 : 40)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .overlay {
                // 底部选择器：z 80。只画最上面一层，下面的层保持在栈里等返回。
                if let top = router.sheets.last {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.34)
                            .ignoresSafeArea()
                            .onTapGesture { router.closeSheets() }
                        UmbraSheetLayer(
                            sheet: top,
                            canBack: router.sheets.count > 1,
                            onBack: { router.popSheet() },
                            onClose: { router.closeSheets() }
                        )
                        .padding(10)
                    }
                    .transition(.opacity)
                }
            }
            .overlay {
                // 确认弹窗：z 90，压在所有东西上面
                if let a = router.alert {
                    ZStack {
                        Color.black.opacity(0.34)
                            .ignoresSafeArea()
                            // 点遮罩关掉 = 取消。不执行 onConfirm。
                            .onTapGesture { router.alert = nil }
                        UmbraAlertView(alert: a) { router.alert = nil }
                            .padding(38)
                    }
                    .transition(.opacity)
                }
            }
            .animation(UmbraMotion.tint, value: router.sheets.count)
            .animation(UmbraMotion.tint, value: router.alert?.id)
            .animation(UmbraMotion.tint, value: router.toast?.id)
    }
}

extension View {
    /// 挂上 sheet / alert / toast 三种浮层。整个 App 只在最外层挂一次。
    func umbraOverlays(_ router: UmbraRouter) -> some View {
        modifier(UmbraOverlayHost(router: router))
    }
}
