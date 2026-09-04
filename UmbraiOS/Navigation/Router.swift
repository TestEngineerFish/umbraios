// Umbra 导航与瞬时 UI 的唯一状态源。
//
// v2 起改用系统 NavigationStack + TabView（一期是自绘栈，理由是当时的设计稿要求
// 带标题的返回按钮与自管转场；v2 交接清单明确改成「直接用系统 push/pop 与
// interactivePopGestureRecognizer」，自绘的那套随之整个退场）。
//
// Router 对页面暴露的 API 不变：go / back / root / present / confirm / showToast ——
// 页面代码不用知道底下是自绘栈还是 NavigationStack。变的只是实现：
// 每个 Tab 一条 [UmbraRoute] 路径，交给各自的 NavigationStack(path:) 渲染，
// 转场、边缘返回、大标题渐显全部由系统负责。
import SwiftUI

// MARK: - 路由
//
// 每个 case 对应设计稿里的一个 route.s。带参数的页面把参数放进 case ——
// 比原型的 [String: Any] 强，编译期就能发现「进详情页忘了传 id」。
enum UmbraRoute: Hashable {
    // Tab 1 聊天
    case chatContacts
    case chatThread(conv: String)
    // Tab 2 提醒（2026-09-02 稿：提醒提回一级 tab —— 一天要看好几次，
    // 藏在工具页里每次都多点一下；任务留在工具页，两者不再并列，
    // 任务是「交给电脑去做」，提醒是「到点叫我」）
    case remList
    case remDetail(id: String)
    case remEdit(id: String?)          // nil = 新建
    // Tab 3 工具（2026-08-23 稿收编任务/灵感/记账/保险箱；提醒 09-02 提走）
    case toolHome
    /// 小组件与轻点背面的说明页（稿 widgets）。入口在工具页「输入辅助」组。
    case toolWidgets
    case taskList
    case taskDetail(id: String)
    case inspList
    case inspDetail(id: String)
    case inspEdit(id: String?)
    // 记账（一期：统计 / 流水 / 记一笔 / 分类管理；入口在工具页的大卡）
    case moneyHome
    case moneyList
    case moneyAdd(id: String?)         // nil = 新建，非 nil = 编辑这一条
    case moneyCats
    /// 单个分类（money.cat）：子类的看 / 加 / 改名 / 删（第二批）。
    case moneyCat(slug: String)
    // 周期记账（二期）：规则列表 + 编辑（nil = 新建）
    case moneyRecur
    case moneyRecurEdit(id: String?)
    // Tab 3 我
    case meHome
    case mePhrases
    /// 常用语的新建/编辑页（nil = 新建）。设计稿 phrase.edit —— 独立推入页，不是弹窗。
    case mePhraseEdit(id: String?)
    case meDevices
    case deviceDetail(id: String)
    case meCaps
    // meWorkspace 已删：工作区 2026-08-22 起在 iOS 下线（稿原文「整屏移除，PC 端保留」）。
    case meProfile
    case setConn
    case setNotify
    case setGeneral
    case setAbout
    // 密码保险箱子树
    case vaultHome
    case vaultCreate
    case vaultKey
    case vaultRecover
    case vaultRecord(id: String)
    case vaultEdit(id: String?)
    case vaultGen
    case vaultCheck
    case vaultGroups
    case vaultProfiles
    case vaultTrash
    case vaultImport
    case vaultSettings
    case vaultPwd
    /// 系统密码填充面板的形态说明页（真填充在 AutoFill 扩展里）。
    /// 一期还有 lockScreen / vaultMask 两个演示路由，早已没有任何入口，v2 清掉。
    case vaultAutofill

    /// 这一页属于哪个 Tab。深链跳转时用来对齐底栏。
    /// 记账 / 保险箱的入口在工具页，所以归 tool；只有回收站例外 ——
    /// 它的正门在「我 › 设置」（vault 前缀只是历史沿用，两区通用）。
    var tab: UmbraTab {
        switch self {
        case .chatContacts, .chatThread:
            return .chat
        case .remList, .remDetail, .remEdit:
            return .rem
        case .toolHome, .toolWidgets,
             .taskList, .taskDetail,
             .inspList, .inspDetail, .inspEdit,
             .moneyHome, .moneyList, .moneyAdd, .moneyCats,
             .moneyCat, .moneyRecur, .moneyRecurEdit:
            return .tool
        case .vaultTrash:
            return .me
        case _ where isVaultSubtree:
            return .tool
        default:
            return .me
        }
    }

