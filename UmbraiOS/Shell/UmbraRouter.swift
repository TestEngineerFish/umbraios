// Umbra 导航与瞬时 UI 的唯一状态源。
//
// 形状是照着主设计稿的 state 抄的（交接文档 State Management 一节列了对应关系）：
//   stack: [{s, ...params}] → [Route]      tab → Tab
//   sheet（支持多层）/ alert / toast / viewer / recording → 各自一个可选值
//
// 为什么不用 SwiftUI 的 NavigationStack + NavigationLink：
// 设计稿的返回按钮带**上一页的名字**（「‹ 密码保险箱」「‹ 我」而不是统一的「‹ Back」），
// 而且 Tab 切换要**重置栈**（root(s, tab)）、演示态在栈底时返回要跳回主页。
// 这三条都要求「栈本身是可读可改的数据」，NavigationStack 的 path 表达不了带标题的返回。
// 所以自己管一个数组，转场动画用 .transition 手动给。
//
// 用 ObservableObject 而不是 @Observable：工程的部署目标是 iOS 16，@Observable 要 17。
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
    // 系统形态演示（顶部演示开关，不是应用内页面）
    case lockScreen
    case vaultAutofill
    case vaultMask

    /// 这一页属于哪个 Tab。切 Tab 时用来决定高亮，深链跳转时用来对齐底栏。
    var tab: UmbraTab {
        switch self {
        case .chatContacts, .chatThread: return .chat
        case .remList, .remDetail, .remEdit, .lockScreen: return .reminder
        case .taskList, .taskDetail: return .task
        case .inspList, .inspDetail, .inspEdit: return .inspiration
        default: return .me
        }
    }

    /// 是否显示底部 Tab 栏。演示态（锁屏、系统填充面板、后台遮盖）是「系统形态」，
    /// 不该出现应用自己的底栏。
    var showsTabBar: Bool {
        switch self {
        case .lockScreen, .vaultAutofill, .vaultMask: return false
        default: return true
        }
    }

    /// 演示态：栈底是它时，返回要跳回主页而不是把栈退空。
    /// 原型里为这个专门写了兜底（「避免卡死」），自查清单第一条就是「每个演示态都要有出口」。
    var isDemo: Bool {
        switch self {
        case .lockScreen, .vaultAutofill, .vaultMask: return true
        default: return false
        }
    }
}

// MARK: - Tab
//
// 顺序按**主设计稿**的 tabsVM()：聊天 / 提醒 / 任务 / 灵感 / 我。
// README 的 Screens 一节把任务写在第 2 位、提醒第 3 位，和设计稿不一致；
// 以设计稿为准（README 自己写了「主设计稿…全部屏幕、状态机、文案都在这里」）。
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
    var iconPath: String {
        switch self {
        case .chat: return UmbraIconPath.chat
        case .reminder: return UmbraIconPath.bell
        case .task: return UmbraIconPath.task
        case .inspiration: return UmbraIconPath.bulb
        case .me: return UmbraIconPath.user
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

    @Published private(set) var stack: [UmbraRoute] = [.chatContacts]
    @Published private(set) var tab: UmbraTab = .chat

    /// 多层底部选择器。空 = 没开。
    @Published var sheets: [UmbraSheet] = []
    @Published var alert: UmbraAlert?
    @Published var toast: UmbraToast?

    /// 转场方向。push 时新页从右滑入，back 时从左滑入 —— 设计稿的 umpushA / umbackA。
    @Published private(set) var goingBack = false

    private var toastTask: Task<Void, Never>?

    var current: UmbraRoute { stack.last ?? .chatContacts }
    var canGoBack: Bool { stack.count > 1 || current.isDemo }

    // MARK: 栈操作

    func go(_ route: UmbraRoute) {
        goingBack = false
        withAnimation(UmbraMotion.push) { stack.append(route) }
    }

    func back() {
        goingBack = true
        withAnimation(UmbraMotion.push) {
            if stack.count > 1 {
                stack.removeLast()
            } else if current.isDemo {
                // 演示态在栈底：退回「我」，不要把栈退空卡死在这一页。
                stack = [.meHome]
                tab = .me
            }
        }
    }

    /// 切 Tab：重置栈到该 Tab 的根。再点一次当前 Tab 也回根 —— 和系统 Tab 的习惯一致。
    func root(_ tab: UmbraTab) {
        goingBack = false
        withAnimation(UmbraMotion.push) {
            self.tab = tab
            stack = [tab.root]
        }
    }

    /// 演示态开关：再点一次退出（自查清单要求「可再点一次退出的开关」）。
    func toggleDemo(_ route: UmbraRoute) {
        if current == route {
            back()
        } else {
            goingBack = false
            withAnimation(UmbraMotion.push) { stack = [route] }
        }
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
