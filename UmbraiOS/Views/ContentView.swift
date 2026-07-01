import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()

    var body: some View {
        TabView {
            ChatView(viewModel: viewModel)
                .tabItem {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("聊天")
                }

            TasksView()
                .tabItem {
                    Image(systemName: "list.bullet.clipboard")
                    Text("任务")
                }

            AbilitiesView()
                .tabItem {
                    Image(systemName: "square.grid.2x2")
                    Text("能力")
                }

            MeView()
                .tabItem {
                    Image(systemName: "person.crop.circle")
                    Text("我的")
                }
        }
        .tint(Color.umbraOrange)
        .environmentObject(viewModel)
    }
}
