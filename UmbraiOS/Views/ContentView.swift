import SwiftUI

/// 应用根视图。
///
/// 现在有两套外壳并存：
///  · **UmbraShell**（新）—— 按设计交接包重建的自绘外壳：5 个 Tab、栈式导航、
///    统一的底部选择器 / 确认弹窗 / toast。页面内容按 README 的顺序在第 3–5 步逐个补齐。
///  · **旧的系统 TabView** —— 现有的 ChatView / TasksView / InspirationsView /
///    AbilitiesView / MeView，功能是通的。
///
/// 之所以留着开关而不是直接删掉旧的：新外壳的页面还没建完，
/// 期间如果需要用真实功能（比如联调服务端），把 useNewShell 改成 false 就能切回去。
/// **页面建完后请删掉这个开关和旧的 legacyShell**，两套外壳长期并存必然分叉。
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var languageManager: LanguageManager
    @StateObject private var viewModel = ChatViewModel()

    /// true = 新外壳（设计交接包），false = 旧的系统 TabView。
    private let useNewShell = true

    var body: some View {
        if useNewShell {
            UmbraShell()
                .environmentObject(viewModel)
        } else {
            legacyShell
        }
    }

    // MARK: - 旧外壳（过渡期保留）
    private var legacyShell: some View {
        // 依赖 localeRevision，确保切换语言后 Tab 文案刷新
        let _ = languageManager.localeRevision
        return TabView {
            ChatView(viewModel: viewModel)
                .tabItem {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text(L("tab.chat"))
                }

            TasksView()
                .tabItem {
                    Image(systemName: "list.bullet.clipboard")
                    Text(L("tab.tasks"))
                }

            InspirationsView()
                .tabItem {
                    Image(systemName: "lightbulb")
                    Text(L("tab.inspiration"))
                }

            AbilitiesView()
                .tabItem {
                    Image(systemName: "square.grid.2x2")
                    Text(L("tab.skills"))
                }

            MeView()
                .tabItem {
                    Image(systemName: "person.crop.circle")
                    Text(L("tab.me"))
                }
        }
        .tint(Color.umbraOrange)
        .environmentObject(viewModel)
    }
}
