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
    // Tab 2 提醒
    case remList
    case remDetail(id: String)
    case remEdit(id: String?)          // nil = 新建
    // Tab 3 任务
    case taskList
    case taskDetail(id: String)
    // Tab 4 灵感
    case inspList
    case inspDetail(id: String)
    case inspEdit(id: String?)
    // Tab 5 我
    case meHome
    case mePhrases
    /// 常用语的新建/编辑页（nil = 新建）。设计稿 phrase.edit —— 独立推入页，不是弹窗。
    case mePhraseEdit(id: String?)
    case meDevices
    case deviceDetail(id: String)
    case meCaps
    case meWorkspace
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
    var tab: UmbraTab {
        switch self {
        case .chatContacts, .chatThread: return .chat
        case .remList, .remDetail, .remEdit: return .reminder
        case .taskList, .taskDetail: return .task
        case .inspList, .inspDetail, .inspEdit: return .inspiration
        default: return .me
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
// 顺序按主设计稿的 tabsVM()：聊天 / 提醒 / 任务 / 灵感 / 我。
enum UmbraTab: String, CaseIterable, Hashable {
    case chat, reminder, task, inspiration, me

    var label: String {
        switch self {
        case .chat: return "聊天"
        case .reminder: return "提醒"
        case .task: return "任务"
        case .inspiration: return "灵感"
        case .me: return "我"
        }
    }
    /// v2：tab bar 交给系统 TabView，图标用 SF Symbols ——
    /// 系统符号才吃得到 tab bar 的选中态渲染（iOS 26 上还有玻璃胶囊与动效）。
    /// 自绘 SVG 路径图标只在内容区继续用。
    var sfSymbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .reminder: return "bell"
        case .task: return "checklist"
        case .inspiration: return "lightbulb"
        case .me: return "person.crop.circle"
        }
    }
    var root: UmbraRoute {
        switch self {
        case .chat: return .chatContacts
        case .reminder: return .remList
        case .task: return .taskList
        case .inspiration: return .inspList
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

/// 一层底部选择器。**支持多层**（设计稿里「移动到分组」会从一层进到下一层），
/// 所以 UmbraRouter 里存的是数组而不是单个值。
struct UmbraSheet: Identifiable {
    let id = UUID()
    let title: String
    var subtitle: String? = nil
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
    /// 每个 Tab 一条独立路径 —— 切走再切回来，各 Tab 的深栈还在（系统 App 的习惯）。
    /// 一期是全局一条栈、切 Tab 就清空，那是自绘栈的简化，不是想要的行为。
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
