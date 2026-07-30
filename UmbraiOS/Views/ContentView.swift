import SwiftUI

/// 应用根视图。
///
/// 五个 Tab 的页面都已经按设计交接包重建完（聊天 / 提醒 / 任务 / 灵感 / 我），
/// 所以**旧的系统 TabView 外壳（legacyShell）连同 useNewShell 开关已经删掉** ——
/// 两套外壳长期并存必然分叉，这是当初留开关时就写明的退出条件。
///
/// 旧的页面文件（ChatView / TasksView / InspirationsView / AbilitiesView / MeView）
/// 暂时还在工程里：ChatView 里的 LocateCard（电脑操作的箭头指位）还在被新对话页复用，
/// 等那块出了 iOS 设计稿、按新语言重做之后，这几个文件可以一起删。
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var languageManager: LanguageManager
    @StateObject private var viewModel = ChatViewModel()

    /// 实际生效的浅深色。设置页写的是 UmbraAppearance，这里读出来同步给 AppState.isDarkMode —— // 旧页面（保险箱）用的是 UmbraColors(isDark:)，需要这个布尔值。
    /// 只在这一处同步，避免两个地方各存一份「现在是不是深色」。
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        UmbraShell()
            .environmentObject(viewModel)
            .onAppear { syncDark() }
            .onChange(of: colorScheme) { _ in syncDark() }
    }

    private func syncDark() {
        let dark = colorScheme == .dark
        if appState.isDarkMode != dark { appState.isDarkMode = dark }
    }
}