    /// 是不是保险箱子树。切后台时只有这些页面要盖住（见 UmbraShell 的遮盖层）。
    var isVaultSubtree: Bool {
        switch self {
        case .vaultHome, .vaultCreate, .vaultKey, .vaultRecover, .vaultRecord, .vaultEdit,
             .vaultGen, .vaultCheck, .vaultGroups, .vaultProfiles, .vaultTrash,
             .vaultImport, .vaultSettings, .vaultPwd, .vaultAutofill:
            return true
        default:
            return false
        }
    }
}

// MARK: - Tab
//
// 顺序按主设计稿的 tabsVM()：聊天 / 提醒 / 工具 / 我。
// 2026-08-23 稿把 tab 从五个减到三个（任务/提醒并列分不清该点哪个，一起收进工具页）；
// 2026-09-02 稿把**提醒**单独提回一级 —— 进 tab 的门槛是「一天要看好几次」，
// 提醒符合，任务不符合（任务是「交给电脑去做」，提醒是「到点叫我」，不再并列）。
// 上了一级 tab 的功能不在工具页重复出现：一个入口只有一个位置。
enum UmbraTab: String, CaseIterable, Hashable {
    case chat, rem, tool, me

    var label: String {
        switch self {
        case .chat: return "聊天"
        case .rem: return "提醒"
        case .tool: return "工具"
        case .me: return "我"
        }
    }
    /// v2：tab bar 交给系统 TabView，图标用 SF Symbols ——
    /// 系统符号才吃得到 tab bar 的选中态渲染（iOS 26 上还有玻璃胶囊与动效）。
    /// 自绘 SVG 路径图标只在内容区继续用。稿的工具图标是个工具箱，
    /// SF 里语义最近且 iOS 16 一定有的是扳手螺丝刀；提醒沿用铃铛。
    var sfSymbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .rem: return "bell"
        case .tool: return "wrench.and.screwdriver"
        case .me: return "person.crop.circle"
        }
    }
    var root: UmbraRoute {
        switch self {
        case .chat: return .chatContacts
        case .rem: return .remList
        case .tool: return .toolHome
        case .me: return .meHome
        }
    }
}

// MARK: - 瞬时 UI

/// 底部选择器的一项。
struct UmbraSheetItem: Identifiable {
    let id = UUID()
    let label: String
    /// 右侧对勾（当前选中项）。
    var checked: Bool = false
    /// 右侧灰色小字说明。
    var note: String? = nil
    /// 破坏性项用 --danger 字色；实心红只留给确认弹窗。
    var destructive: Bool = false
    var action: () -> Void = {}
}

/// 底部选择器里的一格图标（批次 006「换图标」这类**挑形状**的场景）。
/// 独立于 UmbraSheetItem：图标格是网格排布、选中态是描边不是对勾，硬塞进行模型
/// 只会让两边都变形。选中即收 sheet（挑完就是完成，不需要再点取消）。
struct UmbraSheetIcon: Identifiable {
    let id = UUID()
    /// UmbraIcon 的 path（M/L/C/Z 绝对方言）。
    let d: String
    /// 当前生效的那一格：橙描边 + 橙底。
    var on: Bool = false
    var action: () -> Void = {}
}

/// 一层底部选择器。**支持多层**（设计稿里「移动到分组」会从一层进到下一层），
/// 所以 UmbraRouter 里存的是数组而不是单个值。
struct UmbraSheet: Identifiable {
    let id = UUID()
    let title: String
    var subtitle: String? = nil
    /// 图标网格（可空）。有值时渲染在 items 之前 —— 「换图标」sheet 整层只有网格。
    var icons: [UmbraSheetIcon] = []
    var items: [UmbraSheetItem] = []
}

/// 确认弹窗。**实心红只出现在这里的最终动作上**（confirmDestructive = true）。
struct UmbraAlert: Identifiable {
    let id = UUID()
    let title: String
    var body: String = ""
    var cancelLabel: String = "取消"
    var confirmLabel: String
    var confirmDestructive: Bool = false
    var onConfirm: () -> Void = {}
}

