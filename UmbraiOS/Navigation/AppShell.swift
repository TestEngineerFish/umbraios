// 应用外壳：系统 TabView（四个 Tab：聊天/提醒/工具/我）+ 每个 Tab 一条系统 NavigationStack。
//
// 底栏 = **真·系统 tab bar**（终稿②，2026-08-25）：iOS 26 液态玻璃浮动胶囊
// 和它的果冻选中动效是系统私有渲染 —— 自绘复刻过一版（matchedGeometry +
// 过冲弹簧），老板实机验收「手感不好」，整体退场。「推入页不留底栏」不再碰
// SwiftUI 的 toolbar 显隐首选项（占位卡死的雷区），改走 UIKit 官方 API ——
// 见下面 setSystemTabBarHidden 的注释。
//
// 全部页面已在系统导航栏上（UmbraScreen + .navigationTitle/.toolbar），
// 迁移期的旧 UmbraPage 骨架与自绘导航件已删。
import SwiftUI
import UIKit

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

    /// 底栏角标，全是真实数据，且只放**需要动手的数**（2026-09-02 稿）：
    ///   聊天 = 有新消息的**会话数**（服务端没给条数，不编）；
    ///   提醒 = 已逾期数 —— 一级 tab 上的数字要能让人立刻决定要不要点，
    ///          待办总数不是这种数，不上一级；
    ///   工具 = 失败的任务数（逾期提醒 09-02 起归提醒 tab，不再混算）。
    /// ⚠️ 口径区分：App 图标角标 / 小组件走 ReminderStore.pendingCount
    /// （已过期 + 今天到点，见 refreshBadge），那是「今天要看的」；
    /// 这里的 tab 角标只算逾期，是「已经拖过头的」。两个数用途不同，别合并。
    private func badge(_ tab: UmbraTab) -> Int {
        switch tab {
        case .chat:
            return chat.unread.count
        case .rem:
            return reminders.items.filter { !$0.done && $0.group == "已过期" }.count
        case .tool:
            return tasks.items.filter { UmbraStatus(taskStatus: $0.status) == .failed }.count
        case .me:
            return 0
        }
    }

    var body: some View {
        // 结构：TabView 在外，每个 Tab 一条自己的 NavigationStack ——
        // 根页原生大标题唯一可靠的形态（大小标题联动是「导航栏 ↔ 它正下方
        // 滚动视图」之间的系统机制；栈外置 / 栈套栈两条路都实机翻过车）。
        //
        // 底栏（终稿②）：**真·系统 tab bar** —— 液态玻璃胶囊的果冻选中动效
        // 是系统私有渲染，自绘那版（matchedGeometry + 弹簧）被老板实机否掉。
        // 「一级显示 / 推入隐藏」由下面 onChange 里的 setSystemTabBarHidden
        // 驱动（UIKit 官方 API，布局与安全区都由 UIKit 自己收）；SwiftUI 的
        // .toolbar 显隐首选项一根手指都不碰 —— 三种挂法都占位卡死过（禁区①）。
        // 根页内容也不再垫底部 spacer：系统 bar 自己管滚动内容的避让。
        TabView(selection: router.tabSelection) {
            ForEach(UmbraTab.allCases, id: \.self) { tab in
                NavigationStack(path: router.pathBinding(tab)) {
                    UmbraRouteView(route: tab.root)
                        .navigationDestination(for: UmbraRoute.self) { route in
                            UmbraRouteView(route: route)
                        }
                }
                // 标签与角标都交回系统渲染（badge(0) 自动不显示）。
                .tabItem { Label(tab.label, systemImage: tab.sfSymbol) }
                .badge(badge(tab))
                .tag(tab)
            }
        }
        // ⚠️ 这里原来挂了 `.id("shell-<外观>")`，外观一变就把整棵 TabView 重建。
        // 但 UmbraiOSApp 已经在窗口级做了同一件事（overrideUserInterfaceStyle +
        // UIView.transition 交叉淡入，整棵 trait 树一起换，导航栏和 tab bar 都跟上）。
        // 两个修法叠在一起就会打架，去掉重建，保留窗口级方案。
        // 选中态用品牌橙。
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
        // 推入藏底栏 / 回根现底栏。onChange 首帧不触发正好 —— 启动时本来就该显示。
        // 边缘右划返回时 path 在手势**完成**那刻才变，所以 bar 是「落定后滑回来」、
        // 不跟手指走 —— iOS 26 连 UIKit 原生路径的跟手回显都有毛病（论坛 805740），
        // 不在这上面较劲。
        .onChange(of: pushed) { hidden in
            UmbraShell.setSystemTabBarHidden(hidden)
        }
        // 通知里点开的那条提醒：切到目标 Tab 的根再推目标页。
        // （08-23~09-01 期间这里要给 remDetail 先垫一层 .remList —— 当时提醒列表
        //   不是根页，不垫就没有回列表的路。09-02 提醒提回一级 tab、列表就是根页，
        //   垫层随之删掉：返回天然是「详情 → 提醒列表」。）
        .onChange(of: deepLink.route) { route in
            guard let route else { return }
            deepLink.route = nil
            router.root(route.tab)
            postDeepLinkPush(route)
        }
    }

    /// 深链的最后一跳拆出来 —— onChange 闭包别叠太深。
    private func postDeepLinkPush(_ route: UmbraRoute) {
        if route != route.tab.root { router.go(route) }
    }

    /// 当前 Tab 是否在推入页里（栈深 > 0）。系统底栏的显隐跟着它走。
    private var pushed: Bool { !(router.paths[router.tab] ?? []).isEmpty }

    /// 「推入页不留底栏」的唯一合法通道（终稿②）。
    ///
    /// 为什么是它：SwiftUI 侧全部路子都实机翻过车 —— .toolbar 显隐三种挂法
    /// 占位卡死；hidesBottomBarWhenPushed 的 swizzle 因 NavigationStack 不走
    /// pushViewController 而空转（且该属性在 iOS 26 早期版本本身坏过，Apple
    /// 已认账 FB18543961）。Apple 工程师在开发者论坛（thread 789148 / 791287）
    /// 点名的替代品就是 UITabBarController.setTabBarHidden(_:animated:)：
    /// iOS 18+ 官方 API，藏的是「各平台各形态的 tab bar 本体」，布局与安全区
    /// 由 UIKit 自己收 —— SwiftUI 的 toolbar 首选项机制完全不掺和，
    /// 占位 bug 没有发生的那一层。
    ///
    /// iPhone 上 SwiftUI TabView 仍由 UITabBarController 托底，从窗口根往下
    /// 广搜就能拿到。万一哪个系统版本换了实现拿不到：打一行日志、什么都不做，
    /// 退化行为是「推入页底栏常驻」—— 恰好也是 iOS 26 系统 App 的惯例，
    /// 不会出现布局坏死。iOS 16/17 没有这个 API，同样退化为常驻。
    private static func setSystemTabBarHidden(_ hidden: Bool) {
        guard #available(iOS 18.0, *) else { return }
        guard let tbc = findTabBarController() else {
            print("Umbra 底栏：没找到 UITabBarController，推入页底栏保持系统默认（常驻）")
            return
        }
        if tbc.isTabBarHidden != hidden {
            tbc.setTabBarHidden(hidden, animated: true)
        }
    }

    /// 从各窗口的根控制器往下广搜 UITabBarController（含 presented 分支）。
    /// 不缓存引用 —— 控制器树就几十个节点，每次现搜比操心缓存失效省心。
    private static func findTabBarController() -> UITabBarController? {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for window in ws.windows {
                var queue: [UIViewController] = window.rootViewController.map { [$0] } ?? []
                while !queue.isEmpty {
                    let vc = queue.removeFirst()
                    if let tbc = vc as? UITabBarController { return tbc }
                    queue.append(contentsOf: vc.children)
                    if let presented = vc.presentedViewController { queue.append(presented) }
                }
            }
        }
        return nil
    }
}

