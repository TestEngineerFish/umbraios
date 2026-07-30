// 两个「系统形态」页面：后台遮盖与锁屏通知形态。
//
// 保险箱本体的界面在 UmbraVaultViews.swift / UmbraVaultToolViews.swift（第 5 步已重建），
// 这个文件只留下不属于保险箱、但和它相关的两块。
import SwiftUI

// MARK: - 后台遮盖（MaskScreen）
//
// 这不是演示：切到后台 / 进入多任务卡片时，屏幕内容会被系统截图留在任务切换器里。
// 保险箱页面被截进去就等于密码泄漏，所以**真的要盖住**。
// 规范：--bg 底 + 52px 橙色字标「U」+ 一行说明。
struct UmbraMaskScreen: View {
    var body: some View {
        ZStack {
            UmbraColor.bg.ignoresSafeArea()
            VStack(spacing: UmbraMetric.sp5) {
                UmbraWordmark(size: 52)
                Text("切回 Umbra 继续")
                    .font(UmbraFont.sans(13, .w400))
                    .foregroundColor(UmbraColor.muted)
            }
        }
    }
}

// MARK: - 锁屏通知形态
//
// 展示 iOS 推送长什么样：深色玻璃卡 + 两个动作按钮。
// 这一页是**形态展示**，不是功能页 —— 真正的推送由系统渲染，App 决定不了它的样子。
// 所以它只从「我 › 关于」这类地方作为示意进入，不参与正常流程。
struct UmbraLockScreenDemo: View {
    @EnvironmentObject private var router: UmbraRouter

    var body: some View {
        ZStack {
            Color(red: 14 / 255, green: 12 / 255, blue: 10 / 255).ignoresSafeArea()
            VStack(spacing: UmbraMetric.sp6) {
                Spacer()
                Text("9:41")
                    .font(UmbraFont.sans(64, .w400))
                    .foregroundColor(.white)
                Text("7月30日 星期四")
                    .font(UmbraFont.sans(15, .w400))
                    .foregroundColor(Color.white.opacity(0.6))

                card
                    .padding(.horizontal, UmbraMetric.pagePadX)
                    .padding(.top, UmbraMetric.sp8)

                Spacer()
                Button { router.back() } label: {
                    Text("退出这个演示")
                        .font(UmbraFont.sans(14, .w560))
                        .foregroundColor(Color.white.opacity(0.7))
                        .frame(minHeight: UmbraMetric.tapMin)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, UmbraMetric.sp7)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: UmbraMetric.sp3) {
                UmbraWordmark(size: 20)
                Text("Umbra")
                    .font(UmbraFont.sans(12.5, .w560))
                    .foregroundColor(Color.white.opacity(0.7))
                Spacer(minLength: 0)
                Text("现在")
                    .font(UmbraFont.sans(12.5, .w400))
                    .foregroundColor(Color.white.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 4) {
                Text("需要执行前确认")
                    .font(UmbraFont.sans(15, .w600))
                    .foregroundColor(.white)
                Text("在「我的 MacBook Pro」上删除 3 个文件")
                    .font(UmbraFont.sans(14, .w400))
                    .foregroundColor(Color.white.opacity(0.8))
                    .lineSpacing(14 * 0.4)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            HStack(spacing: 0) {
                action("去确认")
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 44)
                action("稍后")
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func action(_ label: String) -> some View {
        Button { router.back() } label: {
            Text(label)
                .font(UmbraFont.sans(15, .w560))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


// MARK: - 系统密码填充面板（形态展示）
//
// 这一页**不是**真的填充面板 —— 真的那个由系统在别的 App 里唤起，运行在
// AutoFill Credential Provider 扩展里（见 AutoFillExtension/，接入步骤在
// doc/iOS-AutoFill-扩展接入步骤.md）。这里只把它长什么样、有多高、
// 锁定态什么文案摆出来，供评审对照 —— 面板高度受限，行高与字号都比 App 内紧凑。
struct UmbraAutoFillDemoView: View {
    @EnvironmentObject private var router: UmbraRouter
    @State private var unlocked = false
    @State private var query = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(red: 12 / 255, green: 10 / 255, blue: 9 / 255).opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { router.back() }

            VStack(spacing: 0) {
                Text("系统密码填充面板 · 高度受限，行高与字号更紧凑")
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(Color.white.opacity(0.7))
                    .lineSpacing(12 * 0.6)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, UmbraMetric.sp5)

                panel
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                UmbraWordmark(size: 24)
                Text("Umbra · 密码填充")
                    .font(UmbraFont.sans(15, .w600))
                    .foregroundColor(UmbraColor.text)
                Spacer(minLength: 0)
                Button { router.back() } label: {
                    Text("关闭")
                        .font(UmbraFont.sans(15, .w400))
                        .foregroundColor(UmbraColor.orange)
                        .frame(minHeight: UmbraMetric.tapMin)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.vertical, UmbraMetric.sp4)
            .overlay(alignment: .bottom) {
                Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
            }

            if unlocked { list } else { lockedPane }
        }
        .frame(maxHeight: 520)
        .background(
            UnevenRoundedCornersShape(radius: 18).fill(UmbraColor.bg)
        )
    }

    private var lockedPane: some View {
        VStack(spacing: 13) {
            UmbraIcon(d: UmbraIconPath.faceId, size: 44, strokeWidth: 1.4)
                .foregroundColor(UmbraColor.orange)
            Text("解锁后才能填充。Face ID 通过即可，不用打开 Umbra。")
                .font(UmbraFont.sans(13, .w400))
                .foregroundColor(UmbraColor.muted)
                .lineSpacing(13 * 0.6)
                .multilineTextAlignment(.center)
            UmbraButton(title: "用 Face ID 解锁", kind: .primary, height: UmbraMetric.tapMin) {
                unlocked = true
            }
            .frame(maxWidth: 180)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
    }

    /// 演示用的三行。**故意不接真数据** —— 这一页是形态说明，
    /// 真列表在扩展里跑；在 App 内把真密码列出来只会让人以为填充已经能用了。
    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            UmbraSearchField(placeholder: "搜 github.com", text: $query)

            UmbraSectionLabel(text: "当前网站的匹配项")

            VStack(spacing: 0) {
                ForEach(Array(["GitHub", "Gmail", "微博"].enumerated()), id: \.offset) { idx, name in
                    if idx > 0 { UmbraRowDivider() }
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(UmbraColor.chip)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Text(String(name.prefix(1)))
                                    .font(UmbraFont.sans(13, .w600))
                                    .foregroundColor(UmbraColor.muted)
                            )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name).font(UmbraFont.sans(14, .w560)).foregroundColor(UmbraColor.text)
                            Text("（示意，不是真数据）")
                                .font(UmbraFont.mono(12))
                                .foregroundColor(UmbraColor.faint)
                        }
                        Spacer(minLength: 0)
                        Text("填充")
                            .font(UmbraFont.sans(12.5, .w560))
                            .foregroundColor(UmbraColor.orange)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(minHeight: 52)
                }
            }
            .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous).fill(UmbraColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous)
                    .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
            )
        }
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.top, UmbraMetric.sp4)
        .padding(.bottom, UmbraMetric.sp6)
    }
}