/// 一闪而过的提示。带 undo 时停留 3 秒，否则 1.8 秒（原型的取值）。
struct UmbraToast: Identifiable {
    let id = UUID()
    let text: String
    var undo: (() -> Void)? = nil
}

// MARK: - Router

@MainActor
final class UmbraRouter: ObservableObject {

    @Published var tab: UmbraTab = .chat
    /// 每个 Tab 一条独立路径，各自的 NavigationStack 住在 TabView **里面** ——
    /// 这是根页原生大标题唯一可靠的形态（大小标题联动 = 导航栏和它正下方
    /// 滚动视图之间的系统机制，栈挪出去/嵌套都会破，两次实机都翻车了）。
    /// 底栏是真·系统 tab bar（液态玻璃的果冻动效只有系统件有）；「推入隐藏」
    /// 由 AppShell 监听这里的栈深调 setTabBarHidden 驱动，这里只管路径状态。
    @Published var paths: [UmbraTab: [UmbraRoute]] = [:]

    /// 多层底部选择器。空 = 没开。
    @Published var sheets: [UmbraSheet] = []
    @Published var alert: UmbraAlert?
    @Published var toast: UmbraToast?

    private var toastTask: Task<Void, Never>?

    /// 当前可见路由（Tab 根页时 = 根路由）。后台遮盖用它判断在不在保险箱子树。
    var current: UmbraRoute { paths[tab]?.last ?? tab.root }
    var canGoBack: Bool { !(paths[tab] ?? []).isEmpty }

    /// 给 NavigationStack(path:) 用的 Binding。系统返回（边缘右划 / 返回钮）
    /// 会直接改这个数组，所以 back() 和系统手势天然一致，不会各记各的账。
    func pathBinding(_ tab: UmbraTab) -> Binding<[UmbraRoute]> {
        Binding(
            get: { [weak self] in self?.paths[tab] ?? [] },
            set: { [weak self] in self?.paths[tab] = $0 }
        )
    }

    /// 给 TabView(selection:) 用的 Binding。
    /// setter 在**再点当前 Tab**时也会被调用（onChange 不会）—— 借这一下实现
    /// 「再点一次回到根」，和系统 Tab 的肌肉记忆一致。
    var tabSelection: Binding<UmbraTab> {
        Binding(
            get: { [weak self] in self?.tab ?? .chat },
            set: { [weak self] new in
                guard let self else { return }
                if new == self.tab { self.paths[new] = [] } else { self.tab = new }
            }
        )
    }

    // MARK: 栈操作

    func go(_ route: UmbraRoute) {
        paths[tab, default: []].append(route)
    }

    func back() {
        if !(paths[tab] ?? []).isEmpty { paths[tab]?.removeLast() }
    }

    /// 切到某个 Tab 的根（清掉该 Tab 的深栈）。深链与「回到主页」用。
    func root(_ tab: UmbraTab) {
        self.tab = tab
        paths[tab] = []
    }

    /// 跨 Tab 跳到某一页（聊天里那些「去看提醒 / 去看流水」的按钮）。
    /// 必须先落到目标 Tab 的**根**再推：直接 go 会把目标页压进当前 Tab 的栈里，
    /// 于是「聊天 › 提醒列表」，返回回到聊天 —— 用户按返回是想回提醒列表的。
    /// 目标本身就是根页时不再推一层（不然会出现「提醒列表 › 提醒列表」）。
    func jump(_ route: UmbraRoute) {
        root(route.tab)
        if route != route.tab.root { go(route) }
    }

    // MARK: 瞬时 UI

    func present(_ sheet: UmbraSheet) { sheets.append(sheet) }
    /// 关掉最上面一层。多层时是「上一步」，只有一层时就是关闭。
    func popSheet() { if !sheets.isEmpty { sheets.removeLast() } }
    func closeSheets() { sheets.removeAll() }

    func confirm(_ alert: UmbraAlert) { self.alert = alert }

    func showToast(_ text: String, undo: (() -> Void)? = nil) {
        toastTask?.cancel()
        toast = UmbraToast(text: text, undo: undo)
        let ns: UInt64 = undo == nil ? 1_800_000_000 : 3_000_000_000
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
