// 应用外壳：系统 TabView（五个 Tab）+ 每个 Tab 一条系统 NavigationStack。
//
// v2 起转场、边缘返回、tab bar 全部交给系统 —— iOS 26 上系统自动给出
// Liquid Glass 的浮动胶囊 tab bar 与玻璃返回钮，老系统上是各版本的原生形态。
// 一期的自绘转场 / 自绘边缘手势 / UmbraTabBar 已删。
//
// 全部页面已在系统导航栏上（UmbraScreen + .navigationTitle/.toolbar），
// 迁移期的旧 UmbraPage 骨架与自绘导航件已删。
import SwiftUI

struct UmbraShell: View {
    @StateObject private var router = UmbraRouter()
    /// 任务 / 灵感的数据源挂在外壳上，而不是各页自己新建：
    /// 列表和详情共用同一份数据，各建各的会出现「详情里改了状态，退回列表还是旧的」。
    @StateObject private var tasks = TasksViewModel()
    @StateObject private var inspirations = InspirationsViewModel()
    /// 保险箱的数据源与会话（软锁 / 自动锁定 / Face ID）也挂在外壳上：
    /// 首页、详情、编辑、体检是独立路由，各建各的 store 会各解各的锁。
    @StateObject private var vault = VaultStore()
    @StateObject private var vaultSession = UmbraVaultSession()
    @EnvironmentObject private var chat: ChatViewModel

    @ObservedObject private var reminders = ReminderStore.shared
    @ObservedObject private var deepLink = UmbraDeepLink.shared
    @Environment(\.scenePhase) private var scenePhase

    /// 底栏角标，两个都是真实数据：
    ///   聊天 = 有新消息的**会话数**（服务端没给条数，不编）；
    ///   提醒 = 已过期 + 今天到点的待办数（「更远」的不该顶个红点催人）。
    private func badge(_ tab: UmbraTab) -> Int {
        switch tab {
        case .chat:
            return chat.unread.count
        case .reminder:
            return reminders.items.filter { !$0.done && ($0.group == "已过期" || $0.group == "今天") }.count
        default:
            return 0
        }
    }

    var body: some View {
        TabView(selection: router.tabSelection) {
            ForEach(UmbraTab.allCases, id: \.self) { tab in
                NavigationStack(path: router.pathBinding(tab)) {
                    UmbraRouteView(route: tab.root)
                        .navigationDestination(for: UmbraRoute.self) { route in
                            UmbraRouteView(route: route)
                        }
                }
                // 底栏只在 Tab 根页显示（设计稿的 showTabBar: stack.length===1）。
                // 挂在**栈外**、由 path 是否为空驱动，而不是在每个 destination 上
                // .toolbar(.hidden)：那种写法返回根页时 tab bar 要等转场完全结束
                // 才回来（实机 0.5~1s 的空档）。path 一清空这里立即翻回 .visible。
                // tab bar 背景不再强行 .hidden：内容能穿到 bar 底下之后，
                // 系统材质是「玻璃下透出内容」的正确形态，抹掉反而露馅。
                .toolbar((router.paths[tab] ?? []).isEmpty ? .visible : .hidden, for: .tabBar)
                .tabItem { Label(tab.label, systemImage: tab.sfSymbol) }
                .badge(badge(tab))
                .tag(tab)
            }
        }
        // ⚠️ 这里原来挂了 `.id("shell-<外观>")`，外观一变就把整棵 TabView 重建。
        // 但 UmbraiOSApp 已经在窗口级做了同一件事（overrideUserInterfaceStyle +
        // UIView.transition 交叉淡入，整棵 trait 树一起换，导航栏和 tab bar 都跟上）。
        // 两个修法叠在一起就会打架：SwiftUI 正在重建 tab bar 的同时，UIKit 那边
        // 盖着一张 0.25s 的旧快照在淡出 —— 于是 tab bar 时而慢半拍、时而画花，
        // 而且因为是时序竞争所以**非必现**（用户实测，深色下更容易撞上）。
        // 窗口级那条是完整的解法，这条重建是它之前的遗留，去掉。
        // 选中态用品牌橙。角标颜色是系统红，不另调 —— 那是系统层的东西。
        .tint(UmbraColor.orange)
        .background(UmbraColor.bg)
        .umbraOverlays(router)
        // 后台遮盖是**真功能**不是演示：切后台时系统会给当前屏幕截一张图放进多任务卡片，
        // 保险箱页面被截进去等于密码泄漏。只在保险箱子树里盖 —— 别的页面盖了纯属打扰。
        .overlay {
            if scenePhase != .active && router.current.isVaultSubtree && vaultSession.maskEnabled {
                UmbraMaskScreen()
            }
        }
        .environmentObject(router)
        .environmentObject(tasks)
        .environmentObject(inspirations)
        .environmentObject(vault)
        .environmentObject(vaultSession)
        // 通知里点开的那条提醒：切到提醒 Tab 再推详情，这样返回是回提醒列表而不是空栈。
        .onChange(of: deepLink.route) { route in
            guard let route else { return }
            deepLink.route = nil
            router.root(route.tab)
            if route != route.tab.root { router.go(route) }
        }
    }
}