// MARK: - （已退场）自绘浮动胶囊底栏
//
// 2026-08-25 一天之内走完一圈：系统 bar 显隐翻车 → 自绘 UmbraTabBar overlay
//（材质胶囊 + matchedGeometry 果冻仿制 + 过冲弹簧）→ 老板实机验收「手感不好」。
// 结论：液态玻璃的果冻选中动效是系统私有渲染，自绘只能形似不能神似 ——
// 底栏必须是真系统件，推入隐藏走 setSystemTabBarHidden（见 UmbraShell）。
// 别再把自绘底栏请回来。

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

        // ── 工具（Tab 3 根页）
        case .toolHome:
            UmbraToolHomeView()
        case .toolWidgets:
            UmbraWidgetsGuideView()

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
        case .moneyCat(let slug):
            UmbraMoneyCatDetailView(slug: slug)
        case .moneyRecur:
            UmbraMoneyRecurListView()
        case .moneyRecurEdit(let id):
            UmbraMoneyRecurEditView(id: id)
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

    // （曾在这里放过 hidesBottomBarWhenPushed 的 swizzle —— 实测无效：
    //   NavigationStack 不走 pushViewController 这条路，钩子空转，bar 照常显示。
    //   推入藏底栏的正解是 UmbraShell.setSystemTabBarHidden，见那里的注释。）
}
