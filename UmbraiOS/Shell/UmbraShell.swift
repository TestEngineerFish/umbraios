// 应用外壳：把 Router 的栈渲染成页面，挂底部 Tab 栏与三种浮层。
//
// 转场：push 时新页从右滑入、back 时从左滑入（对应设计稿的 umpushA / umbackA，
// 都是 .22s 横向位移 26px）。**没有**缩放和弹跳 —— 规范写的是「无弹跳、无缩放」。
import SwiftUI

struct UmbraShell: View {
    @StateObject private var router = UmbraRouter()
    /// 任务 / 灵感的数据源挂在外壳上，而不是各页自己新建：
    /// 列表和详情共用同一份数据，各建各的会出现「详情里改了状态，退回列表还是旧的」。
    @StateObject private var tasks = TasksViewModel()
    @StateObject private var inspirations = InspirationsViewModel()
    /// 保险箱的数据源与会话（软锁 / 自动锁定 / Face ID）也挂在外壳上：
    /// 首页、详情、编辑、体检是四个独立路由，各建各的 store 会各解各的锁。
    @StateObject private var vault = VaultStore()
    @StateObject private var vaultSession = UmbraVaultSession()
    @EnvironmentObject private var chat: ChatViewModel

    @ObservedObject private var reminders = ReminderStore.shared
    @ObservedObject private var deepLink = UmbraDeepLink.shared
    @Environment(\.scenePhase) private var scenePhase

    /// 底栏角标，两个都是真实数据：
    ///   聊天 = 有新消息的**会话数**（ChatViewModel.unread 是会话集合，服务端没给条数，不编）；
    ///   提醒 = 已过期 + 今天到点的待办数（「更远」的不该顶个红点催人）。
    private var badges: [UmbraTab: Int] {
        var out: [UmbraTab: Int] = [:]
        if !chat.unread.isEmpty { out[.chat] = chat.unread.count }
        let due = reminders.items.filter { !$0.done && ($0.group == "已过期" || $0.group == "今天") }.count
        if due > 0 { out[.reminder] = due }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // 用 id 让路由变化触发转场；栈深度参与 id，是为了让同一路由的
                // push / pop 也能各自播一次动画。
                UmbraRouteView(route: router.current)
                    .environmentObject(router)
                    .environmentObject(tasks)
                    .environmentObject(inspirations)
                    .environmentObject(vault)
                    .environmentObject(vaultSession)
                    .id("\(router.stack.count)-\(String(describing: router.current))")
                    .transition(.asymmetric(
                        insertion: .move(edge: router.goingBack ? .leading : .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if router.current.showsTabBar {
                UmbraTabBar(
                    selection: .constant(router.tab),
                    badges: badges,
                    onSelect: { router.root($0) }
                )
            }
        }
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
// 一个 switch 把 route 映射到页面。已建好的页面直接接上；还没建的走
// UmbraPlaceholderPage —— 它是一个**真实承接页**，有返回、有说明，
// 不是弹个 toast 了事（自查清单：「每个『点了会怎样』的入口都有真实承接页」）。
struct UmbraRouteView: View {
    let route: UmbraRoute

    var body: some View {
        switch route {

        // ── Tab 根页（第 3–5 步逐个替换成真实实现）
        case .chatContacts:
            UmbraChatContactsView()
        case .chatThread(let conv):
            UmbraChatThreadView(conv: conv)

        case .remList:
            UmbraReminderListView()
        case .remDetail(let id):
            UmbraReminderDetailView(id: id)
        case .remEdit(let id):
            UmbraReminderEditView(id: id)

        case .taskList:
            UmbraTaskListView()
        case .taskDetail(let id):
            UmbraTaskDetailView(id: id)

        case .inspList:
            UmbraInspirationListView()
        case .inspDetail(let id):
            UmbraInspirationDetailView(id: id)
        case .inspEdit(let id):
            UmbraInspirationEditView(id: id)

        case .meHome:
            UmbraMeHomeView()
        case .mePhrases:
            UmbraPhrasesView()
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

        // ── 保险箱子树（第 5 步）
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

        // ── 系统形态演示（第 6 步）
        case .lockScreen:
            UmbraLockScreenDemo()
        case .vaultAutofill:
            UmbraAutoFillDemoView()
        case .vaultMask:
            UmbraMaskScreen()
        }
    }

    private func placeholder(_ title: String, _ what: String, step: Int) -> some View {
        UmbraPlaceholderPage(title: title, what: what, step: step)
    }
}

// MARK: - 未建成页面的承接页
//
// 刻意做成一个**能看懂、能退出**的页面，而不是空白或 toast：
// 骨架阶段最容易留下的坑就是「点进去什么都没有，也退不出来」。
struct UmbraPlaceholderPage: View {
    let title: String
    let what: String
    let step: Int
    @EnvironmentObject private var router: UmbraRouter

    var body: some View {
        UmbraPage(navBar: {
            if router.canGoBack {
                UmbraNavBar(backLabel: "返回", title: title, onBack: { router.back() })
            } else {
                UmbraNavBar(title: title)
            }
        }, content: {
            VStack(alignment: .leading, spacing: UmbraMetric.sp4) {
                UmbraCard {
                    VStack(alignment: .leading, spacing: UmbraMetric.sp2) {
                        UmbraSectionLabel(text: "这一页还没建")
                        Text(what)
                            .font(UmbraFont.body)
                            .foregroundColor(UmbraColor.text)
                            .lineSpacing(UmbraFont.bodyLineSpacing)
                        Text("导航骨架已通，页面内容在第 \(step) 步实现。")
                            .font(UmbraFont.rowSub)
                            .foregroundColor(UmbraColor.muted)
                    }
                }
                .padding(.horizontal, UmbraMetric.pagePadX)

                // 骨架自检：这几个入口用来验证栈、浮层、toast 真的通了。
                UmbraGroupCard {
                    UmbraListRow(title: "试一次底部选择器", showsChevron: true) {
                        router.present(UmbraSheet(
                            title: "选一个", subtitle: "验证多层选择器与返回箭头",
                            items: [
                                UmbraSheetItem(label: "第一项", checked: true, action: {}),
                                UmbraSheetItem(label: "进到下一层", note: "多层", action: {
                                    router.present(UmbraSheet(title: "第二层", items: [
                                        UmbraSheetItem(label: "回上一层试试")
                                    ]))
                                }),
                                UmbraSheetItem(label: "删除这一项", destructive: true, action: {
                                    router.showToast("已删除", undo: {})
                                })
                            ]))
                    }
                    UmbraRowDivider()
                    UmbraListRow(title: "试一次确认弹窗", showsChevron: true) {
                        router.confirm(UmbraAlert(
                            title: "删除这条记录？",
                            body: "删除后进回收站，30 天内还能恢复。",
                            confirmLabel: "删除",
                            confirmDestructive: true,
                            onConfirm: { router.showToast("已移到回收站") }))
                    }
                    UmbraRowDivider()
                    UmbraListRow(title: "试一次 toast", showsChevron: true) {
                        router.showToast("已复制，60 秒后自动清剪贴板")
                    }
                }
                .padding(.horizontal, UmbraMetric.pagePadX)
            }
            .padding(.top, UmbraMetric.sp5)
        })
    }
}
