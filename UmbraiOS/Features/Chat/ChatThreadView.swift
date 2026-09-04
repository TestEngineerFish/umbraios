// 聊天 · 对话页（chat.thread）。
//
// 数据全部来自既有的 ChatViewModel.blocks，**没有 mock**：服务端没推过来的东西这里就是没有。
// 设计稿里的消息种类和工程里的 ChatBlock 是这样对上的：
//   user  → 用户气泡          ai        → 秘书气泡（+ 工具轨迹卡）
//   tool  → 秘书气泡里的轨迹卡  confirm   → 执行前确认卡
//   task  → 任务进度卡         question  → 问答卡
//   saved → 「已记下灵感」卡    note      → 居中的一行系统说明
// 设计稿有、工程侧还没有的：saved（服务端不推「灵感已保存」的聊天块）、voice（见下）。
// 工程侧有、设计稿没画的：device（设备发来的消息）、done（任务产出）、locate（电脑操作求助）、
// error。这四种照设计语言补齐，其中 locate 直接复用既有的 LocateCard —— 那套箭头指位
// 交互（缩放、平移、抓箭杆）已经调好了，没有新设计稿之前重画一遍只会更差。
import SwiftUI
import UIKit

struct UmbraChatThreadView: View {
    let conv: String

    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var chat: ChatViewModel
    @StateObject private var rec = UmbraHoldRecorder()
    @Environment(\.scenePhase) private var scenePhase

    /// 输入栏形态：打字 / 按住说话。右侧那个按钮在两者之间切。
    @State private var voiceMode = false
    /// 快捷语音：长按空输入框直接开录的那一次按压是否还在进行中。
    /// 单独记一个开关，松手时才知道这轮录音是「长按快捷入口」发起的，要走收尾。
    @State private var quickVoiceActive = false
    /// 输入框焦点。点消息区、往下拖、切到语音态都靠它收键盘。
    @FocusState private var inputFocused: Bool
    /// 应用内图片预览器（产出图片点开）。非 nil 即全屏展示。
    @State private var viewerItem: UmbraViewerItem?

    private var isAssistant: Bool { conv == ChatViewModel.mainConv }
    private var title: String { chat.convLabel(conv) }
    private var device: KnownDevice? { chat.device(for: conv) }
    /// 「/」面板在这个页面开不开：VM 的条件（芯片/斜杠/没按过「当普通消息发」）
    /// 再叠 View 侧的两条 —— 语音态不弹、只读会话没有输入框自然不弹。
    private var slashOn: Bool { chat.slashPanelOn && !voiceMode && inputEnabled }

    var body: some View {
        VStack(spacing: 0) {
            if let d = device, !d.online { offlineBanner }
            ZStack(alignment: .bottom) {
                messages
                // 「/」快捷面板：输入条上方的浮层卡（批次 005）。稿的关闭手势是点面板外
                // 空白 = 清空草稿关面板 —— 挡触层盖住消息区，面板本身叠在它上面不受影响。
                // 挡触层只认点按，但它在 ScrollView 之上，面板开着时消息区不可滚 —— 稿也如此。
                if slashOn {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { chat.draft = "" }
                    SlashPanelView(
                        query: chat.slashQuery,
                        onPick: { a in
                            chat.chipAction = a
                            chat.draft = ""
                            inputFocused = true   // 选完直接打参数，不让用户再点一次输入框
                        },
                        onSendPlain: { chat.slashDismissed = true })
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
            inputBar
        }
        .background(UmbraColor.bg)
        .umbraImageViewer(item: $viewerItem)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            // 标题带 26px 头像（v2 原型：秘书=橙色圆 + 机器人，设备=圆角方块 + 显示器），
            // 和会话列表同一套形状语言。
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: isAssistant ? 13 : 8, style: .continuous)
                        .fill(isAssistant ? UmbraColor.orange : UmbraColor.chip)
                        .frame(width: 26, height: 26)
                        .overlay(
                            UmbraIcon(d: isAssistant ? UmbraIconPath.robot : UmbraIconPath.monitor,
                                      size: 14, strokeWidth: 1.9)
                                .foregroundColor(isAssistant ? .white : UmbraColor.muted)
                        )
                    Text(title)
                        .font(UmbraFont.sans(17, .w600))
                        .foregroundColor(UmbraColor.text)
                        .lineLimit(1)
                }
            }
            if isAssistant {
                ToolbarItem(placement: .topBarTrailing) {
                    // 「⋯」：系统 Menu 锚定弹出。清空是破坏性入口，红字 + 必进确认弹窗。
                    Menu {
                        Button {
                            // 离线时 /new 出不去，本地历史也就不该清（清了服务端那边话题没断）。
                            router.showToast(chat.newSession() ? "已开始新会话" : L("chat.notConnected"))
                        } label: {
                            Label("新会话", systemImage: "plus.bubble")
                        }
                        Button {
                            UIPasteboard.general.string = transcript()
                            router.showToast("已复制")
                        } label: {
                            Label("复制聊天", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            router.confirm(UmbraAlert(
                                title: "确认清空与秘书的聊天历史？",
                                body: "此操作不可撤销（设备会话不受影响）。",
                                confirmLabel: "清空",
                                confirmDestructive: true,
                                onConfirm: {
                                    chat.clearActiveHistory()
                                    router.showToast("聊天历史已清空")
                                }))
                        } label: {
                            Label("清空聊天", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .tint(UmbraColor.orange)
                }
            } else if let d = device {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设备详情") {
                        router.go(.deviceDetail(id: d.device_id))
                    }
                    .tint(UmbraColor.orange)
                }
            }
        }
        .overlay { if rec.active { UmbraVoiceHoldOverlay(rec: rec) } }
        // 切后台 / 被系统打断 → 丢弃这次录音。三条兜底之一。
        .onChange(of: scenePhase) { phase in if phase != .active { rec.abort() } }
        .onDisappear { rec.abort() }
        .onAppear {
            if chat.activeConv != conv { chat.switchConversation(conv) }
            rec.onAutoFinish = { finishRecording($0) }
        }
    }

    // MARK: - 顶部

