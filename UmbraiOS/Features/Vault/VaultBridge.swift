// 两个「系统形态」页面：后台遮盖与锁屏通知形态。
//
// 保险箱本体的界面在 UmbraVaultViews.swift / UmbraVaultToolViews.swift（第 5 步已重建），
// 这个文件只留下不属于保险箱、但和它相关的两块。
import SwiftUI
import AuthenticationServices

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
    /// 系统里我们的填充扩展当前启没启用。nil = 还没查到。
    /// 这是真数据（ASCredentialIdentityStore 的状态），不是演示。
    @State private var providerEnabled: Bool? = nil

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

                // 真实启用状态 + 直达系统启用页。ASSettingsHelper 会打开
                // 「自动填充与密码」里**我们这个扩展**的启用面板，绕过列表 ——
                // 也是最好的注册诊断：跳得开 = 系统认识我们，跳不开 = 没注册上。
                HStack(spacing: 10) {
                    Text(providerEnabled == nil ? "启用状态查询中…"
                         : (providerEnabled == true ? "系统里已启用 Umbra 填充" : "还没在系统里启用"))
                        .font(UmbraFont.sans(12.5, .w560))
                        .foregroundColor(Color.white.opacity(0.85))
                    Spacer(minLength: 0)
                    Button {
                        Task { try? await ASSettingsHelper.openCredentialProviderAppSettings() }
                    } label: {
                        Text("去系统设置启用")
                            .font(UmbraFont.sans(12.5, .w600))
                            .foregroundColor(.white)
                            .padding(.horizontal, 13)
                            .frame(height: 32)
                            .background(Capsule().fill(UmbraColor.orange))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, UmbraMetric.sp4)

                panel
            }
        }
        .onAppear {
            ASCredentialIdentityStore.shared.getState { state in
                Task { @MainActor in providerEnabled = state.isEnabled }
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
