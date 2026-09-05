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
import Photos
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
    /// 应用内图片预览器。**一个 State 管两种形态** —— 单张（任务产出图）和一条消息里的
    /// 那一组（批次 011 ③）。不拆成两个 @State + 两个 fullScreenCover：同一层挂两个
    /// cover，SwiftUI 只有最后挂的那个稳定生效，先挂的会静默失效（产出图就再也点不开了）。
    @State private var viewer: UmbraViewerGroup?
    /// 待发的图（输入框上方那条）。发出去就清空。
    @State private var pending: [ChatPendingImage] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false
    /// 「点被引用的那块回到原消息」：装被引消息的服务端 id，`messages` 里滚过去后清空。
    /// 不直接在 userBubble 里滚 —— ScrollViewReader 的 proxy 只在 `messages` 作用域里拿得到。
    @State private var jumpTo: Int?
    /// 刚跳到的那个块的 id：给它套一圈 orange-soft 的 halo 闪 1.4 秒，
    /// 不闪的话滚过去了用户也不知道到底是哪一条（PC 端同样处理）。
    @State private var flashBlockId: String?

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
        .umbraImageViewerGroup(group: $viewer)
        .chatImagePickers(showPhotos: $showPhotos, showCamera: $showCamera, showFiles: $showFiles,
                          remaining: ChatImageMetric.maxCount - pending.count) { takeImages($0) }
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
            // 待发条一出现 / 消失，输入区高度就变，最后一条消息会被盖住 —— 跟着回底。
            .onChange(of: pending.count) { _ in scrollToEnd(proxy) }
            .onChange(of: jumpTo) { id in
                guard let id else { return }
                jumpTo = nil
                jump(to: id, proxy)
            }
            .onAppear { scrollToEnd(proxy) }
        }
    }

    /// 回到被引用的那条：滚过去 + 闪一下 halo。找不到就说一声，**别默默什么都不做** ——
    /// 用户会以为这块不能点。「找不到」的主因其实是**还没翻到**（一次只拉 40 条），
    /// 所以文案不说「已经删除」，只说它不在已经加载的这一段里。
    private func jump(to serverId: Int, _ proxy: ScrollViewProxy) {
        guard let target = chat.blocks.first(where: { $0.serverId == serverId }) else {
            router.showToast(L("chat.quoteJumpMissing"))
            return
        }
        withAnimation(UmbraMotion.tint) { proxy.scrollTo(target.id, anchor: .center) }
        flashBlockId = target.id
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if flashBlockId == target.id { flashBlockId = nil }
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
        case .user, .image: return .trailing
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

        case .image(let img):
            imageRow(img)

        case .device(let did, let text, _):
            VStack(alignment: .leading, spacing: 5) {
                senderHeader(icon: UmbraIconPath.monitor, name: title, tint: UmbraColor.faint)
                plainLeftBubble(text, fill: UmbraColor.deviceBubble, blockId: did.uuidString)
            }

        case .task(let j):
            taskCard(j)
                .contextMenu { cardMenu("\(j.goal)（\(j.pct)%，\(UmbraStatus(taskStatus: j.status).label)）\(j.message)") }

        case .done(_, let goal, let results):
            doneCard(goal: goal, results: results)
                .contextMenu { cardMenu(L("chat.done", goal)) }

        case .confirm(let c):
            confirmCard(c)
                .contextMenu { cardMenu(c.summary) }

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
                    // 系统提示行也有服务端 id（取消收尾那条），所以它也可能是引用跳转的目标。
                    .overlay { if flashBlockId == n.id.uuidString { Capsule().stroke(UmbraColor.orangeSoft, lineWidth: 2) } }
                if let kept = ChatKeptTool.line(for: n.toolsRun) { keptToolsRow(kept) }
            }

        case .error(_, let text):
            errorCard(text)
        }
    }

    // MARK: - 长按菜单（批次 011 ②）
    //
    // ⚠️ 三处气泡上的 `.textSelection(.enabled)` 随这一批**撤掉了**：它和 `.contextMenu`
    // 抢同一个长按手势，压在文字字形上时系统文本选择会先赢，六项菜单只能在气泡内边距上
    // 才稳定弹出来 —— 而这一批的重点正是那六项。「复制」现在在菜单里，能力没丢。
    //
    // 按消息类型分档，和 PC 右键**同一张表**（`messageMenu.byKind`）：
    //   我发的 复制 · 引用 · 存为常用语 · 记为灵感 · 添加提醒 · 删除
    //   秘书的 复制 · 引用 · 记为灵感 · 添加提醒 · 删除（秘书的话不给「存为常用语」——
    //          常用语是「你常写的话」，存秘书的回复会让那个抽屉里混进一堆不是你会说的句子）
    //   失败的 重新发送（置顶）· 复制 · 删除
    //   卡  片 复制摘要（不给删除：卡片是流程的一部分，删了链路断）
    //   系统行 不接长按
    //
    // 用**系统 contextMenu** 而不是照稿自绘那个 208 宽的玻璃浮层：长按菜单是系统接管的位置
    // （抬起预览、模糊、触感、贴边避让、辅助功能全在里面），自绘一份等于把这些全部重做一遍 ——
    // 和「底栏用真·系统 tab bar」「列表用系统 .swipeActions」是同一条铁律。稿上那些取值
    //（208 / 圆角 16 / 玻璃 / 44 行高 / 图标在右）本来就是系统菜单的样子。
    // 稿②的「选中态 halo」也随之不需要：系统菜单会把气泡抬起来，那就是选中态。

    /// 一条图片消息：气泡 + 上传中的字节行 / 失败行。
    private func imageRow(_ img: ChatBlock.ImageBlock) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: UmbraMetric.sp5)
            VStack(alignment: .trailing, spacing: 4) {
                ChatImageBubble(block: img) { openImage(img, at: $0) }
                    .overlay { halo(img.id.uuidString, mine: true) }
                    // 上传中不挂菜单：它自带「取消上传」，再叠一层菜单是同一件事两个入口
                    //（`messageMenu.byKind` 里也只有 image / imgFailed 两档，没有「上传中」）。
                    .modifier(UmbraConditionalMenu(on: img.state != .uploading &&
                                                       img.state != .awaitingReceipt) { imageMenu(img) })
                if img.state == .uploading { uploadingRow(img) }
                if img.state == .awaitingReceipt { awaitingRow }
                if img.state == .failed { imageFailedRow(img) }
            }
        }
    }

    /// 上传中那一行：「正在上传 · 1.8 MB / 2.9 MB」+「取消上传」。
    /// 字节是**整条**的（环画在每一格上，说的是那一张；这一行说的是这一条）。
    private func uploadingRow(_ img: ChatBlock.ImageBlock) -> some View {
        HStack(spacing: 6) {
            Text(L("chat.uploading", umbraMB(img.sentBytes), umbraMB(img.totalBytes)))
                .font(UmbraFont.sans(11.5, .w400))
                .foregroundColor(UmbraColor.faint)
                .fixedSize()
            failedAction(L("chat.img.cancelUpload"), weight: .w400, tint: UmbraColor.muted) {
                dropImages(img)
            }
        }
        .frame(minHeight: UmbraMetric.tapMin)
    }

    /// 图都传完、WS 也送出去了，在等服务端回执。**这一档不给「取消上传」** ——
    /// 服务端已经有这条了，撤掉本地只会让用户再发一次，变成两条。
    private var awaitingRow: some View {
        Text(L("chat.img.sending"))
            .font(UmbraFont.sans(11.5, .w400))
            .foregroundColor(UmbraColor.faint)
            .fixedSize()
    }

    /// 图片没发出去那一行。和文字那条同一个形，只是原因由上传链路给。
    private func imageFailedRow(_ img: ChatBlock.ImageBlock) -> some View {
        HStack(spacing: 6) {
            UmbraIcon(d: UmbraIconPath.alertOctagon, size: 14, strokeWidth: 2)
                .foregroundColor(UmbraColor.danger)
            Text(img.failReason.isEmpty ? L("chat.uploadFailed") : img.failReason)
                .font(UmbraFont.sans(12.5, .w400))
                .foregroundColor(UmbraColor.danger)
                .fixedSize(horizontal: false, vertical: true)
            failedAction(L("chat.menu.resend"), weight: .w600, tint: UmbraColor.danger) {
                chat.retryImages(blockId: img.id)
            }
        }
        .frame(minHeight: UmbraMetric.tapMin)
    }

    /// 撤掉一条还没发成的图片消息，并把本地那几张**放回待发条** ——
    /// 图还在本地，让用户再去相册翻一遍说不过去（PC 端同一条行为）。
    private func dropImages(_ img: ChatBlock.ImageBlock) {
        let back = chat.cancelImageUpload(blockId: img.id)
        guard !back.isEmpty else { return }
        let room = ChatImageMetric.maxCount - pending.count
        pending.append(contentsOf: back.prefix(max(0, room)).map { ChatPendingImage(data: $0) })
        // 块已经撤掉了，条里又放不下 —— 不说一声的话图就一声不吭地没了。
        if back.count > room { router.showToast(L("chat.img.tooMany")) }
    }

    /// 图片消息的长按菜单（`messageMenu.byKind.image` / `.imgFailed`）。
    /// 失败的那条砍到三项、「重新发送」置顶；正常的五项。
    @ViewBuilder
    private func imageMenu(_ img: ChatBlock.ImageBlock) -> some View {
        if img.state == .failed {
            Button { chat.retryImages(blockId: img.id) } label: {
                Label(L("chat.menu.resend"), systemImage: "arrow.clockwise")
            }
            // 一张都没传成的时候不给「查看大图」—— 服务端上还没有这张，点了只会静默无反应。
            if !img.atts.isEmpty {
                Button { openImage(img, at: 0) } label: {
                    Label(L("chat.menu.viewImage"), systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            // 删除是**丢掉**，不回填待发条：点了红色「删除」却看见九张图原样回到输入框上方，
            // 观感上像没删掉。回填只归「取消上传」。
            Button(role: .destructive) { chat.cancelImageUpload(blockId: img.id) } label: {
                Label(L("chat.menu.delete"), systemImage: "trash")
            }
        } else {
            Button { openImage(img, at: 0) } label: {
                Label(L("chat.menu.viewImage"), systemImage: "arrow.up.left.and.arrow.down.right")
            }
            // 标签**按张数分档**（批次 016 `messageMenu.byKind.imageLabelWhy`）：
            // 多图时「复制第一张」「存 5 张到相册」。
            // 两项行为不一致是**系统能力不一致**（剪贴板单槽、相册没这个限制），改不了；
            // 修法不是改行为，是让标签自己说清对象 —— 不让人按完才发现只复制了一张。
            // 通则：菜单项行为有边界时，边界写进标签，不写进说明文字，也不靠人试一次学会。
            Button { copyImage(img) } label: {
                Label(img.count > 1 ? L("chat.menu.copyFirstImage") : L("chat.menu.copyImage"),
                      systemImage: "doc.on.doc")
            }
            actionQuote(id: img.serverId, role: "user", text: L("chat.quoteImage", img.count))
            Button { saveImageToAlbum(img) } label: {
                Label(img.count > 1 ? L("chat.menu.saveNToAlbum", img.count) : L("chat.menu.saveToAlbum"),
                      systemImage: "square.and.arrow.down")
            }
            actionDelete(serverId: img.serverId)
        }
    }

    /// 点开这一条里的第 i 张。**带上整条的图** —— 预览器里左右切的就是这一条里的图。
    private func openImage(_ img: ChatBlock.ImageBlock, at i: Int) {
        let items = img.atts.enumerated().compactMap { j, fid -> UmbraViewerItem? in
            guard let url = HTTPService.shared.moneyFileURL(fid) else { return nil }
            return UmbraViewerItem(url: url, name: L("chat.img.nth", j + 1))
        }
        guard !items.isEmpty else { return }
        viewer = UmbraViewerGroup(items: items, start: min(i, items.count - 1))
    }

    /// 复制图片：进系统剪贴板的是**图本身**不是链接 —— 粘到别处要能直接出图。
    /// 本地还留着原图就用本地那份（不用等下载）；只有 file_id 的现下一次。
    ///
    /// **只复制第一张**，而「存到相册」存整条 —— 016 裁定：行为不改，**改标签**。
    /// 两者不一致是系统能力不一致（剪贴板单槽、相册没这个限制），把「存相册」也退化成
    /// 存一张是纯损失。所以菜单项和吐司都按张数说清对象。
    private func copyImage(_ img: ChatBlock.ImageBlock) {
        // 多图时吐司也说「第一张」—— 菜单说了一遍，做完再确认一遍，
        // 免得人以为九张都进剪贴板了、粘出来只有一张时怀疑是粘贴的问题。
        let done = img.count > 1 ? L("chat.img.copiedFirst") : L("chat.img.copied")
        if let d = img.data.first, let ui = UIImage(data: d) {
            UIPasteboard.general.image = ui
            router.showToast(done)
            return
        }
        guard let fid = img.atts.first, let url = HTTPService.shared.moneyFileURL(fid) else { return }
        Task {
            guard let d = try? await URLSession.shared.data(from: url).0,
                  let ui = UIImage(data: d) else {
                router.showToast(L("chat.img.copyFailed")); return
            }
            UIPasteboard.general.image = ui
            router.showToast(done)
        }
    }

    /// 存到相册。**这一条里的图全存** —— 菜单挂在整条消息上，只存第一张说不通
    ///（「复制图片」只取第一张是另一回事：剪贴板实际只有一格）。
    ///
    /// ⚠️ 不用 `UIImageWriteToSavedPhotosAlbum`：它是异步的、而且**不回报成败**。
    /// 用户在权限弹窗上点「不允许」时一张都存不进去，吐司却照样说「已存 N 张」。
    /// PhotoKit 的 performChanges 能 await 到真实结果。
    private func saveImageToAlbum(_ img: ChatBlock.ImageBlock) {
        Task {
            // 显式要一次权限：只拦 .denied 的话，.notDetermined 会靠 performChanges
            // 隐式弹框，用户点「不允许」之后抛的错被当成「图片取不下来」——
            // 文案在甩锅给网络，人会去查 WiFi 而不是去开权限。.restricted 同理。
            var st = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if st == .notDetermined { st = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
            guard st == .authorized || st == .limited else {
                router.showToast(L("chat.img.noAlbumPermission")); return
            }
            var ok = 0
            for (j, fid) in img.atts.enumerated() {
                var bytes: Data? = j < img.data.count ? img.data[j] : nil
                if bytes == nil, let url = HTTPService.shared.moneyFileURL(fid) {
                    bytes = try? await URLSession.shared.data(from: url).0
                }
                guard let d = bytes, let ui = UIImage(data: d) else { continue }
                // 用 completion 版包一层，不用 async 重载：那个重载在不同 SDK 上
                // 可能是 `async throws` 也可能是 `async throws -> Bool`，后者在
                // success == false 且不抛错时会被误记成功。这里拿到的就是那个 Bool。
                let done: Bool = await withCheckedContinuation { cont in
                    PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAsset(from: ui)
                    } completionHandler: { success, _ in
                        cont.resume(returning: success)
                    }
                }
                // 逐张记账：三张里成功两张要说「已存 2 张」，不能整批当失败。
                if done { ok += 1 }
            }
            router.showToast(ok > 0 ? L("chat.img.saved", ok) : L("chat.img.saveFailed"))
        }
    }

    /// 选图回来：超限的那张也收进条里（标红说明），**不吞掉** ——
    /// 吞掉的话用户会以为自己没选中。
    private func takeImages(_ datas: [Data]) {
        let room = ChatImageMetric.maxCount - pending.count
        guard room > 0 else { router.showToast(L("chat.img.tooMany")); return }
        pending.append(contentsOf: datas.prefix(room).map { ChatPendingImage(data: $0) })
        if datas.count > room { router.showToast(L("chat.img.tooMany")) }
    }

    /// 「+」：三入口的 action sheet（`imageMessage.entry.ios`）。
    private func askAddImage() {
        guard pending.count < ChatImageMetric.maxCount else {
            router.showToast(L("chat.img.tooMany")); return
        }
        router.present(UmbraSheet(
            title: L("chat.img.sheetTitle"), subtitle: L("chat.img.sheetSub"),
            items: [
                UmbraSheetItem(label: L("chat.attach.album")) { showPhotos = true },
                UmbraSheetItem(label: L("chat.attach.camera")) {
                    // 模拟器 / 无摄像头设备直说，不给一个点了闪退的入口。
                    if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
                    else { router.showToast(L("chat.img.noCamera")) }
                },
                UmbraSheetItem(label: L("chat.attach.file")) { showFiles = true },
            ]))
    }

    /// 我方气泡的菜单。发失败的那条按 `messageMenu.byKind.failed` 砍到三项、「重新发送」置顶
    ///（那条还没送出去，引用和存起来都无从谈起，而你长按它十次有九次就是为了重发）。
    @ViewBuilder
    private func myMenu(_ u: ChatBlock.UserBlock) -> some View {
        if u.failed {
            actionResend(u)
            actionCopy(u.text)
            // 服务端上根本没有这条，只是本地移除 —— 不走「移入回收站 30 天」那套确认。
            Button(role: .destructive) {
                chat.dropLocal(blockId: u.id.uuidString)
            } label: {
                Label(L("chat.menu.delete"), systemImage: "trash")
            }
        } else {
            actionCopy(u.text)
            actionQuote(id: u.serverId, role: "user", text: u.text)
            actionPhrase(u.text)
            actionIdea(u.text)
            actionRemind(u.text)
            actionDelete(serverId: u.serverId)
        }
    }

    /// 引用条与被引块上写谁说的。设备说的话既不是「我」也不是「秘书」——
    /// 写成秘书就是把另一台机器说的话安到秘书头上。
    private func quoteWho(_ role: String) -> String {
        switch role {
        case "user": return L("chat.quoteMe")
        // 设备的话**不能**无脑用 title：服务端不带 conversation 时 device_message 会落进
        // 主会话，那里的 title 就是「秘书」—— 正好把另一台机器说的话安到秘书头上。
        case "device": return isAssistant ? L("chat.quoteWho.device") : title
        default: return L("chat.conv.secretary")
        }
    }

    /// 秘书 / 设备气泡的菜单。role 决定引用条上写谁说的。
    @ViewBuilder
    private func botMenu(_ text: String, serverId: Int?, role: String = "assistant") -> some View {
        actionCopy(text)
        actionQuote(id: serverId, role: role, text: text)
        actionIdea(text)
        actionRemind(text)
        // 设备发来的消息不归我们删（它在服务端也不是「我的一条消息」），所以不出这一项。
        actionDelete(serverId: serverId, settling: role != "device")
    }

    /// 结构化消息（任务卡 / 确认卡 / 完成卡）只给「复制摘要」一项。
    /// 「打开对应任务」作废（`messageMenu.cardOneItem`：独立确认卡里没有 task_id，
    /// 不为一个菜单项让服务端加字段）。
    private func cardMenu(_ summary: String) -> some View {
        Button {
            UIPasteboard.general.string = summary
            router.showToast(L("chat.copied"))
        } label: {
            Label(L("chat.menu.copySummary"), systemImage: "doc.on.doc")
        }
    }

    // MARK: 菜单里的单个动作

    private func actionCopy(_ text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
            router.showToast(L("chat.copied"))
        } label: {
            Label(L("chat.copy"), systemImage: "doc.on.doc")
        }
    }

    private func actionResend(_ u: ChatBlock.UserBlock) -> some View {
        Button {
            chat.resendFailed(blockId: u.id.uuidString)
        } label: {
            Label(L("chat.menu.resend"), systemImage: "arrow.clockwise")
        }
    }

    /// 引用。**只在能打字的会话里给** —— 引用条挂在输入框上方，只读的设备会话里
    /// 挂上去也发不出去。（PC 端的做法是切回主会话，那会把人从当前会话拽走，不搬。）
    @ViewBuilder
    private func actionQuote(id: Int?, role: String, text: String) -> some View {
        if inputEnabled {
            Button {
                voiceMode = false          // 语音态没有输入框，引用条挂上去看不见
                chat.quoteMessage(id: id, role: role, text: text)
                inputFocused = true
            } label: {
                Label(L("chat.menu.quote"), systemImage: "text.quote")
            }
        }
    }

    /// 存为常用语。取前 12 个字当名字（和秘书侧 add_phrase 同规则）；
    /// 内容一模一样的已经有了就不重复存，并说清楚是「已经有了」而不是「存失败了」。
    private func actionPhrase(_ text: String) -> some View {
        Button {
            let store = PhraseStore.shared
            if store.items.contains(where: { $0.content == text }) {
                router.showToast(L("chat.phraseExists"))
                return
            }
            // 取第一行的前 12 个字当名字（和秘书侧 add_phrase 同规则）。
            // trim 要含换行：.whitespaces 不含 \n，全是空行的正文会存出一条名字是几个换行的常用语。
            // 兜底那一支也要用 **trim 过的**全文：split 只跳过空子串，`"   "` 不是空串，
            // 于是「首行全是空格」的正文会绕过上面这次 trim，名字里带着前导空白存进去。
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let head = (text.split(separator: Character("\n")).first.map { String($0) } ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = String((head.isEmpty ? body : head).prefix(12))
            guard !name.isEmpty else { return }   // 全是空白的正文不值得存一条名字为空的常用语
            store.add(name: name, content: text, keyword: nil)
            router.showToast(L("chat.phraseSaved"))
        } label: {
            Label(L("chat.menu.phrase"), systemImage: "text.badge.plus")
        }
    }

    private func actionIdea(_ text: String) -> some View {
        Button {
            Task {
                let ok = await HTTPService.shared.createInspiration(
                    raw: text, title: "", summary: "", tags: [])
                await MainActor.run {
                    router.showToast(ok ? L("chat.ideaSaved") : L("chat.ideaSaveFailed"))
                    if ok { NotificationCenter.default.post(name: .inspirationChanged, object: nil) }
                }
            }
        } label: {
            Label(L("chat.menu.idea"), systemImage: "lightbulb")
        }
    }

    /// 添加提醒：把正文预填进**新建提醒页**，让用户自己补时间。
    /// 原来是直接建一条「一小时后」的 —— 那个时间是我们猜的，猜错了用户还得进去改。
    /// 走 ReminderStore 已有的模板通道（路由只认 id，传不了草稿，见 stashCloneTemplate）。
    private func actionRemind(_ text: String) -> some View {
        Button {
            ReminderStore.shared.stashCloneTemplate(
                UmbraReminder(id: UUID().uuidString,
                              text: String(text.prefix(200)),
                              at: Date().addingTimeInterval(3600),
                              source: "聊天"))
            // 通知权限**不在这儿要** —— 用户还没写完、可能马上就点取消。
            // 新建页的 save() 里已经在正确时机要了（「这时候用户正想让它响，最容易被同意」）。
            router.jump(.remEdit(id: nil))
        } label: {
            Label(L("chat.menu.remind"), systemImage: "bell")
        }
    }

    /// 删除。跨端的，必须先问一句（`messageMenu.deleteCopy` 的原文）。
    ///
    /// `settling`：这条**本该**有服务端 id、只是还没拿到（取消收尾之后那一轮里我发的那条 ——
    /// `reply_cancelled` 不带 `user_message_id`，服务端补上之前认不到）。这种不能静默少一项：
    /// 「全场唯一一条菜单不一样的消息」用户解释不了，会当成卡了。所以照样给「删除」，
    /// 点了吐一句实话。服务端补上 `user_message_id` 之后，这个分支连同文案一起删。
    /// `settling = false` 的（设备发来的消息）本来就不归我们删，那才该静默不出。
    @ViewBuilder
    private func actionDelete(serverId: Int?, settling: Bool = true) -> some View {
        if serverId == nil, settling {
            Button(role: .destructive) {
                router.showToast(L("chat.msgSettling"))
            } label: {
                Label(L("chat.menu.delete"), systemImage: "trash")
            }
        } else if let sid = serverId {
            Button(role: .destructive) {
                router.confirm(UmbraAlert(
                    title: L("chat.delMsgTitle"),
                    body: L("chat.delMsgBody"),
                    confirmLabel: L("chat.menu.delete"),
                    confirmDestructive: true,
                    onConfirm: {
                        // 本地不抢着删：服务端广播 message_deleted 会回来（不排除发起端）。
                        // 抢着删的话，服务端拒绝时就留下一条「看起来删了其实还在」的消息。
                        if !chat.deleteMessage(serverId: sid) {
                            router.showToast(L("chat.notConnected"))
                        } else {
                            router.showToast(L("chat.deleted"))
                        }
                    }))
            } label: {
                Label(L("chat.menu.delete"), systemImage: "trash")
            }
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
            VStack(alignment: .trailing, spacing: 2) {
                VStack(alignment: .leading, spacing: 6) {
                    // 被引用的内容进**气泡顶部**（不是挂在气泡外面）：它是这条消息的一部分，
                    // 挂在外面会被读成两条消息（批次 011 ② 明确改的一处）。
                    if let q = u.quote { quotedBlock(q) }
                    Text(u.text)
                        .font(UmbraFont.sans(15.5, .w400))
                        .foregroundColor(UmbraColor.text)
                        .lineSpacing(15.5 * 0.5)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(UmbraBubbleShape(mine: true).fill(UmbraColor.userBubble))
                // 发失败的气泡压暗（稿 .72），和「送出去了」区分开。
                .opacity(u.failed ? 0.72 : 1)
                .overlay { halo(u.id.uuidString, mine: true) }
                .contextMenu { myMenu(u) }
                if u.failed { failedRow(u) }
            }
        }
    }

    /// 刚跳到的那条闪一圈 orange-soft。不闪的话滚过去了也不知道到底是哪一条。
    @ViewBuilder
    private func halo(_ blockId: String, mine: Bool) -> some View {
        if flashBlockId == blockId {
            UmbraBubbleShape(mine: mine).stroke(UmbraColor.orangeSoft, lineWidth: 2)
        }
    }

    /// 气泡顶部的被引用块（`messageQuote.inBubble`）：`--chip` 底 + 左 2px 橙条，
    /// 两行截断，点它回到原消息。没有 id 的（对方端刚广播过来、还没拉历史）不给点 ——
    /// 点了也跳不过去，给个能点的样子只会让人点两次。
    private func quotedBlock(_ q: ChatQuote) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Capsule().fill(UmbraColor.orange).frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(quoteWho(q.role))
                    .font(UmbraFont.sans(11.5, .w600))
                    .foregroundColor(UmbraColor.orangeText)
                Text(q.text)
                    .font(UmbraFont.sans(12.5, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineSpacing(12.5 * 0.5)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            // ⚠️ 这里**不能**挂 .frame(maxWidth: .infinity)：贪婪属性会一路上传给气泡，
            // 让它和外层的 Spacer 对半分屏宽 —— 就是 userBubble 顶上那段警告写的那个坑，
            // 表现为「引用了一条之后，回一个『好的』也画成半屏宽」。
        }
        // ⚠️ 这行 fixedSize 是**承重的**：左边那条竖条是弹性视图，去掉它之后外层给下来一个
        // 大高度提案时竖条会照单全收，整块引用被撑成半屏高。别「顺手清理」。
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UmbraColor.chip))
        .contentShape(Rectangle())
        .onTapGesture { if let id = q.id { jumpTo = id } }
    }

    /// 「没发出去」那一行（`replyCancel.textFailed`）：14px 描边 alert-octagon + 原因 + 动作。
    /// 错误三段式在这一行里齐了 —— 发生了什么 · 为什么 + 可点的钮。
    ///
    /// **原因照实分档，动作跟着分档**：没连上给两颗（重新发送 / 检查服务端），
    /// 服务端拒了只给重新发送 —— 服务端都回话了，再让人去检查地址是把人往错方向支。
    ///
    /// 图标走**通知家族**的 `alertOctagon`（八角），不是状态家族的 `xCircle` ——
    /// 015 已裁定这两颗不并：这一行是「一条要你处理的问题」（后面跟着原因和按钮），
    /// 任务卡上的圆叉是「这个对象的状态是失败」。
    private func failedRow(_ u: ChatBlock.UserBlock) -> some View {
        HStack(spacing: 6) {
            UmbraIcon(d: UmbraIconPath.alertOctagon, size: 14, strokeWidth: 2)
                .foregroundColor(UmbraColor.danger)
            Text(L(u.failure == .rejected ? "chat.sendFailed.rejected" : "chat.sendFailed.offline"))
                .font(UmbraFont.sans(12.5, .w400))
                .foregroundColor(UmbraColor.danger)
                .fixedSize()
            failedAction(L("chat.menu.resend"), weight: .w600, tint: UmbraColor.danger) {
                chat.resendFailed(blockId: u.id.uuidString)
            }
            // 没连上才给「检查服务端」：这一颗是把人送到能解决问题的地方去。
            if u.failure == .offline {
                failedAction(L("chat.menu.checkServer"), weight: .w400, tint: UmbraColor.muted) {
                    router.jump(.setConn)
                }
            }
        }
        // 行撑到真实的 44（`minTapTarget.siblingClearance`）：钮的热区整块落在行内，
        // 不再往上探进气泡、往下探进下一条的行距。见 failedAction 的注释。
        .frame(minHeight: UmbraMetric.tapMin)
    }

    /// 失败行里的行内文字动作。热区照 `minTapTarget` 撑到 44（tokens 点名：12.5px 字
    /// 配 13px 纵向 padding 只有 41，不够）。
    ///
    /// ⚠️ **不再用负边距把多出来的高度收掉**（`minTapTarget.siblingClearance`，批次 016）。
    /// 原来的写法是 `.frame(minHeight: 44)` + `.padding(.vertical, -13)`：行高不变，
    /// 但那 13pt 是**从上下邻居身上借的** —— 往上探进失败气泡的底部、往下探进下一条消息的行距。
    /// 而这一行在 SwiftUI 的绘制顺序里靠后，它赢：**长按失败气泡的下沿会变成点「重新发送」**。
    ///
    /// 现在的做法是设计侧给的：**把行撑到真实的 44 高**（见下面三个调用行的
    /// `.frame(minHeight: tapMin)`），钮在行里长满、居中，热区整块落在行内、零溢出。
    /// 代价是失败气泡下面那一行多出约 29pt —— 设计侧原话：「那就是一个 44pt 热区
    /// 真正的价钱，不要拿邻居去偿。」
    ///
    /// 这是同一个病的第三种壳（前两种：横向吃 flex gap、内层盖外层）。共同判据：
    /// **撑热区只能向留白借，不能向可点的东西借**；留白不够就把容器撑高。
    private func failedAction(_ title: String, weight: UmbraFont.Weight,
                              tint: Color, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(title)
                .font(UmbraFont.sans(12.5, weight))
                .foregroundColor(tint)
                .padding(.horizontal, 6)
                // **定尺 44**，不是 `maxHeight: .infinity`。
                // 贪婪写法在 ScrollView 里（高度提案是 nil）确实老实停在 44，
                // 但它把整行的尺寸范围变成 [44, ∞) —— 哪天这一行被放进一个会分配剩余高度的
                // 容器（非滚动的 VStack），它就会被拉长。定尺没有这个坑，行为也完全一样：
                // 行本身 minHeight 44，钮正好 44，热区不多不少。
                .frame(height: UmbraMetric.tapMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 设备气泡专用（秘书那条走 `aiBubbleBody`）。fill 用来区分说话人 —— 秘书和设备
    /// 都在左侧，不换色的话在设备会话里根本分不出哪句是秘书说的（用户点名）。
    /// 设备消息**没有服务端 id**，
    /// 所以它的菜单会自动少掉「删除」（`actionDelete` 里按 serverId 判）。
    private func plainLeftBubble(_ text: String, fill: Color, blockId: String?) -> some View {
        // 同 userBubble：宽度随内容，靠右侧 Spacer 留白，不用 maxWidth 撑满。
        HStack(spacing: 0) {
            UmbraMarkdownText(raw: text)
                .foregroundColor(UmbraColor.text)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(UmbraBubbleShape(mine: false).fill(fill))
                .overlay(UmbraBubbleShape(mine: false).stroke(UmbraColor.border, lineWidth: UmbraMetric.borderW))
                .overlay { if let bid = blockId { halo(bid, mine: false) } }
                .contextMenu { botMenu(text, serverId: nil, role: "device") }
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
                .background(Circle().fill(UmbraColor.card))
                .overlay(Circle().stroke(UmbraColor.border, lineWidth: UmbraMetric.borderW))
                // 热区**只往上下撑**（32 宽 × 44 高），横向就是视觉那 32。
                .frame(width: Self.stopDiameter, height: UmbraMetric.tapMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("chat.stopReply"))
        // 热区比视觉高一圈，用负边距抵掉，免得把气泡行撑高。跟着 tapMin 走，
        // 写死 -6 的话以后调 tapMin 这里会静默错位。
        //
        // ⚠️ **负边距只给纵向**（`rules.minTapTarget.negativeMarginAxis`，批次 015）：
        // 横向负边距会吃掉 HStack 的 spacing —— 这里左邻就是气泡（它自己带 contextMenu），
        // 原来四向 -6 撞上 spacing 8，只差 2pt 就叠到气泡上了；tapMin 哪天从 44 调到 48，
        // 这 2pt 就没了，而且叠上之后是**静默**的：人按气泡，停止钮把这一按吃掉。
        // 横向本来也不需要满 44（同一条 token 的原话），32 已经够按。
        .padding(.vertical, -(UmbraMetric.tapMin - Self.stopDiameter) / 2)
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
            }
            // 流式光标：7×16 橙块，1 秒硬闪一次（steps(1)，不是渐隐）。
            // 只在**已经有字**时闪：空气泡里一根光标看不出「它在想」，那一段归三点。
            if a.streaming, !a.text.isEmpty { UmbraBlinkCaret() }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(UmbraBubbleShape(mine: false).fill(UmbraColor.card))
        .overlay(UmbraBubbleShape(mine: false).stroke(UmbraColor.border, lineWidth: UmbraMetric.borderW))
        .overlay { halo(a.id.uuidString, mine: false) }
        // 条件必须在**修饰符外面**：挂着一个空 menu 的话，长按占位气泡照样会抬起 +
        // 模糊一整套系统预览，然后什么菜单项都没有。
        .modifier(UmbraConditionalMenu(on: !a.text.isEmpty) { botMenu(a.text, serverId: a.serverId) })
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
                // 单张也走同一个预览器（组里只有一项，翻页条自己不出）。
                viewer = UmbraViewerGroup(items: [UmbraViewerItem(url: u, name: name)], start: 0)
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
            if let q = chat.quote { quoteBar(q) }
            if !pending.isEmpty { ChatPendingStrip(items: $pending, onAdd: askAddImage) }
            HStack(alignment: .bottom, spacing: 8) {
                plusButton
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

    /// 输入框上方的引用条（`messageQuote.bar`）：左 2px 橙竖条 + 「引用 我 / 秘书」+ 摘要两行截断 + ×。
    /// 底走 `--card`（iOS 那一档），和输入栏的毛玻璃底分得开。
    @ViewBuilder
    private func quoteBar(_ q: ChatQuote) -> some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("chat.quoteWho", quoteWho(q.role)))
                    .font(UmbraFont.sans(11.5, .w600))
                    .foregroundColor(UmbraColor.orangeText)
                Text(q.text)
                    .font(UmbraFont.sans(12.5, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineSpacing(12.5 * 0.5)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                chat.quote = nil
            } label: {
                UmbraIcon(d: UmbraIconPath.x, size: 11, strokeWidth: 2.4)
                    .foregroundColor(UmbraColor.muted)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(UmbraColor.chip))
                    // 热区 22 宽 × 44 高：横向不撑（`minTapTarget.horizontalNot44` —— 横向撑
                    // 只能从左邻那两行引用文字身上抢）；纵向 **贴顶往下长**，视觉圆留在
                    // 原来的位置（HStack 是 .top 对齐的，圆本来就在顶上）。
                    //
                    // ⚠️ 后面那句负边距**去掉了**（`minTapTarget.siblingClearance`，批次 016）：
                    // 原来 `-11` 把占位收回 22，代价是热区上探 11pt —— 而引用条自己只有 8pt
                    // 纵向内衬，多出来的 3pt 探到条外面去了，还会被条的 clipShape 裁掉一截。
                    // 现在占位就是 22×44，条跟着长到至少 44+16=60。
                    // 引用只有一行时条会比以前高一截 —— 那就是一个 44pt 热区的价钱。
                    .frame(width: 22, height: UmbraMetric.tapMin, alignment: .top)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("chat.quoteClear"))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(UmbraColor.card))
        // strokeBorder 而不是 stroke：stroke 是压线画的，外侧一半会被下面的 clipShape 裁掉，
        // 1px 的边只剩 0.5px。
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(UmbraColor.borderSoft, lineWidth: UmbraMetric.borderW))
        // 左边那条 2px 橙竖条：压在圆角矩形左沿上，用 clipShape 收进圆角里。
        .overlay(alignment: .leading) {
            Rectangle().fill(UmbraColor.orange).frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, 2)
        .padding(.bottom, 8)
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
            // 走 sendPending 而不是 chat.send()：挂着待发的图时，图文要一起走
            // （图文分条，但同一次发送）。直接 send() 会把图落在条里。
            chat.draft = t
            // 被超限拦下时要切回打字态：语音态显示的是按住说话条，
            // 刚识别出来的那句话落在看不见的草稿里，用户会以为它丢了。
            if !sendPending() { voiceMode = false }
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

    /// 一次发送：先图后文（图文分条）。超限那张挡在这里 —— 它已经在条里标红说明了，
    /// 这一步只需要不让它混进去，不用再吐一次同样的话。
    @discardableResult
    private func sendPending() -> Bool {
        // 有超限的就**整条拦下**（图和文都不发），并点名是第几张 —— 和 PC 一致。
        // 「好的照发、超限的留在条里」看着更宽容，但会出现「三张全超限 + 草稿为空 →
        // 点发送什么都没发生」这种毫无反应的死角；而且文字先跑了、图还留着也很割裂。
        if let bad = pending.firstIndex(where: { $0.oversize }) {
            router.showToast(L("chat.img.oversize", bad + 1, umbraMB(pending[bad].bytes),
                               umbraMB(ChatImageMetric.maxBytes)))
            return false
        }
        if !pending.isEmpty {
            chat.sendImages(pending.map(\.data))
            pending = []
        }
        if !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chat.send() }
        return true
    }

    /// 输入框左侧那颗 36 圆钮「+」（`imageMessage.entry.ios`）。
    private var plusButton: some View {
        Button(action: askAddImage) {
            UmbraIcon(d: UmbraIconPath.plus, size: 19, strokeWidth: 1.9)
                .foregroundColor(UmbraColor.muted)
                .frame(width: 36, height: 36)
                .background(Circle().fill(UmbraColor.card))
                .overlay(Circle().strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW))
                // 同 rightButton：36 够不到 44，透明外框底对齐撑触达区。
                .frame(width: UmbraMetric.tapMin, height: UmbraMetric.tapMin, alignment: .bottom)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("chat.attach.add"))
    }

    /// 右侧按钮的三态：语音态=键盘（回到打字）；有草稿或待发的图=发送；都没有=麦克风。
    private var rightButton: some View {
        // 挂着待发的图时也是「发送」态：图文分条 —— 一次点击先发图那一条，
        // 草稿里还有字就紧跟着发文字那一条（稿：图片单独成条，配的文字紧跟一条）。
        let hasDraft = !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !pending.isEmpty
        let icon = voiceMode ? UmbraIconPath.keyboard : (hasDraft ? UmbraIconPath.send : UmbraIconPath.mic)
        let bg = voiceMode ? UmbraColor.orangeSoft : (hasDraft ? UmbraColor.orange : UmbraColor.chip)
        let fg = voiceMode ? UmbraColor.orangeText : (hasDraft ? Color.white : UmbraColor.muted)
        let bc = voiceMode ? UmbraColor.orange : (hasDraft ? UmbraColor.orange : UmbraColor.border)
        return Button {
            if voiceMode {
                voiceMode = false
                inputFocused = true          // 回到打字态就把键盘叫回来，少一次点击
            } else if hasDraft {
                sendPending()                // 发完**不收键盘** —— IM 里都是连着打下一句
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

    /// 「复制聊天」的内容。只导出有文字的块 —— 卡片（确认、问答、任务）复制成文本没有意义，
    /// 拼一堆「[任务进度卡]」占位反而让粘出来的东西没法用。
    private func transcript() -> String {
        chat.blocks.compactMap { b -> String? in
            switch b {
            case .user(let u): return "我：\(u.text)"
            case .assistant(let a): return a.text.isEmpty ? nil : "秘书：\(a.text)"
            case .image(let i): return "\(L("chat.quoteMe"))：\(L("chat.quoteImage", i.count))"
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

/// 有条件地挂长按菜单。**不能**写成 `.contextMenu { if 条件 { … } }` ——
/// 条件不成立时菜单内容为空，但 `.contextMenu` 修饰符本身还在，长按照样会抬起气泡、
/// 模糊背景，走完一整套系统预览，然后一个菜单项都没有。条件必须决定「挂不挂」。
/// 泛型参数叫 `MenuContent` 不叫 `Menu`：`Menu` 会在这个作用域里遮蔽 `SwiftUI.Menu`
///（CLAUDE.md 点名的遮蔽雷区），以后有人在里面写 `Menu { } label: { }` 就会撞上。
///
/// 另：`on` 翻转会让 `_ConditionalContent` 换分支，气泡整棵子树的**身份**随之变更、
/// 里面的 @State 会重置。流式回复的第一个 delta 到达时必然发生一次（text 由空变非空），
/// 当下无害（那一刻只有三点在退场、光标在入场，本来就要重建），但以后往气泡里放任何
/// 有状态的东西（展开收起、选中态）都会在那一刻被清掉。
struct UmbraConditionalMenu<MenuContent: View>: ViewModifier {
    let on: Bool
    @ViewBuilder let menu: () -> MenuContent

    /// 显式标 @ViewBuilder：不标也能靠协议要求继承，但本工程其它三个 ViewModifier
    /// 都没有在 body 顶层写 if/else，没有先例可比对，明写一层省得将来靠推断。
    @ViewBuilder
    func body(content: Content) -> some View {
        if on { content.contextMenu { menu() } } else { content }
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