    /// 设备离线横幅。warning-soft 底 + warning 字 + 三角图标 —— 状态不只靠颜色。
    private var offlineBanner: some View {
        HStack(spacing: 8) {
            UmbraIcon(d: UmbraIconPath.alertTriangle, size: 15, strokeWidth: 2)
            Text("这台设备当前离线，端侧任务无法执行")
                .font(UmbraFont.sans(12.5, .w560))
            Spacer(minLength: 0)
        }
        .foregroundColor(UmbraColor.warning)
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.vertical, UmbraMetric.sp3)
        .background(UmbraColor.warningSoft)
    }

    // MARK: - 消息区

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: UmbraMetric.sp4) {
                    if chat.canLoadOlder {
                        Button {
                            Task { await chat.loadOlderHistory() }
                        } label: {
                            Text("加载更早消息…")
                                .font(UmbraFont.sans(12.5, .w400))
                                .foregroundColor(UmbraColor.faint)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, UmbraMetric.sp3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if chat.blocks.isEmpty { emptyState }

                    ForEach(Array(chat.blocks.enumerated()), id: \.element.id) { idx, block in
                        row(block, index: idx)
                            .frame(maxWidth: .infinity, alignment: alignment(block))
                            .id(block.id)
                    }
                }
                .padding(.horizontal, UmbraMetric.pagePadX)
                .padding(.top, UmbraMetric.sp5)
                .padding(.bottom, UmbraMetric.sp6)
            }
            // ⚠️ 不用 .defaultScrollAnchor(.bottom)：它和 LazyVStack 撞 ——
            // 懒加载行高在首帧只是估值，按估值锚到底会**滚过头**，
            // 进来一屏空白、要往下拉才见到历史（实机复现，已回退）。
            // 「键盘收起消息跟着回落」改由下面的焦点 onChange 双向 scrollToEnd 承担。
            // 往下拖收键盘。IM 里这是肌肉记忆，不给的话只能去够那个「完成」键。
            .scrollDismissesKeyboard(.interactively)
            // 点消息区的空白处收键盘。用 simultaneousGesture 而不是 onTapGesture：
            // onTapGesture 会把气泡上的按钮（展开轨迹、批准、填答案）一起吃掉。
            .simultaneousGesture(TapGesture().onEnded { inputFocused = false })
            .onChange(of: chat.blocks.count) { _ in scrollToEnd(proxy) }
            // 键盘**弹起**要跟滚（正在看的那条会被顶到键盘后面），
            // 键盘**收起**也要跟滚（不然列表停在上移后的位置，底下空一截）——两个方向都回底。
            .onChange(of: inputFocused) { _ in scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = chat.blocks.last else { return }
        withAnimation(UmbraMotion.tint) { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(isAssistant ? "跟秘书说点什么" : "直接吩咐「\(title)」做事")
                .font(UmbraFont.sans(15, .w560))
                .foregroundColor(UmbraColor.text)
            Text(isAssistant ? "描述你的目标就行，Umbra 会拆活、派活。" : "秘书会把任务派给这台设备。")
                .font(UmbraFont.sans(13, .w400))
                .foregroundColor(UmbraColor.muted)
                .lineSpacing(13 * 0.6)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 250)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
    }

    private func alignment(_ b: ChatBlock) -> Alignment {
        switch b {
        case .user: return .trailing
        case .note, .error: return .center
        default: return .leading
        }
    }

    // MARK: - 单条消息

    @ViewBuilder
    private func row(_ block: ChatBlock, index: Int) -> some View {
        switch block {
        case .user(let u):
            userBubble(u)

        case .assistant(let a):
            VStack(alignment: .leading, spacing: 5) {
                // 设备会话里左侧会同时出现秘书和设备两方的话，秘书这边也要标明身份。
                if !isAssistant, !a.text.isEmpty || a.streaming {
                    senderHeader(icon: UmbraIconPath.robot, name: "秘书", tint: UmbraColor.orange)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if !a.trace.isEmpty { traceCard(a, index: index) }
                    if !a.text.isEmpty || a.streaming { aiBubble(a) }
                    // 停在半截的那条：气泡下一行小字（批次 011 ①）。
                    // **不在正文里加「（已中断）」** —— 括号在气泡里会被读成秘书自己说的话。
                    if a.interrupted, !a.text.isEmpty { interruptedFootnote }
                    if let kept = ChatKeptTool.line(for: a.toolsRun) { keptToolsRow(kept) }
                }
            }

        case .device(_, let text, _):
            VStack(alignment: .leading, spacing: 5) {
                senderHeader(icon: UmbraIconPath.monitor, name: title, tint: UmbraColor.faint)
                plainLeftBubble(text, fill: UmbraColor.deviceBubble)
            }

        case .task(let j):
            taskCard(j)

        case .done(_, let goal, let results):
            doneCard(goal: goal, results: results)

        case .confirm(let c):
            confirmCard(c)

        case .question(let q):
            UmbraQuestionCard(block: q)

        case .locate(let l):
            // 复用既有实现（ChatView.swift）。等这块出了 iOS 设计稿再按新语言重做。
            LocateCard(
                data: l,
                onLocate: { nx, ny in chat.handleLocate(askId: l.askId, nx: nx, ny: ny) },
                onFeedback: { chat.handleLocateFeedback(askId: l.askId, text: $0) },
                onPause: { chat.handleLocatePause(askId: l.askId) },
                onResume: { chat.handleResume(runId: l.runId, askId: l.askId) }
            )

        case .note(let n):
            // 系统提示行不接长按菜单（`messageMenu.byKind.systemLine`）：它不是消息。
            VStack(spacing: 8) {
                Text(n.text)
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(UmbraColor.faint)
                    .padding(.horizontal, UmbraMetric.sp4)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(UmbraColor.chip))
                if let kept = ChatKeptTool.line(for: n.toolsRun) { keptToolsRow(kept) }
            }

        case .error(_, let text):
            errorCard(text)
        }
    }

    /// 长按气泡复制。IM 的通行做法，textSelection 只能选不能一键复制整条。
    ///
    /// ⚠️ 这还是**批次 011 之前**的两项菜单。稿②要求按消息类型分档
    ///（我发的 / 秘书的 / 失败的 / 图片 / 卡片），并补上引用、存为常用语、记为灵感、删除。
    /// 引用与删除的数据层已经通了（`ChatViewModel.quoteMessage` / `deleteMessage`、
    /// 服务端的 `message_delete` 与 meta.quote），**缺的只是这层菜单 UI**，留在 ② 那一批做 ——
    /// 别再照着老注释重新判一次「服务端不支持」。
    @ViewBuilder
    private func copyMenu(_ text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
            router.showToast("已复制")
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        Button {
            // 把这句话变成一条一小时后的本机提醒 —— 提醒本来就是本机功能，这是真的。
            let r = UmbraReminder(id: UUID().uuidString,
                                  text: String(text.prefix(80)),
                                  at: Date().addingTimeInterval(3600),
                                  source: "聊天")
            ReminderStore.shared.save(r)
            ReminderStore.shared.requestAuthorizationIfNeeded()
            router.showToast("已加到提醒 · 1 小时后")
        } label: {
            Label("添加提醒", systemImage: "bell")
        }
    }

    private func userBubble(_ u: ChatBlock.UserBlock) -> some View {
        // ⚠️ 别用 `.frame(maxWidth: 270)` 给气泡限宽：SwiftUI 的 maxWidth 会让这个 frame
        // **撑满父级给的宽度直到上限**，于是「好的」两个字也画成 270 宽的一大块，
        // 看起来就是「消息永远一样长、文字缩在左边」（用户点名）。
        // 正确做法是让气泡取自身理想宽度，靠外层 HStack 的 Spacer 把它推到一侧、
        // 同时用 Spacer 的 minLength 留出对侧留白 —— 长文自然换行，短文自然收窄。
        HStack(spacing: 0) {
            Spacer(minLength: UmbraMetric.bubbleGutter)
            Text(u.text)
                .font(UmbraFont.sans(15.5, .w400))
                .foregroundColor(UmbraColor.text)
                .lineSpacing(15.5 * 0.5)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(UmbraBubbleShape(mine: true).fill(UmbraColor.userBubble))
                .contextMenu { myMenu(u) }
        }
    }

    /// 我方气泡的长按菜单。发**失败**的那条按稿②砍到三项、「重新发送」置顶
    ///（`messageMenu.byKind.failed`：那条还没送出去，引用和存起来都无从谈起，
    /// 而你右键它十次有九次就是为了重发）。这条路必须现在就通 —— 不然离线发一条，
    /// 它就带着红叹号卡在那儿，既发不出去也删不掉。
    /// 正常那条仍是老的两项，按类型分档的完整菜单留在 ② 那一批。
    @ViewBuilder
    private func myMenu(_ u: ChatBlock.UserBlock) -> some View {
        if u.failed {
            Button {
                chat.resendFailed(blockId: u.id.uuidString)
            } label: {
                Label("重新发送", systemImage: "arrow.clockwise")
            }
            Button {
                UIPasteboard.general.string = u.text
                router.showToast("已复制")
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            // 服务端上根本没有这条，只是本地移除 —— 不走「移入回收站 30 天」那套确认。
            Button(role: .destructive) {
                chat.dropLocal(blockId: u.id.uuidString)
            } label: {
                Label("删除", systemImage: "trash")
            }
        } else {
            copyMenu(u.text)
        }
    }

    /// 左侧气泡。fill 用来区分说话人：秘书用 card、设备用 deviceBubble ——
    /// 两边都在左侧，不换色的话在设备会话里根本分不出哪句是秘书说的（用户点名）。
    private func plainLeftBubble(_ text: String, fill: Color = UmbraColor.card) -> some View {
        // 同 userBubble：宽度随内容，靠右侧 Spacer 留白，不用 maxWidth 撑满。
        HStack(spacing: 0) {
            UmbraMarkdownText(raw: text)
                .foregroundColor(UmbraColor.text)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(UmbraBubbleShape(mine: false).fill(fill))
                .overlay(UmbraBubbleShape(mine: false).stroke(UmbraColor.border, lineWidth: UmbraMetric.borderW))
                .contextMenu { copyMenu(text) }
            Spacer(minLength: UmbraMetric.bubbleGutter)
        }
    }

    /// 发言人抬头（小图标 + 名字）。只在**设备会话**里出现 ——
    /// 主会话整屏都是秘书，每条都标一遍纯属噪音。
    private func senderHeader(icon: String, name: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            UmbraIcon(d: icon, size: 12, strokeWidth: 1.9)
                .foregroundColor(tint)
            Text(name).font(UmbraFont.sans(11.5, .w560))
                .foregroundColor(UmbraColor.faint)
        }
    }

    private func aiBubble(_ a: ChatBlock.AssistantBlock) -> some View {
        // 外层再包一层 HStack + 右侧 Spacer：同 userBubble 的理由，宽度随内容。
        // 停止钮（批次 011 ①）**常显**在占位 / 流式气泡尾部，不做「按住才出现」——
        // 等回复的那几秒正是最需要看见它的时候，藏起来等于让人先学会「原来这里能点」。
        HStack(alignment: .bottom, spacing: 8) {
            aiBubbleBody(a)
            if a.streaming { stopButton }
            // 停止钮占掉「钮 32 + 间距 8」，从右侧留白里扣，气泡的可用宽度不变 ——
            // 否则一有停止钮气泡就先窄一截、停完又变宽，正在读的那段会整体重排。
            Spacer(minLength: a.streaming
                   ? UmbraMetric.bubbleGutter - Self.stopDiameter - 8
                   : UmbraMetric.bubbleGutter)
        }
    }

    /// 停止这次回复：视觉 32pt 圆钮，热区 44pt（`replyCancel.button`）。
    /// 热区靠透明外框撑出来 —— 稿的规矩是「视觉可以小于 44，热区不许」。
    private var stopButton: some View {
        Button {
            if !chat.cancelReply() { router.showToast(L("chat.notConnected")) }
        } label: {
            UmbraIcon(d: UmbraIconPath.stopSquare, size: 13, strokeWidth: 2)
                .foregroundColor(UmbraColor.muted)
                .frame(width: Self.stopDiameter, height: Self.stopDiameter)
                .background(Circle().fill(UmbraColor.bg))
                .overlay(Circle().stroke(UmbraColor.border, lineWidth: UmbraMetric.borderW))
                .frame(width: UmbraMetric.tapMin, height: UmbraMetric.tapMin)   // 热区
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("chat.stopReply"))
        // 热区比视觉大一圈，用负边距抵掉，免得把气泡行撑高。跟着 tapMin 走，
        // 写死 -6 的话以后调 tapMin 这里会静默错位。
        .padding(-(UmbraMetric.tapMin - Self.stopDiameter) / 2)
    }

    /// 停止钮的视觉直径（稿：32，热区 44）。热区走 `UmbraMetric.tapMin`。
    private static let stopDiameter: CGFloat = 32

    /// 半截回复下面那行小字。图标是同一颗停止方块 —— 让人一眼认出「这是你按的那个键干的」。
    private var interruptedFootnote: some View {
        HStack(spacing: 5) {
            UmbraIcon(d: UmbraIconPath.stopSquare, size: 12, strokeWidth: 2)
                .foregroundColor(UmbraColor.faint)
            Text(L("chat.interruptedNote"))
                .font(UmbraFont.sans(11.5, .w400))
                .foregroundColor(UmbraColor.faint)
                .fixedSize()
        }
    }

    /// 取消收尾的琥珀行（`replyCancel.toolKept`）。只在真的跑过**会留下东西**的工具时出：
    /// 只读查询停了就停了，说「不跟着撤销」反而吓人。文案具体到那一条，并给一个能去看的钮 ——
    /// 笼统的「已执行的操作不会撤销」被稿方点名否掉了。
    /// 收的是**已经解析好的那一行**（`ChatKeptTool.line`），不是原始工具清单：
    /// 「一个会留下东西的工具都没有 → 这一行不出」的判断必须发生在 VStack 外面，
    /// 不然 VStack 会给一个空 View 也留出一格间距。
    private func keptToolsRow(_ kept: (text: String, route: UmbraRoute, button: String)) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                UmbraIcon(d: UmbraIconPath.alertTriangle, size: 16, strokeWidth: 1.9)
                    .foregroundColor(UmbraColor.warning)
                    .padding(.top, 2)
                Text(kept.text)
                    .font(UmbraFont.sans(13, .w400))
                    .foregroundColor(UmbraColor.warning)
                    .lineSpacing(13 * 0.6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                router.jump(kept.route)
            } label: {
                Text(kept.button)
                    .font(UmbraFont.sans(14.5, .w600))
                    .foregroundColor(UmbraColor.warning)
                    .frame(maxWidth: .infinity, minHeight: UmbraMetric.tapMin)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(UmbraColor.warning, lineWidth: UmbraMetric.borderW))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(width: 300, alignment: .leading)   // 与同屏的轨迹卡 / 任务卡 / 确认卡同宽
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(UmbraColor.warningSoft))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(UmbraColor.warning, lineWidth: UmbraMetric.borderW))
    }

    private func aiBubbleBody(_ a: ChatBlock.AssistantBlock) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            // 占位（一个字都还没流出来）：三点 —— 光标在空气泡里闪，看不出「它在想」。
            if a.thinking, a.text.isEmpty { UmbraThinkingDots() }
            if !a.text.isEmpty {
                // 秘书的回复里全是「**开发步骤**：」「1. 需求分析」这类 Markdown，
                // 直接当纯文本画出来满屏星号井号（用户点名）——走块级渲染。
                UmbraMarkdownText(raw: a.text)
                    .foregroundColor(UmbraColor.text)
                    .textSelection(.enabled)
            }
            // 流式光标：7×16 橙块，1 秒硬闪一次（steps(1)，不是渐隐）。
            // 只在**已经有字**时闪：空气泡里一根光标看不出「它在想」，那一段归三点。
            if a.streaming, !a.text.isEmpty { UmbraBlinkCaret() }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(UmbraBubbleShape(mine: false).fill(UmbraColor.card))
        .overlay(UmbraBubbleShape(mine: false).stroke(UmbraColor.border, lineWidth: UmbraMetric.borderW))
        .contextMenu { if !a.text.isEmpty { copyMenu(a.text) } }
    }

    /// 工具轨迹卡。工程里的 trace 是一行行字符串（「🔧 名字(参数)」「↳ 名字 → 结果」），
    /// 不像设计稿那样拆成 name / args / result 三段 —— 那要改服务端协议，这里如实按行显示。
    private func traceCard(_ a: ChatBlock.AssistantBlock, index: Int) -> some View {
        VStack(spacing: 0) {
            Button {
                chat.toggleTrace(at: index)
            } label: {
                HStack(spacing: 8) {
                    UmbraIcon(d: UmbraIconPath.wrench, size: 15, strokeWidth: 1.9)
                    Text("工具轨迹 · \(a.trace.count) 步")
                        .font(UmbraFont.sans(13.5, .w560))
                    Spacer(minLength: 0)
                    UmbraIcon(d: UmbraIconPath.chevronRight, size: 16, strokeWidth: 2.2)
                        .rotationEffect(.degrees(a.traceOpen ? 90 : 0))
                        .animation(UmbraMotion.tint, value: a.traceOpen)
                }
                .foregroundColor(UmbraColor.muted)
                .padding(.horizontal, UmbraMetric.sp4)
                .padding(.vertical, 10)
                .frame(minHeight: UmbraMetric.tapMin)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if a.traceOpen {
                VStack(spacing: 0) {
                    ForEach(Array(a.trace.enumerated()), id: \.offset) { i, line in
                        HStack(alignment: .top, spacing: UmbraMetric.sp3) {
                            Text("\(i + 1)")
                                .font(UmbraFont.sans(11, .w600))
                                .foregroundColor(UmbraColor.faint)
                                .frame(width: 18, height: 18)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(UmbraColor.chip))
                            Text(line)
                                .font(UmbraFont.mono(12, .w400))
                                .foregroundColor(UmbraColor.muted)
                                .lineSpacing(12 * 0.5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, UmbraMetric.sp4)
                        .padding(.vertical, UmbraMetric.sp3)
                        .overlay(alignment: .top) {
                            Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
                        }
                    }
                }
            }
        }
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
        .overlay(
            RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
        )
    }

    // MARK: 任务进度卡（TaskProgressCard）

    private func taskCard(_ j: ChatBlock.TaskBlock) -> some View {
        let st = UmbraStatus(taskStatus: j.status)
        let finished = j.status != "running" && j.status != "pending"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: UmbraMetric.sp3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(st.soft)
                    if st == .running {
                        UmbraSpinningIcon(d: st.iconPath, size: 14, strokeWidth: 2.1)
                    } else {
                        UmbraIcon(d: st.iconPath, size: 14, strokeWidth: 2.1)
                    }
                }
                .foregroundColor(st.fg)
                .frame(width: 24, height: 24)

                Text(j.goal)
                    .font(UmbraFont.sans(14.5, .w560))
                    .foregroundColor(UmbraColor.text)
                    .lineSpacing(14.5 * 0.45)
                    .frame(maxWidth: .infinity, alignment: .leading)

                UmbraStatusBadge(status: st)
            }

            UmbraProgressBar(progress: Double(j.pct) / 100, color: st.bar)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // 服务端的步骤结论不再截断（时间线不省略，2026-08-26 拍板），这条 message
                // 可能长达几百字 —— 聊天卡是概览，限 8 行兜底，全文看任务详情。
                Text(j.message)
                    .font(UmbraFont.sans(13, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineSpacing(13 * 0.5)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(j.pct)%")
                    .font(UmbraFont.mono(12, .w400))
                    .foregroundColor(UmbraColor.faint)
            }

            // 任务卡上顺带要确认：批准/总是允许/拒绝，和确认卡同一套动作。
            if let confirmId = j.confirmId {
                confirmActions(confirmId: confirmId)
            }

            if finished {
                UmbraButton(title: st == .failed ? "重试任务" : "查看结果", kind: .secondary, height: 44) {
                    router.go(.taskDetail(id: j.taskId))
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, UmbraMetric.sp4)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
        .overlay(
            RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
        )
    }

    /// 绿色完成卡（完成广播）。批次 005 稿：完成时聊天里是两张相邻卡 ——
    /// 进度卡收敛成 done 态只管过程（查看结果），**产出区只挂这张绿卡**，同一批产出只出一份。
    /// 稿里没产出时整卡不出，但工程侧广播块已经进了聊天流，整卡消失更像丢消息 ——
    /// 折中：保留「任务完成」头一行，只是不渲染空的产出容器。
    private func doneCard(goal: String, results: [[String: String]]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                UmbraIcon(d: UmbraIconPath.check, size: 15, strokeWidth: 2.2)
                    .foregroundColor(UmbraColor.success)
                    .padding(.top, 2)
                Text("任务完成：\(goal)")
                    .font(UmbraFont.sans(13.5, .w600))
                    .foregroundColor(UmbraColor.success)
                    .lineSpacing(13.5 * 0.45)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.offset) { i, r in
                        if i > 0 {
                            Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
                        }
                        resultRow(r)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UmbraColor.card))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(UmbraColor.success, lineWidth: UmbraMetric.borderW)
                )
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.successSoft))
        .overlay(
            RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                .strokeBorder(UmbraColor.success, lineWidth: UmbraMetric.borderW)
        )
    }

    /// 产出行（稿：36×36 前导块 + 名 + 等宽 meta + chevron，行高 ≥52）。
    /// 图片点开走应用内预览器，其它类型交系统打开 —— 只有图在应用内看才有意义，
    /// html / zip 之类系统比我们会处理。meta 显示服务器路径：同名文件靠路径区分。
    private func resultRow(_ r: [String: String]) -> some View {
        let url = r["url"] ?? ""
        let name = r["title"] ?? (url.isEmpty ? "产出" : url)
        let isImg = UmbraViewerItem.looksImage(url)
        let full = fullResultURL(url)
        let meta = url.replacingOccurrences(of: #"^https?://[^/]+"#, with: "", options: .regularExpression)
        return Button {
            if isImg, let u = full {
                viewerItem = UmbraViewerItem(url: u, name: name)
            } else {
                openResult(url)
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UmbraColor.chip)
                    if isImg, let u = full {
                        // 内联缩略：截图任务的重点就是看那张图。失败退回图片图标，不留破图占位。
                        AsyncImage(url: u) { phase in
                            if case .success(let img) = phase {
                                img.resizable().scaledToFill()
                            } else {
                                UmbraIcon(d: UmbraIconPath.image, size: 16, strokeWidth: 1.8)
                                    .foregroundColor(UmbraColor.muted)
                            }
                        }
                    } else {
                        UmbraIcon(d: UmbraIconPath.file, size: 16, strokeWidth: 1.8)
                            .foregroundColor(UmbraColor.muted)
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(UmbraColor.borderSoft, lineWidth: UmbraMetric.borderW)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(UmbraFont.sans(13.5, .w560))
                        .foregroundColor(UmbraColor.text)
                        .lineLimit(1)
                    if !meta.isEmpty {
                        Text(meta)
                            .font(UmbraFont.mono(11, .w400))
                            .foregroundColor(UmbraColor.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                UmbraIcon(d: UmbraIconPath.chevronRight, size: 14, strokeWidth: 2.2)
                    .foregroundColor(UmbraColor.faint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 相对路径补服务端前缀。返回 nil 表示这条产出连 url 都拼不出来（不该出现，防御）。
    private func fullResultURL(_ url: String) -> URL? {
        guard !url.isEmpty else { return nil }
        let full = url.hasPrefix("http") ? url : NetworkConfig.shared.serverUrl + url
        return URL(string: full)
    }

    private func openResult(_ url: String) {
        guard let u = fullResultURL(url) else { return }
        UIApplication.shared.open(u)
    }

    // MARK: 执行前确认卡

    private func confirmCard(_ c: ChatBlock.ConfirmBlock) -> some View {
        let head: (String, Color, Color, String) = {
            switch c.resolved {
            case .none: return ("需要执行前确认", UmbraColor.warningSoft, UmbraColor.warning, UmbraIconPath.shield)
            case .some(.approved): return ("已批准，执行中…", UmbraColor.orangeSoft, UmbraColor.orangeText, UmbraIconPath.spinnerArc)
            case .some(.denied): return ("已拒绝", UmbraColor.dangerSoft, UmbraColor.danger, UmbraIconPath.xCircle)
            }
        }()
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                UmbraIcon(d: head.3, size: 16, strokeWidth: 2)
                Text(head.0).font(UmbraFont.sans(13.5, .w600))
                Spacer(minLength: 0)
            }
            .foregroundColor(head.2)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(head.1)

            VStack(alignment: .leading, spacing: 10) {
                Text(c.summary)
                    .font(UmbraFont.sans(14.5, .w400))
                    .foregroundColor(UmbraColor.text)
                    .lineSpacing(14.5 * 0.55)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if c.resolved == nil { confirmActions(confirmId: c.confirmId) }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, UmbraMetric.sp4)
        }
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
        // 先裁剪（头部是整块实底，不裁会盖住圆角）再描边。
        .clipShape(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                .strokeBorder(head.1, lineWidth: UmbraMetric.borderW)
        )
    }

    /// 批准 / 总是允许 / 拒绝。「拒绝」是描边红不是实心红 ——
    /// 实心红全 App 只出现在确认弹窗的最终动作上。
    private func confirmActions(confirmId: String) -> some View {
        VStack(spacing: 7) {
            UmbraButton(title: "批准", kind: .primary, height: 44) {
                chat.handleConfirm(confirmId: confirmId, approved: true)
            }
            HStack(spacing: 7) {
                UmbraButton(title: "总是允许", kind: .secondary, height: 44) {
                    chat.handleConfirmAlways(confirmId: confirmId)
                }
                UmbraButton(title: "拒绝", kind: .dangerOutline, height: 44) {
                    chat.handleConfirm(confirmId: confirmId, approved: false)
                }
            }
        }
    }

    /// 错误三段式：发生了什么 → 为什么 → 现在能做什么（第三段必须是可点按钮）。
    /// 服务端给的 message 只是前两段，第三段这里固定给「重新连接」——
    /// 聊天里的错误绝大多数是连接断了，而重连是用户此刻唯一能做的事。
    private func errorCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: UmbraMetric.sp3) {
            HStack(spacing: 7) {
                UmbraIcon(d: UmbraIconPath.xCircle, size: 15, strokeWidth: 2)
                Text("这一轮没能完成").font(UmbraFont.sans(13.5, .w600))
            }
            .foregroundColor(UmbraColor.danger)
            Text(text)
                .font(UmbraFont.sans(13, .w400))
                .foregroundColor(UmbraColor.muted)
                .lineSpacing(13 * 0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
            UmbraButton(title: "重新连接", kind: .secondary, height: 44) {
                chat.ws.reconnect()
                router.showToast("正在重新连接")
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, UmbraMetric.sp4)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
        .overlay(
            RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                .strokeBorder(UmbraColor.dangerSoft, lineWidth: UmbraMetric.borderW)
        )
    }

    // MARK: - 输入栏

    /// 设备会话默认只读：任务进度照样推进来，但不能在这里直接吩咐它。
    /// 开关在「我 › 设备与能力 › 设备详情」里（NetworkConfig.allowDeviceSend）。
    private var inputEnabled: Bool { isAssistant || NetworkConfig.shared.allowDeviceSend }

    @ViewBuilder
    private var inputBar: some View {
        if inputEnabled { composer } else { readOnlyBar }
    }

    /// 只读态的底栏。不是把输入框置灰 —— 置灰的输入框看不出为什么不能打字，
    /// 这里直接说明原因并给一个「去打开」的真实入口。
    private var readOnlyBar: some View {
        HStack(spacing: 10) {
            UmbraIcon(d: UmbraIconPath.lock, size: 16, strokeWidth: 1.9)
                .foregroundColor(UmbraColor.faint)
            Text("这个设备会话只读。任务进度照样推进来。")
                .font(UmbraFont.sans(12.5, .w400))
                .foregroundColor(UmbraColor.muted)
                .lineSpacing(12.5 * 0.55)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if let d = device { router.go(.deviceDetail(id: d.device_id)) }
            } label: {
                Text("去打开")
                    .font(UmbraFont.sans(13, .w560))
                    .foregroundColor(UmbraColor.orange)
                    .frame(minHeight: UmbraMetric.tapMin)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.top, UmbraMetric.sp4)
        .padding(.bottom, UmbraMetric.sp5)
        .background(UmbraColor.bg.opacity(0.94))
        .overlay(alignment: .top) {
            Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
        }
    }

    // 模式切换 chip（auto / chat / execution 的 Menu）已随批次 005 整个撤除 ——
    // 它的位置由「/」快捷输入的前缀芯片顶上，芯片直接住在输入框里。
    private var composer: some View {
        VStack(spacing: 0) {
            if let banner = chat.ideaBanner { ideaBannerView(banner) }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack {
                    if voiceMode { holdBar } else { textField }
                }
                // 快捷语音的手势不直接压在 TextField 上（SwiftUI 手势叠在 UIKit 输入框上
                // 会把「点一下弹键盘」吃掉 —— 实机复现：点输入框不出键盘）。
                // 改成**只在「没焦点、没内容」时**盖一层透明层：点一下 = 我们自己给焦点弹键盘，
                // 长按 = 进语音；一旦有焦点/有内容，这层就撤掉，输入框恢复系统原生行为。
                // quickVoiceActive 期间这层必须留着 —— 手势挂在它身上，中途拆了录音就停不下来。
                // 挂着动作芯片时也不盖：盖了会把「点芯片删除」吃掉；此时长按快捷语音让位，
                // 右侧的麦克风按钮照常可用。
                .overlay {
                    if quickVoiceActive ||
                        (!voiceMode && !inputFocused && chat.chipAction == nil &&
                         chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { inputFocused = true }
                            .gesture(quickVoiceGesture)
                    }
                }
                rightButton
            }
            // 输入栏下不放**常驻**提示文字（用户点名两轮删干净）——
            // 落区怎么用的说明在按住后的浮层里。唯一的例外是挂芯片的瞬时态：
            // 批次 005 稿在这里给一行 faint 说明灰字占位是什么、芯片怎么删。
            if chat.chipAction != nil, !voiceMode {
                Text("灰字是要说清的东西，敲字即替换。点芯片去掉它。")
                    .font(UmbraFont.sans(11.5, .w400))
                    .foregroundColor(UmbraColor.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 7)
            }
        }
        .padding(.horizontal, UmbraMetric.sp4)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(UmbraColor.bg.opacity(0.94))
        .overlay(alignment: .top) {
            Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
        }
    }

    /// 灵感带过来的来源横幅：贴在输入条上方，说明芯片和草稿是替用户填好的。
    /// 「知道了」手动收；直接发送也会随 send() 一起消失 —— 两条路都不留残影。
    private func ideaBannerView(_ text: String) -> some View {
        HStack(spacing: 8) {
            UmbraIcon(d: UmbraIconPath.bulb, size: 14, strokeWidth: 1.9)
            Text(text)
                .font(UmbraFont.sans(12.5, .w400))
                .lineSpacing(12.5 * 0.45)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { chat.ideaBanner = nil } label: {
                Text("知道了")
                    .font(UmbraFont.sans(12.5, .w600))
                    .padding(.horizontal, 4)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(UmbraColor.orangeText)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UmbraColor.orangeSoft))
        .padding(.bottom, 8)
    }

    /// 芯片占位 > 会话占位：挂着动作时灰字提示该补什么参数（稿：「金额 分类 备注」这类）。
    private var placeholderText: String {
        if let a = chat.chipAction { return a.params }
        return isAssistant ? "说点什么，敲 / 用快捷动作" : "对「\(title)」说点什么，敲 / 用快捷动作"
    }

    private var textField: some View {
        HStack(spacing: 7) {
            if let a = chat.chipAction {
                SlashChipView(action: a) { chat.chipAction = nil }
            }
            TextField(placeholderText,
                      text: $chat.draft, axis: .vertical)
                .font(UmbraFont.sans(15.5, .w400))
                .foregroundColor(UmbraColor.text)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                // **没有** submitLabel(.send)：axis:.vertical 的输入框里回车是换行，
                // 系统不会触发 onSubmit。把键盘上那个键标成「发送」却按了只换行，
                // 比标着「换行」更糟。发送统一走右边那个按钮。
        }
        .padding(.leading, UmbraMetric.sp4)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(UmbraColor.card))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
        )
    }

    /// 快捷语音（设计稿 areaDown）：输入框**没焦点、没内容**时长按它 0.48s，
    /// 直接切语音态并开录 —— 按住不放接着说、松手就发，省掉「先点麦克风再按住」两步。
    /// 挂在 composer 里那层**条件透明层**上（有焦点/有内容时该层不存在）：
    /// 手势压在 UIKit 输入框上会吃掉「点一下弹键盘」，所以点按也由那层自己转发成焦点。
    private var quickVoiceGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.48)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                switch value {
                case .first:
                    // ⚠️ 这里**不能**开录：LongPressGesture 的 value 手指一按下就是 true
                    //（它表示「正在按着」，不是「长按已成立」）。之前在 .first(true) 里开录，
                    // 结果点一下输入框就直接进语音（实机复现）。真正的「0.48s 长按成立」
                    // 是序列推进到 .second 的那一刻。
                    break
                case .second(true, let drag):
                    // 长按成立。第一次进来启动录音，之后每次带坐标就更新落区。
                    if !quickVoiceActive {
                        guard !voiceMode else { return }
                        quickVoiceActive = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        voiceMode = true
                        rec.start()
                    }
                    // 按住期间照常做落区判定：上滑左取消、右转文字，和按「按住 说话」一致。
                    if let g = drag { rec.zone = zone(at: g.location) }
                default:
                    break
                }
            }
            .onEnded { value in
                guard quickVoiceActive else { return }
                quickVoiceActive = false
                if case .second(true, let drag) = value, let g = drag {
                    finishRecording(rec.stop(zone: zone(at: g.location)))
                } else {
                    // 长按刚认定就松手（没产生拖拽事件）：手指还在输入栏上，按「发送」区收尾。
                    finishRecording(rec.stop(zone: .send))
                }
            }
    }

    /// 「按住 说话」。用 minimumDistance 0 的拖拽手势来同时拿到「按下」和「手指位置」——
    /// LongPressGesture 拿不到移动中的坐标，而落区判定要靠坐标。
    private var holdBar: some View {
        HStack(spacing: 7) {
            UmbraIcon(d: UmbraIconPath.mic, size: 16, strokeWidth: 1.9)
            Text(rec.active ? "正在说话…" : "按住 说话").font(UmbraFont.sans(15, .w560))
        }
        .foregroundColor(rec.active ? UmbraColor.orangeText : UmbraColor.muted)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 36)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(rec.active ? UmbraColor.orangeSoft : UmbraColor.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(rec.active ? UmbraColor.orange : UmbraColor.border, lineWidth: UmbraMetric.borderW)
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { g in
                    if !rec.active { rec.start() }
                    rec.zone = zone(at: g.location)
                }
                .onEnded { g in
                    finishRecording(rec.stop(zone: zone(at: g.location)))
                }
        )
    }

    /// 落区判定。以浮层里两个圆钮的**实测全局 frame** 为准（外扩 14pt 容差）——
    /// 一开始按屏幕比例算 y 阈值，量的是内容区高度、比的却是全局坐标，
    /// 阈值整体偏高，手指压在按钮上反而落进「发送」区（用户实测：要划到按钮上方才触发）。
    private func zone(at p: CGPoint) -> UmbraHoldRecorder.Zone {
        let cancelF = rec.cancelZoneFrame
        let textF = rec.textZoneFrame
        if !cancelF.isEmpty, !textF.isEmpty {
            if cancelF.insetBy(dx: -14, dy: -14).contains(p) { return .cancel }
            if textF.insetBy(dx: -14, dy: -14).contains(p) { return .text }
            // 按钮圈再往上仍按左右分半判：上滑本来就不要求精确压到圈上。
            if p.y < cancelF.minY {
                let w = UIScreen.main.bounds.width
                if p.x < w * 0.382 { return .cancel }
                if p.x > w * 0.618 { return .text }
            }
            return .send
        }
        // 浮层第一帧还没量到 frame 时的兜底：整屏比例（设计稿 393×852 的取值）。
        let b = UIScreen.main.bounds
        if p.y > b.height * 0.868 { return .send }
        if p.x < b.width * 0.382 { return .cancel }
        if p.x > b.width * 0.618 { return .text }
        return .send
    }

    private func finishRecording(_ result: UmbraHoldRecorder.Result) {
        switch result {
        case .send(let t):
            chat.draft = t
            chat.send()
        case .toText(let t):
            // 文字已经出现在输入框里，结果一目了然 —— 不再弹 toast 挡视线（用户点名）。
            chat.draft = t
            voiceMode = false
        case .cancel:
            // 取消就是取消，浮层收掉即是反馈，不弹 toast。
            break
        case .tooShort:
            router.showToast("说话时间太短，没听清")
        case .unavailable:
            router.showToast("麦克风或语音识别不可用，去系统设置里开一下")
        }
    }

    /// 右侧按钮的三态：语音态=键盘（回到打字）；有草稿=发送；空草稿=麦克风。
    private var rightButton: some View {
        let hasDraft = !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let icon = voiceMode ? UmbraIconPath.keyboard : (hasDraft ? UmbraIconPath.send : UmbraIconPath.mic)
        let bg = voiceMode ? UmbraColor.orangeSoft : (hasDraft ? UmbraColor.orange : UmbraColor.chip)
        let fg = voiceMode ? UmbraColor.orangeText : (hasDraft ? Color.white : UmbraColor.muted)
        let bc = voiceMode ? UmbraColor.orange : (hasDraft ? UmbraColor.orange : UmbraColor.border)
        return Button {
            if voiceMode {
                voiceMode = false
                inputFocused = true          // 回到打字态就把键盘叫回来，少一次点击
            } else if hasDraft {
                chat.send()                  // 发完**不收键盘** —— IM 里都是连着打下一句
            } else {
                inputFocused = false         // 切语音前先收键盘，否则浮层被键盘顶掉一半
                voiceMode = true
            }
        } label: {
            UmbraIcon(d: icon, size: 19, strokeWidth: hasDraft && !voiceMode ? 2.4 : 1.9)
                .foregroundColor(fg)
                .frame(width: 36, height: 36)
                .background(Circle().fill(bg))
                .overlay(Circle().strokeBorder(bc, lineWidth: UmbraMetric.borderW))
                // 36 够不到 44：靠透明外框撑触达区，不把按钮画大。
                // 外框对齐到底：HStack 按 .bottom 对齐的是这个 44 外框，
                // 圆钮居中的话会比输入框底高出 4pt（实机看得出来）。
                .frame(width: UmbraMetric.tapMin, height: UmbraMetric.tapMin, alignment: .bottom)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(UmbraMotion.tint, value: hasDraft)
    }

    // MARK: - 浮层



    /// 「复制聊天」的内容。只导出有文字的块 —— 卡片（确认、问答、任务）复制成文本没有意义，
    /// 拼一堆「[任务进度卡]」占位反而让粘出来的东西没法用。
    private func transcript() -> String {
        chat.blocks.compactMap { b -> String? in
            switch b {
            case .user(let u): return "我：\(u.text)"
            case .assistant(let a): return a.text.isEmpty ? nil : "秘书：\(a.text)"
            case .device(_, let t, _): return "\(title)：\(t)"
            case .note(let n): return n.text
            default: return nil
            }
        }.joined(separator: "\n\n")
    }
}

