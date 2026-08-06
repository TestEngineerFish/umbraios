// 应用根视图。
//
// 只做一件事：建好整个 App 唯一的 ChatViewModel，然后把外壳挂上去。
// 浅深色由 UmbraiOSApp 的 .preferredColorScheme 统一决定（读「我 › 通用 › 外观」），
// 这里**不再自己同步一份 isDarkMode** —— 原来那段是喂给旧的 UmbraColors(isDark:) 的，
// 那套配色已经删了，同步过去也没人读。
import SwiftUI

struct RootView: View {
    @EnvironmentObject var languageManager: LanguageManager
    @StateObject private var viewModel = ChatViewModel()

    var body: some View {
        UmbraShell()
            .environmentObject(viewModel)
            // 小组件 / 灵动岛点进来的 umbra:// 深链，走通知同一条 UmbraDeepLink 管道。
            .onOpenURL { UmbraDeepLink.shared.handle($0) }
    }
}
