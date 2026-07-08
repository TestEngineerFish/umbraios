import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var languageManager: LanguageManager
    @StateObject private var viewModel = ChatViewModel()

    var body: some View {
        // 依赖 localeRevision，确保切换语言后 Tab 文案刷新
        let _ = languageManager.localeRevision
        TabView {
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
