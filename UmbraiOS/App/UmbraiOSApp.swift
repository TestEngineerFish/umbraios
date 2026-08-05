import SwiftUI
import UIKit

@main
struct UmbraiOSApp: App {
    @ObservedObject private var languageManager = LanguageManager.shared

    /// 外观偏好。来源是「我 › 通用 › 外观」写的这个键（浅色 / 深色 / 跟随系统）。
    /// 原来读的是 AppState.isDarkMode —— 那是个布尔值，表达不了「跟随系统」，
    /// 于是深色模式永远是手动挡。现在跟随系统时写 .unspecified，交给系统决定。
    @AppStorage("umbra.appearance") private var appearance = UmbraAppearance.system.rawValue

    init() {
        // 通知代理必须在 App 完全启动**之前**装好：用户点通知冷启动时，
        // 系统只在启动早期投递一次那条响应，装晚了就永远收不到。
        UmbraNotificationDelegate.shared.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(languageManager)
                .environment(\.locale, languageManager.locale)
                .id(languageManager.localeRevision)
                // 深浅色切换写到 **UIWindow** 上，而不是 .preferredColorScheme：
                // preferredColorScheme 只刷 SwiftUI 这层，UIKit 托管的导航栏
                // （当前页标题、返回钮）要退出重进才换色（用户实测点名）。
                // 改 window 的 overrideUserInterfaceStyle 是整棵 trait 树一起变，
                // 导航栏、tab bar 都立刻跟上。
                .onAppear { applyAppearance() }
                .onChange(of: appearance) { _ in applyAppearance() }
        }
    }

    /// 把外观偏好落到所有窗口上。跟随系统 = .unspecified，还给系统管。
    private func applyAppearance() {
        let style: UIUserInterfaceStyle
        switch UmbraAppearance(rawValue: appearance) ?? .system {
        case .light: style = .light
        case .dark: style = .dark
        case .system: style = .unspecified
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for window in ws.windows {
                // 包在 UIView.transition 里：交叉淡入会强制整个窗口按新 trait 重画一遍，
                // 导航栏的标题与返回钮才会**当场**换色 —— 只改 overrideUserInterfaceStyle
                // 的话，正停留的那根导航栏要等下次 push/pop 才重配色（实机复现）。
                // 顺带把根控制器也标一遍，杜绝个别子控制器不吃窗口级 trait 的情况。
                UIView.transition(with: window, duration: 0.25,
                                  options: .transitionCrossDissolve) {
                    window.overrideUserInterfaceStyle = style
                    window.rootViewController?.overrideUserInterfaceStyle = style
                }
            }
        }
    }
}
