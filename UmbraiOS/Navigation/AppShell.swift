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
    /// 记账的数据源也挂外壳：统计 / 流水 / 记一笔 / 分类管理是独立路由，
    /// 各建各的会各拉各的数据，统计页点分类跳流水也要靠它带筛选。
    @StateObject private var money = MoneyStore()
    @EnvironmentObject private var chat: ChatViewModel

    @ObservedObject private var reminders = ReminderStore.shared
    @ObservedObject private var deepLink = UmbraDeepLink.shared
    @Environment(\.scenePhase) private var scenePhase

    /// 底栏角标，两个都是真实数据：
    ///   聊天 = 有新消息的**会话数**（服务端没给条数，不编）；
    ///   工具 = 已逾期的提醒 + 待确认的任务（稿原话：一级 tab 上的数字要能让人
    ///   立刻决定要不要点 —— 「今天晚些时候」的提醒不该顶个红点催人）。
    private func badge(_ tab: UmbraTab) -> Int {
        switch tab {
        case .chat:
            return chat.unread.count
        case .tool:
            let overdue = reminders.items.filter { !$0.done && $0.group == "已过期" }.count
            let attn = tasks.jobs.filter { UmbraStatus(jobStatus: $0.status) == .awaitingReview }.count
            return overdue + attn
        case .me:
            return 0
        }
    }

    var body: some View {
        // 栈挂在 TabView **外面**：推入页盖住整个 TabView（含 tab bar），
        // 它的布局里根本没有 bar 的安全区 —— 「二级页底部一条 tab bar 高的死带」
        // 这类问题从结构上消灭。
        //
        // 为什么不再用 .toolbar(.hidden, for: .tabBar)：栈在 TabView 里面时，
        // 首个推入层是「从显示着 bar 的页面推入」的，系统按有 bar 布局、bar 藏掉后
        // inset 不回收 —— 于是二级页缺一条底、三级页反而正常（从无 bar 的页面起推，
        // 用户实测钉死的现场）。该 API 的三种挂法（只挂栈外 / 内外都挂 / 只挂
        // destination）连续三轮验收全部失败，禁止再引入，见 CLAUDE.md「页面骨架」。
        //
        NavigationStack(path: router.pathBinding) {
            TabView(selection: router.tabSelection) {
                ForEach(UmbraTab.allCases, id: \.self) { tab in
                    // 每个根页配一条**永不推入的内层栈**，只干一件事：给根页一条
                    // 属于自己的导航栏。原生的大标题联动（上滑收成小标题）是
                    // 「导航栏 ↔ 它正下方的滚动视图」之间的机制 —— 大标题挂在外层
                    // 栈上时隔着一整个 TabView，系统挂不上去：标题上方多出一截空、
                    // 收放也不是系统手感（用户实测截图）。内层栈 + 根页内容
                    // 就是改造前那个像素级正确的形态，原样保留；推入一律走外层栈，
                    // 内层栈的 path 永远为空（router.go 只改外层 path）。
                    //
                    // tab bar 背景不强行 .hidden：内容能穿到 bar 底下之后，
                    // 系统材质是「玻璃下透出内容」的正确形态，抹掉反而露馅。
                    NavigationStack {
                        UmbraRouteView(route: tab.root)
                    }
                    .tabItem { Label(tab.label, systemImage: tab.sfSymbol) }
                    .badge(badge(tab))
                    .tag(tab)
                }
            }
            // 外层栈的导航栏在根页**隐藏** —— 根页的栏由上面的内层栈提供，
            // 两条都显示就是双栏。navigationTitle 仍要给：栏虽然藏着，
            // 推入页返回按钮的文字取的是它（「< 工具」而不是「< 返回」）。
            .navigationTitle(router.tab.label)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UmbraRoute.self) { route in
                UmbraRouteView(route: route)
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
        .environmentObject(money)
        // 通知里点开的那条提醒：切到工具 Tab、先垫上提醒列表再推详情 ——
        // 这样返回是「详情 → 提醒列表 → 工具页」，而不是从详情一步掉回工具页
        // （tab 减到三个之后提醒列表不再是根页，不垫这一层就没有回列表的路）。
        .onChange(of: deepLink.route) { route in
            guard let route else { return }
            deepLink.route = nil
            router.root(route.tab)
            switch route {
            case .remDetail, .remEdit:
                router.go(.remList)
            default:
                break
            }
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

        // ── 工具（Tab 2 根页）
        case .toolHome:
            UmbraToolHomeView()

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
        case .moneyHome:
            UmbraMoneyHomeView()
        case .moneyList:
            UmbraMoneyListView()
        case .moneyAdd(let id):
            UmbraMoneyAddView(id: id)
        case .moneyCats:
            UmbraMoneyCatsView()
        case .deviceDetail(let id):
            UmbraDeviceDetailView(id: id)
        case .meCaps:
            UmbraCapabilitiesView()
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
