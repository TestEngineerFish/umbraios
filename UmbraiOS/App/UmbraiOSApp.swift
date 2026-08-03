import SwiftUI

@main
struct UmbraiOSApp: App {
    @ObservedObject private var languageManager = LanguageManager.shared

    /// 外观偏好。来源是「我 › 通用 › 外观」写的这个键（浅色 / 深色 / 跟随系统）。
    /// 原来读的是 AppState.isDarkMode —— 那是个布尔值，表达不了「跟随系统」，
    /// 于是深色模式永远是手动挡。现在跟随系统时传 nil，交给系统决定。
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
                .preferredColorScheme((UmbraAppearance(rawValue: appearance) ?? .system).colorScheme)
        }
    }
}