// MARK: - 路由分发
//
// 一个 switch 把 route 映射到页面。根页与推入页共用这一份 ——
// NavigationStack 的 navigationDestination 也从这里取。
struct UmbraRouteView: View {
    let route: UmbraRoute

    var body: some View {
        switch route {

        // ── 聊天
        case .chatContacts:
            UmbraChatContactsView()
        case .chatThread(let conv):
            UmbraChatThreadView(conv: conv)

        // ── 提醒
        case .remList:
            UmbraReminderListView()
        case .remDetail(let id):
            UmbraReminderDetailView(id: id)
        case .remEdit(let id):
            UmbraReminderEditView(id: id)

        // ── 任务
        case .taskList:
            UmbraTaskListView()
        case .taskDetail(let id):
            UmbraTaskDetailView(id: id)

        // ── 灵感
        case .inspList:
            UmbraInspirationListView()
        case .inspDetail(let id):
            UmbraInspirationDetailView(id: id)
        case .inspEdit(let id):
            UmbraInspirationEditView(id: id)

        // ── 我
        case .meHome:
            UmbraMeHomeView()
        case .mePhrases:
            UmbraPhrasesView()
        case .mePhraseEdit(let id):
            UmbraPhraseEditView(id: id)
        case .meDevices:
            UmbraDevicesView()
        case .deviceDetail(let id):
            UmbraDeviceDetailView(id: id)
        case .meCaps:
            UmbraCapabilitiesView()
        case .meWorkspace:
            UmbraWorkspaceView()
        case .meProfile:
            UmbraProfileView()
        case .setConn:
            UmbraConnSettingsView()
        case .setNotify:
            UmbraNotifySettingsView()
        case .setGeneral:
            UmbraGeneralSettingsView()
        case .setAbout:
            UmbraAboutView()

        // ── 保险箱子树
        case .vaultHome:
            UmbraVaultHomeView()
        case .vaultCreate:
            UmbraVaultCreateView()
        case .vaultKey:
            UmbraVaultKeyView()
        case .vaultRecover:
            UmbraVaultRecoverView()
        case .vaultRecord(let id):
            UmbraVaultRecordView(id: id)
        case .vaultEdit(let id):
            UmbraVaultEditView(id: id)
        case .vaultGen:
            UmbraVaultGenView()
        case .vaultCheck:
            UmbraVaultCheckView()
        case .vaultGroups:
            UmbraVaultGroupsView()
        case .vaultProfiles:
            UmbraVaultProfilesView()
        case .vaultTrash:
            UmbraVaultTrashView()
        case .vaultImport:
            UmbraVaultImportView()
        case .vaultSettings:
            UmbraVaultSettingsView()
        case .vaultPwd:
            UmbraVaultPasswordView()
        case .vaultAutofill:
            UmbraAutoFillDemoView()
        }
    }
}


// MARK: - 编辑页也要能边缘右划返回
//
// SwiftUI 的 NavigationStack 在 .navigationBarBackButtonHidden(true) 时会连
// interactivePopGestureRecognizer 一起禁掉 —— 而编辑页只是想把左上角换成「取消」，
// 不是想没收右划。把手势的 delegate 接回来，栈深 > 1 时始终允许。
// 这是社区通行的补法；系统哪天原生放开了，删掉这段即可。
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