// MARK: - 气泡形状
//
// 我方 16 16 4 16（右下收角），对方 16 16 16 4（左下收角）。
// 用 Path 手画而不是 cornerRadius：SwiftUI 到 iOS 17 才有分角圆角。
struct UmbraBubbleShape: Shape {
    var mine: Bool
    private let big: CGFloat = 16
    private let small: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        // 顺时针：左上 → 右上 → 右下 → 左下
        let tl = big, tr = big
        let br = mine ? big : small
        let bl = mine ? small : big
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tr),
                       control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - br, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - bl),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tl, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// 流式光标。1 秒一次硬闪（steps(1)），不是渐隐 —— 渐隐看起来像呼吸灯，
/// 而这里要表达的是「还在往外吐字」。
struct UmbraBlinkCaret: View {
    @State private var on = true
    var body: some View {
        Rectangle()
            .fill(UmbraColor.orange)
            .frame(width: 7, height: 16)
            .opacity(on ? 1 : 0)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    on.toggle()
                }
            }
    }
}

/// 占位气泡里的三点。7pt 圆点、`--muted`、1.2s 一轮，三颗错开 .2s / .4s（稿的取值）。
/// 用 `repeatForever` 的隐式动画而不是逐帧 Task：三颗点各自跑一条 CA 动画，
/// 交给系统去插值，比在主线程上定时改 @State 省事也不会掉帧。
struct UmbraThinkingDots: View {
    @State private var bob = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(UmbraColor.muted)
                    .frame(width: 7, height: 7)
                    .offset(y: bob ? -3 : 0)
                    .animation(.easeInOut(duration: 0.6)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.2), value: bob)
            }
        }
        // onAppear 里翻一次开关把三条动画一起点着 —— 初始值就设 true 的话首帧没有变化，
        // repeatForever 不会启动（SwiftUI 的动画要有「值变了」这个事件）。
        .onAppear { bob = true }
    }
}

// MARK: - 任务状态映射

extension UmbraStatus {
    /// 服务端任务/操控 status 字符串 → 状态枚举。认不出来的一律当「执行中」，
    /// 不要新造一档 —— 界面上多一个没人认识的状态比暂时显示执行中更糟。
    init(taskStatus: String) {
        switch taskStatus {
        case "done", "succeeded", "success": self = .done
        case "failed", "error": self = .failed
        case "awaiting_confirm": self = .awaitingReview   // 操控停下来等你授权（进度卡琥珀档）
        case "suspended", "paused": self = .suspended
        case "pending", "queued": self = .pending
        case "cancelled", "canceled", "stopped": self = .cancelled
        default: self = .running
        }
    }
}
