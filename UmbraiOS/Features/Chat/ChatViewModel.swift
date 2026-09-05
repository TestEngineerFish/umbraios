import Foundation
import UIKit

// MARK: - Chat ViewModel
//
// 联系人式多会话（与 PC 端一致）：
//   - "assistant"   = 你↔秘书主会话
//   - "device:<id>" = 与某台设备的会话：可直接发消息，服务端会把「目标设备=这台」注入上下文，
//                     端侧任务直接派给它；这台设备的编排流也落在同一个会话里。
//   每个会话各自维护 blocks/分页/未读；服务端给所有推送打了 conversation 标签，据此路由。
@MainActor
class ChatViewModel: ObservableObject {
    static let mainConv = "assistant"

    // 当前会话的消息（驱动列表渲染）
    @Published var blocks: [ChatBlock] = []
    // 会话切换
    @Published var activeConv: String = ChatViewModel.mainConv
    @Published var conversationOrder: [String] = [ChatViewModel.mainConv]
    @Published var unread: Set<String> = []
    // 联系人列表：所有已知设备（含离线）+ 各会话的最后一条消息预览
    @Published var devices: [KnownDevice] = []
    @Published var previews: [String: ConvPreview] = [:]

    struct ConvPreview: Equatable {
        var text: String = ""
        var at: String? = nil
    }

    /// 草稿变得不再以「/」开头（清空、发出、或删掉了斜杠）时复位「当普通消息发」，
    /// 下次再敲 / 面板照常弹 —— 不复位的话按过一次之后面板就永远哑了。
    @Published var draft: String = "" {
        didSet { if !draft.hasPrefix("/"), slashDismissed { slashDismissed = false } }
    }
    /// 输入框上方的引用条（批次 011 ②）：选了「引用」之后挂在这儿，发出去随消息带走。
    /// 只是这条消息的注脚 —— 不改发给模型的正文，也不改气泡里显示的文字。
    @Published var quote: ChatQuote?
    /// 「/」快捷输入选中的动作芯片（批次 005）。挂着芯片时动作名以 【动作名】 前缀
    /// 并进正文发出（服务端零改动，秘书按人话前缀理解意图）；nil = 没挂。
    /// 原来这里是三态「对话模式」（auto / chat / execution）—— 模式条整个撤了，
    /// 发送固定 auto（服务端 mode 参数保留一段时间），UserDefaults 里的旧键随之作废。
    @Published var chipAction: SlashAction?
    /// 面板空态里按过「当普通消息发」：草稿仍以 / 开头但这轮不再弹面板。
    @Published var slashDismissed = false
    /// 灵感页「让 Umbra 去做这件事」带过来的来源横幅文案；nil = 不显示。
    /// 放 VM 不放 View 的 @State：预填发生在灵感页、显示在对话页，跨页面只能走这里。
    @Published var ideaBanner: String?
    @Published var isThinking: Bool = false

    /// 「/」面板该不该开：芯片未挂、没按过「当普通消息发」、草稿以 / 开头。
    /// 语音态的额外条件在 View 侧叠（voiceMode 是 View 的 @State）。
    var slashPanelOn: Bool { chipAction == nil && !slashDismissed && draft.hasPrefix("/") }
    /// 去掉引导斜杠后的过滤词。
    var slashQuery: String { String(draft.dropFirst()).trimmingCharacters(in: .whitespaces) }
    // showAttachSheet / showVoiceOverlay / showLightbox / lightboxImageURL 四个已删：
    // 它们只被旧的 ChatView 用过，那个文件已经不在了。新的对话页用自己的 @State 管这些瞬时状态。
    @Published var confirmPending: ConfirmRequest?

    let ws = ChatWebSocket()

    // 正在等回复的会话（流式 token / reply 归属它；服务端也会给事件打 conversation 标签，这里是兜底）。
    private var pendingConv: String = ChatViewModel.mainConv

    // 回复超时兜底：发出后一段时间没有任何回复/流式内容，就把「思考中」气泡收尾为错误，
    // 避免连接中途断开时界面永远 loading。
    private var replyTimeout: Task<Void, Never>?
    /// **静默**多久算这一轮没戏了。注意是「一点动静都没有」的时长，不是整轮耗时 ——
    /// 带工具的一轮跑几分钟很正常（服务端日志里单次请求就要 20 秒往上），
    /// 按总耗时判会把正常的长任务全判成超时。
    private static let idleTimeoutNs: UInt64 = 120_000_000_000   // 120s

    private func armReplyTimeout() {
        replyTimeout?.cancel()
        replyTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleTimeoutNs)
            guard let self, !Task.isCancelled else { return }
            self.failPendingTurn()
        }
    }

    /// 这一轮收尾（拿到 reply / 出错）→ 停表并置空。
    /// 置 nil 而不只是 cancel：handleMessage 靠它判断「还在等这一轮吗」，
    /// 不置空的话闲置期间收到别的推送也会白白重起一个计时器。
    private func stopReplyTimeout() {
        replyTimeout?.cancel()
        replyTimeout = nil
    }
    private func failPendingTurn() {
        // 先清表再判：这条路径不经过 stopReplyTimeout，早退时不清的话 replyTimeout 会留着
        // 一个跑完的 Task，而 handleMessage 靠「replyTimeout != nil」判断「还在等这一轮吗」——
        // 契约一破，之后每收到一条推送都会白白重起一个 120 秒的计时器。
        replyTimeout = nil
        let conv = pendingConv
        let s = store(conv)
        guard let idx = s.assistantIdx, idx < s.blocks.count else { return }
        if case .assistant(var a) = s.blocks[idx] {
            a.thinking = false
            a.streaming = false
            s.blocks[idx] = .assistant(a)
        }
        s.assistantIdx = nil
        replyTimeout = nil
        s.blocks.append(.error(id: UUID(), text: L("chat.status.timeout")))
        reflect(conv)
    }

    // 每个会话的独立状态
    private final class ConvStore {
        var blocks: [ChatBlock] = []
        var assistantIdx: Int?
        var taskMap: [String: Int] = [:]
        var oldestId: Int?
        var hasMoreHistory = true
        var loaded = false
    }
    private var stores: [String: ConvStore] = [:]

    private var isLoadingHistory = false
    var stickToBottom: Bool = true
    var shouldScrollToBottom: Bool { stickToBottom }
    func setStickToBottom(_ value: Bool) { stickToBottom = value }

    func convLabel(_ conv: String) -> String {
        if conv == ChatViewModel.mainConv { return L("chat.conv.secretary") }
        if let d = device(for: conv) { return d.device_name }
        if conv.hasPrefix("device:") { return String(conv.dropFirst("device:".count)) }
        return conv
    }

    func device(for conv: String) -> KnownDevice? {
        guard conv.hasPrefix("device:") else { return nil }
        let id = String(conv.dropFirst("device:".count))
        return devices.first { $0.device_id == id }
    }

    /// 联系人顺序：秘书恒在首位 → 在线设备 → 离线设备（服务端已排好序）。
    var contacts: [String] {
        [ChatViewModel.mainConv] + devices.map(\.conversation)
    }

    init() {
        setupWebSocket()
    }

    // MARK: - Devices（联系人列表）
    func loadDevices() {
        Task { await reloadDevices() }
    }

    /// 下拉刷新用的可等待版本 —— .refreshable 需要 async 才能让刷新圈转到数据回来。
    func reloadDevices() async {
        let list = await HTTPService.shared.fetchAllDevices()
        // 拉失败（nil）保留旧联系人，别把列表清成只剩秘书。
        if let list { await MainActor.run { self.devices = list } }
    }

    func forgetDevice(_ deviceId: String) {
        Task {
            if await HTTPService.shared.forgetDevice(deviceId) {
                await MainActor.run { self.devices.removeAll { $0.device_id == deviceId } }
            }
        }
    }

    private func setPreview(_ conv: String, _ text: String, _ at: String?) {
        guard !text.isEmpty else { return }
        previews[conv] = ConvPreview(text: text, at: at)
    }

    // MARK: - Store helpers
    private func store(_ conv: String) -> ConvStore {
        if let s = stores[conv] { return s }
        let s = ConvStore()
        stores[conv] = s
        if !conversationOrder.contains(conv) { conversationOrder.append(conv) }
        return s
    }
    private var mainStore: ConvStore { store(ChatViewModel.mainConv) }

    /// 只把变更反映到当前会话，**不标未读**。删除、回收站找回这类「不是新消息」的变更用它 ——
    /// 走 reflect 的话联系人列表会冒一个红点，点进去却什么新东西都没有。
    private func refresh(_ conv: String) {
        if conv == activeConv { blocks = store(conv).blocks }
    }

    // 把某会话的变更反映到 UI：active → 更新 blocks；否则标未读。
    private func reflect(_ conv: String) {
        if conv == activeConv {
            blocks = store(conv).blocks
        } else {
            unread.insert(conv)
        }
    }

    // MARK: - Setup / history
    private func setupWebSocket() {
        ws.onMessage = { [weak self] msg in self?.handleMessage(msg) }
        ws.onStatusChange = { [weak self] status in
            // 连接掉线且此时有「思考中」的回合在等 → 立即收尾为错误，不用干等超时。
            guard let self else { return }
            if status == .offline, self.store(self.pendingConv).assistantIdx != nil {
                self.stopReplyTimeout()
                self.failPendingTurn()
            }
        }
        ws.connect()
        loadHistory()
        loadConversationsList()
        loadDevices()
    }

    func loadHistory() {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        Task {
            let messages = await HTTPService.shared.fetchHistory(limit: 40, conversation: ChatViewModel.mainConv)
            await MainActor.run {
                self.isLoadingHistory = false
                let s = self.mainStore
                s.loaded = true
                if s.blocks.isEmpty {
                    s.blocks = messages.compactMap { self.historyToBlock($0) }
                }
                if let last = messages.first {
                    s.oldestId = last.id
                    s.hasMoreHistory = messages.count >= 40
                }
                self.reflect(ChatViewModel.mainConv)
            }
        }
    }

    private func loadConvHistory(_ conv: String) {
        let s = store(conv)
        guard !s.loaded else { return }
        s.loaded = true
        Task {
            let messages = await HTTPService.shared.fetchHistory(limit: 40, conversation: conv)
            await MainActor.run {
                if s.blocks.isEmpty {
                    s.blocks = messages.compactMap { self.historyToBlock($0) }
                }
                if let last = messages.first {
                    s.oldestId = last.id
                    s.hasMoreHistory = messages.count >= 40
                }
                // 首次进这个会话时把历史铺上，不是「来新消息了」。同 loadOlderHistory：
                // 这中间隔了一次 await，中途再切一次会话就会给它误点红点。
                self.refresh(conv)
            }
        }
    }

    private func loadConversationsList() {
        Task {
            let rows = await HTTPService.shared.fetchConversations()
            await MainActor.run {
                for r in rows {
                    _ = self.store(r.conversation)
                    self.setPreview(r.conversation, r.last_content, r.last_at)
                }
            }
        }
    }

    /// 历史里的一行 → 一个块。**返回可空**：有些行不该出现在界面上（见下面两处 nil），
    /// 调用方一律用 compactMap。
    private func historyToBlock(_ msg: HistoryMessage) -> ChatBlock? {
        // `/new` 会往库里写一行 __new_topic__ 当「新话题」的分界标记（memory.mark_new_topic）。
        // 它是给取上下文用的，不是给人看的 —— 历史接口不过滤（只滤软删），端上必须自己滤掉，
        // 否则开了新会话再回来，聊天里就多一行写着 __new_topic__ 的东西。
        // 放在 switch **之前**：现在它是 role=system，但这一条不该押注在 role 上 ——
        // 万一哪天换成别的 role，落进 default 就会变成一颗秘书说「__new_topic__」的气泡，更糟。
        if msg.content == "__new_topic__" { return nil }
        switch msg.role {
        case "user":
            // 历史里的一条我发的消息：id / 引用 / 附件都从服务端那份带回来（删除与引用指着它们）。
            // 纯图片消息（kind=image）的 content 是空串，走图片块 —— 当文字气泡画就是个空泡。
            if (msg.kind ?? "text") == "image" {
                let atts = (msg.atts ?? []).filter { !$0.isEmpty }
                guard !atts.isEmpty else { return nil }
                return .image(ChatBlock.ImageBlock(atts: atts, ts: msg.created_at,
                                                   serverId: msg.id, state: .sent))
            }
            return .user(ChatBlock.UserBlock(
                text: msg.content, ts: msg.created_at, serverId: msg.id,
                quote: historyQuote(msg.meta), atts: msg.atts ?? []))
        case "device": return .device(id: UUID(), text: msg.content, ts: msg.created_at)
        case "system":
            // 取消收尾那条系统提示行是真消息（进库、能删、能从回收站找回），
            // 重进这个会话时得照样画出来，不能当成秘书说的话塞进气泡。
            return .note(ChatBlock.NoteBlock(text: msg.content, serverId: msg.id,
                                             toolsRun: historyTools(msg.meta)))
        default:
            return .assistant(ChatBlock.AssistantBlock(
                thinking: false, streaming: false, text: msg.content, trace: [], traceOpen: false,
                ts: msg.created_at, serverId: msg.id,
                interrupted: msg.meta?.interrupted ?? false, toolsRun: historyTools(msg.meta)))
        }
    }

    /// 历史行的 meta.quote → 引用注脚。空 text 的引用不要 —— `ChatQuote.init?(json:)`（WS 那条路）
    /// 就是拒绝空 text 的，两条入口的口径必须一样，不然同一条消息在「拉历史」和「跨端广播」
    /// 两种来源下画出来的东西不一致。
    private func historyQuote(_ meta: HistoryMeta?) -> ChatQuote? {
        guard let q = meta?.quote, let text = q.text, !text.isEmpty else { return nil }
        return ChatQuote(id: q.id, role: q.role ?? "user", text: text)
    }

    /// 历史行的 meta.tools → 端上的工具留痕。两份结构长得几乎一样，
    /// 但一份是 Codable（HTTP 历史）、一份从 JSON 字典来（WS 广播），合不成一个类型。
    private func historyTools(_ meta: HistoryMeta?) -> [ChatToolRun] {
        (meta?.tools ?? []).compactMap { t in
            guard let name = t.name, !name.isEmpty else { return nil }
            return ChatToolRun(name: name, args: t.args ?? "")
        }
    }

    /// 当前会话还能往前翻吗。不是 @Published，但它只在 blocks 变化时会变，
    /// 而 blocks 是 @Published —— 读它的视图该刷新的时候都会刷新。
    var canLoadOlder: Bool {
        let s = store(activeConv)
        return s.hasMoreHistory && !s.blocks.isEmpty
    }

    func loadOlderHistory() async {
        let s = store(activeConv)
        guard !isLoadingHistory, s.hasMoreHistory, let beforeId = s.oldestId else { return }
        isLoadingHistory = true
        let conv = activeConv
        let messages = await HTTPService.shared.fetchHistory(limit: 40, beforeId: beforeId, conversation: conv)
        await MainActor.run {
            isLoadingHistory = false
            if messages.isEmpty { s.hasMoreHistory = false; return }
            if messages.count < 40 { s.hasMoreHistory = false }
            s.oldestId = messages.first?.id
            let newBlocks = messages.compactMap { self.historyToBlock($0) }
            s.blocks.insert(contentsOf: newBlocks, at: 0)
            let shift = newBlocks.count
            for key in s.taskMap.keys { s.taskMap[key]? += shift }
            s.assistantIdx? += shift
            // 往前插旧消息不是「来新消息了」。而且这中间隔了一次 await：用户在转圈时
            // 切去了别的会话的话，reflect 会给刚才那个会话点上一个红点。
            refresh(conv)
        }
    }

    // MARK: - Conversation switching
    func switchConversation(_ conv: String) {
        activeConv = conv
        unread.remove(conv)
        stickToBottom = true
        // 引用是 VM 级的单例状态：在主会话里选了「引用」还没发就切走，
        // 带着它发出去就是一条指向**别的会话**那条消息的引用，点了永远跳不过去。
        quote = nil
        let s = store(conv)
        blocks = s.blocks
        if !s.loaded { loadConvHistory(conv) }
    }

    // MARK: - Send
    // 发到**当前会话**：主会话=直接跟秘书说；设备会话=对着这台设备说（秘书按「目标设备=这台」执行）。
    func send() {
        let raw = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        // 芯片动作以【动作名】前缀并入正文（批次 005 拍板）。气泡里显示的就是这份全文 ——
        // 用户看到的等于发出去的，不藏一层「其实还带了个动作」的暗号。
        let text = chipAction.map { "【\($0.label)】\(raw)" } ?? raw
        draft = ""
        chipAction = nil
        ideaBanner = nil
        let sent = quote
        quote = nil   // 引用是一次性的：这一条带走就摘掉，别让下一条默默带上同一段
        deliver(text, quote: sent)
    }

    /// 真正把一条消息发出去（乐观气泡 / 占位 / 失败收尾 / 计时都在这儿）。
    /// 和 `send()` 拆开，是因为「重新发送」不该借用户的输入框当传参通道 ——
    /// 借了就会把人家正打到一半的草稿、挂着的芯片、刚选的另一条引用全冲掉。
    private func deliver(_ text: String, quote sent: ChatQuote?) {
        stickToBottom = true
        let conv = activeConv
        let s = store(conv)
        let now = ISO8601DateFormatter().string(from: Date())
        // 上一轮还在转的占位先收尾：assistantIdx 马上要被这一轮覆盖，旧那颗就再没人管了。
        // 批次 011 之后它还会多长出一颗停止钮，而那颗点下去停的是**这一轮** —— 更坏。
        sealPlaceholder(s)
        // 乐观气泡：先画出来，服务端回执（reply 的 user_message_id）再把 serverId 认领上。
        s.blocks.append(.user(ChatBlock.UserBlock(text: text, ts: now, quote: sent)))
        // mode 固定 "auto"：模式条已撤（批次 005），服务端参数保留一段时间，界面不再出现。
        // 发不出去（离线）就地收尾：把这条标成失败 + 追一行说清楚，**不画占位**。
        // 原来的做法是照样画占位，然后三个点转满 120 秒才冒出「超时」—— 而消息压根没出门。
        guard ws.sendMessage(text, conversation: conv, mode: "auto", quote: sent) else {
            if case .user(var u) = s.blocks[s.blocks.count - 1] {
                u.failure = .offline
                s.blocks[s.blocks.count - 1] = .user(u)
            }
            // 不另起错误块：稿②把「没发出去 · 连接断了」+「重新发送」画在气泡**正下方那一行**，
            // 再来一张错误卡就是同一件事说两遍。
            // 这一轮压根没开始，表也别留着（sealPlaceholder 已经把上一轮的 assistantIdx 清了，
            // 计时器再响一次也找不到收尾对象，只会把 replyTimeout 卡成非 nil）。
            stopReplyTimeout()
            setPreview(conv, text, now)
            reflect(conv)
            return
        }
        s.blocks.append(.assistant(ChatBlock.AssistantBlock(thinking: true, streaming: true, text: "", trace: [], traceOpen: true, ts: now)))
        s.assistantIdx = s.blocks.count - 1
        setPreview(conv, text, now)
        reflect(conv)
        pendingConv = conv
        armReplyTimeout()
    }

    // MARK: - 图片消息（批次 011 ③）

    /// 正在跑的上传任务，按块 id 存 —— 「取消上传」和「块被删掉了」都靠它把 Task 掐掉。
    private var uploads: [UUID: Task<Void, Never>] = [:]
    /// 上一次真正落库的整数百分比，按块存。节流的第一道闸 ——
    /// 原来要先全量扫一遍找块才能比对，贵的那半没省下来。
    private var lastPct: [UUID: Int] = [:]
    /// 每个块的上传**代次**。旧任务被 cancel 之后要等一次主线程轮转才恢复执行，
    /// 那时槽里已经是新任务了 —— 没有代次号的话旧任务的收尾会把新任务的槽清掉
    /// （于是「取消上传」变成空转：界面上撤了，HTTP 还在跑，服务端留孤儿文件）。
    /// 迟到的进度回调同理，会把重传后的进度条往回拨。
    private var uploadGen: [UUID: Int] = [:]

    /// 发一条图片消息。先把块画出来（本地图当预览），再逐张传，全传完才送 WS。
    func sendImages(_ images: [Data]) {
        guard !images.isEmpty else { return }
        let conv = activeConv
        let s = store(conv)
        stickToBottom = true
        var blk = ChatBlock.ImageBlock(data: images,
                                       ts: ISO8601DateFormatter().string(from: Date()))
        blk.totalBytes = images.reduce(0) { $0 + $1.count }
        // 单图的比例趁本地还有原图算一次。钳进 [0.4, 2.5]：长截图（1:8）不钳的话
        // 会画成 220×1760 再被裁掉中间一截，破图的 size 还可能是 0 → NaN。
        if images.count == 1, let ui = UIImage(data: images[0]), ui.size.height > 0 {
            blk.ratioHint = min(2.5, max(0.4, ui.size.width / ui.size.height))
        }
        s.blocks.append(.image(blk))
        setPreview(conv, L("chat.imageMsgPreview"), blk.ts)
        reflect(conv)
        runUpload(blockId: blk.id, conv: conv)
    }

    /// 断点续传：从 `atts.count` 那张接着传，传完送 WS。
    /// **不重传已经传成功的** —— 重传会在服务端留孤儿文件。
    private func runUpload(blockId: UUID, conv: String) {
        uploads[blockId]?.cancel()
        let gen = (uploadGen[blockId] ?? 0) + 1
        uploadGen[blockId] = gen
        uploads[blockId] = Task { @MainActor [weak self] in
            // 只清自己那一代的槽，别把接手的新任务掐了。
            defer { if self?.uploadGen[blockId] == gen { self?.uploads[blockId] = nil } }
            guard let self else { return }
            while let blk = self.imageBlock(blockId), blk.atts.count < blk.data.count {
                let idx = blk.atts.count
                let bytes = blk.data[idx]
                let doneBytes = blk.data.prefix(idx).reduce(0) { $0 + $1.count }
                let name = "chat-\(Int(Date().timeIntervalSince1970))-\(idx).jpg"
                do {
                    let up = try await HTTPService.shared.uploadFileWithProgress(name: name, data: bytes) { sent, total in
                        // 进度回调可能比「块已经没了 / 已经重传了」晚到，靠代次号拦。
                        // cur 钳到这张图的裸字节数：multipart 的 boundary/header 也算在
                        // sent 里，不钳的话会出现「1.9 MB / 1.8 MB」这种超过 100% 的行。
                        Self.noteProgress(self, blockId: blockId, gen: gen, idx: idx,
                                          frac: total > 0 ? Double(sent) / Double(total) : 0,
                                          doneBytes: doneBytes, cur: min(Int(sent), bytes.count))
                    }
                    guard !Task.isCancelled else { return }
                    self.mutateImage(blockId) { b in
                        b.atts.append(up.file_id)
                        b.sentBytes = doneBytes + bytes.count
                        b.currentFrac = 0
                    }
                } catch {
                    // 被取消（用户点「取消上传」/ 删了这条）就到此为止，不改成失败态 ——
                    // 那两条路自己会处理块的去留。
                    guard !Task.isCancelled else { return }
                    self.mutateImage(blockId) { b in
                        b.state = .failed
                        b.failReason = L("chat.uploadFailed")
                    }
                    return
                }
            }
            guard !Task.isCancelled, let blk = self.imageBlock(blockId),
                  blk.state == .uploading, blk.atts.count == blk.data.count else { return }
            // 全传完才送 WS。成功路径**不动状态** —— message_saved 回执来认领（带正式 id）。
            guard self.ws.sendImageMessage(atts: blk.atts, conversation: conv) else {
                self.mutateImage(blockId) { b in
                    b.state = .failed
                    b.failReason = L("chat.notConnected")
                }
                return
            }
            // 送出去了就转「等回执」：这一档不再给「取消上传」——
            // 服务端已经有这条了，撤本地只会让用户再发一次，变成两条。
            self.mutateImage(blockId) { b in if b.state == .uploading { b.state = .awaitingReceipt } }
            // 回执兜底：图都传上去了、WS 也送出去了，但 message_saved 可能丢
            //（连接刚好在这一刻断）。不兜的话这条会**永远转**，而它其实已经在服务端了。
            // 转成失败态并说实话；「重新发送」此时只是再送一次 WS —— atts 齐了不会重传文件。
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let after = self.imageBlock(blockId),
                  after.state == .awaitingReceipt, after.serverId == nil else { return }
            self.mutateImage(blockId) { b in
                b.state = .failed
                b.failReason = L("chat.uploadNoReceipt")
            }
        }
    }

    /// 进度回调专用的静态入口：闭包里直接捕获 self 会把 @Sendable 的要求传染开，
    /// 绕一层静态方法最省事，语义完全一样。
    /// `idx`：这一帧说的是**第几张**。`didSendBodyData` 是另跳一个 Task 派发的，和
    /// `upload(...)` 的恢复之间没有顺序保证 —— 第 k 张的最后一帧完全可能落在
    /// 「atts.append + currentFrac = 0」之后，于是第 k+1 张的格子先闪一个 100% 的环、
    /// 字节数还往回退。所以除了代次号，还要确认「这一张仍然是当前正在传的那张」。
    private static func noteProgress(_ vm: ChatViewModel, blockId: UUID, gen: Int, idx: Int,
                                     frac: Double, doneBytes: Int, cur: Int) {
        guard vm.uploadGen[blockId] == gen else { return }
        // **按整数百分比节流**，而且这道闸放在最前面（O(1)）：didSendBodyData 每个网络
        // 分片就回调一次（每秒几十次），而落库一次就要整条会话重新赋值 @Published blocks、
        // 整页重算。放到扫描之后拦的话，贵的那半（每次遍历所有会话所有块）并没省下来。
        let pct = Int(min(1, max(0, frac)) * 100)
        guard vm.lastPct[blockId] != pct else { return }
        var applied = false
        vm.mutateImage(blockId) { b in
            guard b.state == .uploading, b.atts.count == idx else { return }
            b.currentFrac = min(1, max(0, frac))
            b.sentBytes = doneBytes + cur
            applied = true
        }
        if applied { vm.lastPct[blockId] = pct }
    }

    /// 找到某个图片块。找不到 = 它已经被撤掉了（取消上传 / 删除），调用方据此收工。
    private func imageBlock(_ blockId: UUID) -> ChatBlock.ImageBlock? {
        for (_, s) in stores {
            for b in s.blocks {
                if case .image(let img) = b, img.id == blockId { return img }
            }
        }
        return nil
    }

    /// 就地改一个图片块并刷新它所在的会话。
    private func mutateImage(_ blockId: UUID, _ body: (inout ChatBlock.ImageBlock) -> Void) {
        for (conv, s) in stores {
            for (i, b) in s.blocks.enumerated() {
                guard case .image(var img) = b, img.id == blockId else { continue }
                body(&img)
                s.blocks[i] = .image(img)
                refresh(conv)
                return
            }
        }
    }

    /// 「取消上传」：掐掉任务、把这条撤掉，并把**本地那几张图原样交还**给调用方 ——
    /// 图还在本地，放回待发条就行，不该让用户再去相册翻一遍（PC 端同一条行为）。
    ///
    /// 返回的是**整条的图**，不是「还没传成的那几张」：用户拿回来的应该是完整一条消息，
    /// 缺几张的一条他自己也拼不回去。代价是已经传上去的那几份在服务端成了孤儿文件 ——
    /// 这条记在台账里，等服务端加一个「没有消息引用的文件定期清掉」。
    @discardableResult
    func cancelImageUpload(blockId: UUID) -> [Data] {
        uploads[blockId]?.cancel()
        uploads[blockId] = nil
        // 置 nil 而不是 +1：迟到回调那边 `nil == gen` 同样为 false，拦截效果一样，
        // 还顺手把字典项回收了（不清的话它会随会话时长单调增长）。
        uploadGen[blockId] = nil
        lastPct[blockId] = nil
        for (conv, s) in stores {
            guard let i = s.blocks.firstIndex(where: {
                if case .image(let img) = $0 { return img.id == blockId } else { return false }
            }) else { continue }
            var back: [Data] = []
            if case .image(let img) = s.blocks[i] { back = Array(img.data) }
            dropBlocks(at: i, in: s)
            refresh(conv)
            return back
        }
        return []
    }

    /// 掐掉某个会话里所有在途的上传。整批清块的四条路（清空历史 / 开新话题 /
    /// 别的端清空 / 回收站找回后重拉）都要先调它 —— 不掐的话上传会继续跑到底，
    /// 白耗流量、在服务端留孤儿文件，最后因为找不到块而**静默地什么都不发**。
    private func cancelUploads(in s: ConvStore) {
        for b in s.blocks {
            guard case .image(let img) = b else { continue }
            uploads[img.id]?.cancel()
            uploads[img.id] = nil
            uploadGen[img.id] = nil
            lastPct[img.id] = nil
        }
    }

    /// 图片消息「重新发送」：从断的那张续传。
    func retryImages(blockId: UUID) {
        // 只有失败态能重传。不校验的话，一条正在传的块被再点一次就会有两个任务
        // 并发往同一个 atts 里 append（PC 的 retryImageSend 首行也是这条守卫）。
        guard let b = imageBlock(blockId), b.state == .failed else { return }
        let conv = activeConv
        mutateImage(blockId) { b in
            b.state = .uploading
            b.failReason = ""
            b.sentBytes = b.data.prefix(b.atts.count).reduce(0) { $0 + $1.count }
            b.currentFrac = 0
        }
        runUpload(blockId: blockId, conv: conv)
    }

    /// 把某会话里还在转的占位气泡就地收尾（只停转，不追错误行）。
    /// 用在「这一轮的占位要被新一轮顶掉」的场合 —— 旧那颗的 delta/reply 本来就已经
    /// 找不到落点了（currentAssistant 只认 assistantIdx），至少别让它一直转下去。
    private func sealPlaceholder(_ s: ConvStore) {
        defer { s.assistantIdx = nil }
        guard let idx = s.assistantIdx, idx < s.blocks.count,
              case .assistant(var a) = s.blocks[idx] else { return }
        a.thinking = false
        a.streaming = false
        s.blocks[idx] = .assistant(a)
    }

    /// 认领服务端给我方消息分配的 id（批次 011）。用户消息在 `handle()` 里才落库，
    /// WS 广播那会儿还没有 id，所以由 `reply` 回执带回来。
    ///
    /// 两道保险，都是 PC 端踩出来的：
    ///   1. **已经认领过就别再找**（带附件那条由 message_saved 先认领）—— 不然会把这个 id
    ///      错发给更早一条还没回执的消息；
    ///   2. 从**本轮的占位气泡**往前找，不是从整份数组的末尾找。等回复的这几秒里别的端
    ///      也可能发消息进来，而服务端广播别人那条纯文字消息时**不带 id**
    ///      （app.py 的 user_sync 只有带附件才 update id），末尾那条很可能是别人的 ——
    ///      认错了以后长按删除就删到别人头上。占位块之前紧挨着的那条一定是我这条。
    private func claimUserMessageId(_ uid: Int, conv: String) {
        let s = store(conv)
        let taken = s.blocks.contains { if case .user(let u) = $0 { return u.serverId == uid } else { return false } }
        guard !taken else { return }
        var i = min(s.assistantIdx.map { $0 - 1 } ?? s.blocks.count - 1, s.blocks.count - 1)
        while i >= 0 {
            if case .user(var u) = s.blocks[i], u.serverId == nil, !u.failed {
                u.serverId = uid
                s.blocks[i] = .user(u)
                refresh(conv)
                return
            }
            i -= 1
        }
    }

    /// 图片消息的落库回执：按 atts 认领（file_id 一次上传一个，天然唯一，不会认错）。
    /// 认到之后这条就从「在途」转成「已发」，长按菜单里的删除 / 引用才有对象可指。
    private func claimImageMessageId(_ mid: Int, atts: [String]) {
        guard !atts.isEmpty else { return }
        for (conv, s) in stores {
            for (i, b) in s.blocks.enumerated() {
                // 守卫是 `!= .sent` 而不是 `== .uploading`：15 秒兜底会把「回执迟到」的块
                // 转成失败态，但它在服务端**是真存在的** —— 第 16 秒才到的回执必须认下来，
                // 否则用户会照着那条红字再发一次，服务端就有两条一模一样的图片消息。
                guard case .image(var img) = b, img.serverId == nil,
                      img.state != .sent, img.atts == atts else { continue }
                img.serverId = mid
                img.state = .sent
                img.failReason = ""
                // 本地原图到此为止：服务端那份已经是正本，再留着就是最多 9×10 MB
                // 一直挂在 VM 上、换会话也不释放（PC 端也是认领时就 files = undefined）。
                // 代价是「复制图片 / 存到相册」要现下一次 —— 值。
                img.data = []
                s.blocks[i] = .image(img)
                refresh(conv)
                return
            }
        }
    }

    /// 停掉这次回复（批次 011 ①）。**只发信号，不动本地气泡** —— 收尾块由服务端
    /// 以 reply_cancelled 回来替换占位；本端抢着改的话，「点停止的同一刻其实已经答完了」
    /// 这种时序会两边打架。
    ///
    /// 静默计时**不停**：收尾也可能丢（连接刚好断、服务端收尾那段抛异常），
    /// 停了表这颗占位气泡就会一直转到用户杀进程。留着它当地板。
    /// 返回 false = 没连上，信号没发出去 —— 调用方该吐一句，不然用户戳那颗钮毫无反应。
    @discardableResult
    func cancelReply() -> Bool {
        let conv = activeConv
        guard store(conv).assistantIdx != nil else { return false }
        return ws.sendCancelReply(conversation: conv)
    }

    /// 删一条消息（批次 011 ②）。服务端软删进回收站（30 天）后广播 message_deleted 给所有端，
    /// **本端也从广播里删** —— 本地先删会在服务端拒绝时留下一条「看起来删了其实还在」的消息。
    ///
    /// ⚠️ 这个方法**不弹二次确认**。删除是跨端的，稿里点名要先问一句
    ///（「删除这条消息？/ 各设备都会删除。删除后会移入回收站，保留 30 天。」），
    /// 那一层归调用方（长按菜单）走 `router.confirm`。
    /// 返回 false = 没连上，没发出去 —— 调用方该吐一句，别让菜单收了却什么也没发生。
    /// 没有 serverId 的消息（还没发出去的失败条）服务端上不存在，只该本地移除，走 `dropLocal`。
    @discardableResult
    func deleteMessage(serverId: Int) -> Bool {
        guard serverId > 0 else { return false }
        return ws.sendDeleteMessage(id: serverId)
    }

    /// 只把本地这一个块拿掉（发送失败、服务端上根本没有这条的那种「删除」）。
    func dropLocal(blockId: String) {
        for (conv, s) in stores {
            guard let i = s.blocks.firstIndex(where: { $0.id == blockId }) else { continue }
            dropBlocks(at: i, in: s)
            refresh(conv)
            return
        }
    }

    /// 重新发送一条发失败的消息（批次 011 ② 的「重新发送」置顶项）。
    /// 先把失败那条连同它的错误行拿掉，再走一遍完整的 `send()` —— 原地改状态的话，
    /// 第二次又失败就会留下两条一模一样的红叹号。正文与引用照旧带走。
    func resendFailed(blockId: String) {
        let conv = activeConv
        let s = store(conv)
        guard let i = s.blocks.firstIndex(where: { $0.id == blockId }),
              case .user(let u) = s.blocks[i], u.failed else { return }
        dropBlocks(at: i, in: s)
        refresh(conv)
        // 直接喂内核，不经 draft / quote 这两个属性中转：正文已经含着【动作名】前缀
        //（原来那次发送时就拼进去了），走 send() 会被 chipAction 再拼一层，
        // 而且会把用户此刻正在打的草稿冲掉。
        deliver(u.text, quote: u.quote)
    }

    /// 移掉第 i 个块，并把受影响的下标整体前移。
    ///
    /// 曾经这里还会「顺带带走紧跟其后的那行错误」——因为发送失败时会另起一条错误块。
    /// 稿②把「没发出去 · 连接断了」画进了气泡正下方那一行，错误块不再产生，这条顺带
    /// 就只剩下误删：失败气泡在末尾，之后服务端推来的 error 正好落在它 i+1，
    /// 用户点重发 / 删除会把那条**真的**服务端错误一起静默删掉。
    private func dropBlocks(at i: Int, in s: ConvStore) {
        s.blocks.remove(at: i)
        if let a = s.assistantIdx { s.assistantIdx = a > i ? a - 1 : (a == i ? nil : a) }
        for (k, v) in s.taskMap where v > i { s.taskMap[k] = v - 1 }
    }

    /// 引用一条消息（批次 011 ②）：挂到输入框上方的引用条，发出去随消息带走。
    /// 没有 serverId 也能引用（引用条照出、正文照带），只是点它跳不回原消息。
    func quoteMessage(id: Int?, role: String, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        quote = ChatQuote(id: id, role: role, text: String(t.prefix(200)))
    }

    /// 灵感详情「让 Umbra 去做这件事」：切到主会话，挂「创建任务」芯片、
    /// 把灵感原文填进草稿、亮来源横幅。**不自动发送** —— 发之前让用户能改一句
    /// （PC 端定下的行为，两端一致）。原来这里是「切执行模式」，模式撤了改走芯片。
    func prefillTaskFromIdea(_ text: String, sourceTitle: String) {
        switchConversation(ChatViewModel.mainConv)
        chipAction = SlashCatalog.taskAction
        slashDismissed = false
        draft = text
        ideaBanner = "来自灵感「\(sourceTitle)」，已经替你填好「创建任务」。"
    }

    // 清空【当前会话】历史：本地立即清 + 服务端删除。
    func clearActiveHistory() {
        let conv = activeConv
        let s = store(conv)
        // 挂着的引用指向的那条马上就没了，一起摘掉（同 switchConversation 的理由）。
        quote = nil
        cancelUploads(in: s)
        s.blocks.removeAll()
        s.assistantIdx = nil
        s.taskMap.removeAll()
        s.oldestId = nil
        s.hasMoreHistory = false
        s.loaded = true
        previews[conv] = nil
        reflect(conv)
        Task { await HTTPService.shared.clearHistory(conversation: conv) }
    }

    /// 开新话题。**先发后清**：`/new` 没出门（离线）就什么都不做并返回 false ——
    /// 原来是先清本地再发，离线时表现成「历史清了，服务端那边话题却没断」，
    /// 而且 hasMoreHistory 还留着 true，往上一翻刚清掉的又全回来了。
    @discardableResult
    func newSession() -> Bool {
        guard ws.sendNewSession() else { return false }
        let s = mainStore
        // 同 clearActiveHistory：引用指着的那条即将从列表里消失。
        // 放在 if 之外 —— 已经在主会话时走的是 else 分支，不经过 switchConversation。
        quote = nil
        cancelUploads(in: s)
        s.blocks.removeAll()
        s.assistantIdx = nil
        s.taskMap.removeAll()
        s.oldestId = nil
        s.hasMoreHistory = true
        stickToBottom = true
        if activeConv != ChatViewModel.mainConv { switchConversation(ChatViewModel.mainConv) }
        else { refresh(ChatViewModel.mainConv) }
        return true
    }

    func toggleTrace(at index: Int) {
        let s = store(activeConv)
        guard index < s.blocks.count, case .assistant(var a) = s.blocks[index] else { return }
        a.traceOpen.toggle()
        s.blocks[index] = .assistant(a)
        reflect(activeConv)
    }

    func handleConfirm(confirmId: String, approved: Bool) {
        ws.sendConfirm(confirmId: confirmId, approved: approved)
        resolveConfirm(confirmId: confirmId, approved: approved)
        confirmPending = nil
    }

    // MARK: - 问答卡
    //
    // 作答状态存在块里（见 QuestionBlock），这里只做「找到那张卡 → 改它 → 反映到 UI」。
    // 每个方法都按 cardId 找，而不是按下标 —— 补拉历史会往前插消息，下标会整体位移。

    private func mutateQuestion(_ cardId: String, _ body: (inout ChatBlock.QuestionBlock) -> Void) {
        for (conv, s) in stores {
            var changed = false
            for i in s.blocks.indices {
                if case .question(var q) = s.blocks[i], q.cardId == cardId {
                    body(&q)
                    s.blocks[i] = .question(q)
                    changed = true
                }
            }
            // 改的是卡片自己的作答状态，不是新消息。别的端答完广播过来的 question_resolved
            // 更是「已经有人处理过了」，给它点个红点、点进去却什么新东西都没有。
            if changed { refresh(conv) }
        }
    }

    /// 选一个选项。多选=切换；单选=替换（再点一次可以取消，和 PC 端一致）。
    func pickAnswer(cardId: String, questionId: String, option: String, multi: Bool) {
        mutateQuestion(cardId) { q in
            guard !q.done else { return }
            var cur = q.picked[questionId] ?? []
            if multi {
                if let k = cur.firstIndex(of: option) { cur.remove(at: k) } else { cur.append(option) }
            } else {
                cur = cur.contains(option) ? [] : [option]
            }
            q.picked[questionId] = cur
        }
    }

    func setCustomAnswer(cardId: String, questionId: String, text: String) {
        mutateQuestion(cardId) { q in
            guard !q.done else { return }
            q.custom[questionId] = text
        }
    }

    /// 翻题。夹在 0…题数-1，越界就停在边界上（不要环绕，用户会以为提交了）。
    func moveQuestion(cardId: String, by delta: Int) {
        mutateQuestion(cardId) { q in
            guard !q.done else { return }
            q.at = min(max(0, q.at + delta), max(0, q.questions.count - 1))
        }
    }

    /// 提交整张卡。必答题没答完就直接不提交 —— 界面上提交键此时是置灰的，
    /// 这里是第二道闸（多端同时操作、或者题目在提交瞬间被改）。
    func submitAnswers(cardId: String) {
        var payload: [String: [String]] = [:]
        var pairs: [(q: String, v: String)] = []
        var ok = false
        mutateQuestion(cardId) { q in
            guard !q.done, q.allFilled else { return }
            payload.removeAll()
            pairs.removeAll()
            for item in q.questions {
                var vals = q.picked[item.id] ?? []
                let c = (q.custom[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !c.isEmpty { vals.append(c) }   // 自己填的与选项并存
                payload[item.id] = vals
                pairs.append((q: item.text, v: vals.isEmpty ? "（跳过）" : vals.joined(separator: "、")))
            }
            q.done = true
            q.answered = pairs
            ok = true
        }
        guard ok else { return }
        ws.sendAnswers(cardId: cardId, answers: payload)
    }

    /// 别的端答完了：本端标成已完成。没有答案明细可展示，就不编 —— 只显示「已答完」。
    private func resolveQuestion(cardId: String) {
        mutateQuestion(cardId) { q in q.done = true }
    }

    // 总是允许：打开自动批准（“我的”里同步）+ 批准本次。
    func handleConfirmAlways(confirmId: String) {
        NetworkConfig.shared.autoApproveOperate = true
        handleConfirm(confirmId: confirmId, approved: true)
    }

    // ① 箭头指位：nx,ny 为箭头尖端归一化坐标(0-1000)。ask_id 是这次求助的单号。
    func handleLocate(askId: String, nx: Int, ny: Int) {
        ws.sendLocate(askId: askId, nx: nx, ny: ny)
        resolveLocate(askId: askId, status: .located)
    }

    // ② 文字纠偏：把「哪错了」发给 AI，让它自己调整步骤/判断。
    func handleLocateFeedback(askId: String, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        ws.sendLocate(askId: askId, feedback: t)
        resolveLocate(askId: askId, status: .feedbackSent)
    }

    // ③ 暂停我来：这次操控挂起，用户手动处理；卡片随后出现「继续」。
    func handleLocatePause(askId: String) {
        ws.sendLocate(askId: askId, paused: true)
        resolveLocate(askId: askId, status: .paused)
    }

    // 用户手动处理完点「继续」：唤醒这次操控，AI 重新看屏接着干。
    // 按 run_id 走，不是 ask_id —— 一次操控可能求助过好几次。
    func handleResume(runId: String, askId: String) {
        guard !runId.isEmpty else { return }
        ws.sendResume(runId: runId)
        resolveLocate(askId: askId, status: .resumed)
    }

    private func resolveLocate(askId: String, status: ChatBlock.LocateStatus) {
        let s = mainStore
        for i in s.blocks.indices {
            if case .locate(var l) = s.blocks[i], l.askId == askId {
                // paused → resumed 允许再次更新；其它状态定型后不再改。
                if l.resolved == nil || (l.resolved == .paused && status == .resumed) {
                    l.resolved = status
                    s.blocks[i] = .locate(l)
                }
            }
        }
        // 四个调用方全是本机用户自己点的（指位 / 纠偏 / 暂停 / 继续）——
        // 自己操作把自己标未读，说不通。
        refresh(ChatViewModel.mainConv)
    }

    private var autoApprovedConfirms: Set<String> = []
    // 满足自动批准就直接批准；返回是否已自动处理。按确认单号（confirm_id）去重。
    private func autoApproveIfEnabled(_ confirmId: String) -> Bool {
        guard NetworkConfig.shared.autoApproveOperate, !autoApprovedConfirms.contains(confirmId) else { return false }
        autoApprovedConfirms.insert(confirmId)
        ws.sendConfirm(confirmId: confirmId, approved: true)
        resolveConfirm(confirmId: confirmId, approved: true)
        return true
    }

    // MARK: - Message Handler
    private func handleMessage(_ msg: ChatMessage) {
        // 流式一类事件归属「服务端标注的会话」，缺省回落到正在等回复的会话。
        let streamConv = msg.conversation ?? pendingConv
        // **收到任何一条服务端消息都重置静默计时**。
        // 原来只有 delta 会重置，可一轮里很可能一个 delta 都没有 ——
        // 模型直接吐工具调用时只有 tool_call / tool_result / node，
        // 问答卡那一轮更是只有 question_card，于是 60 秒一到就误报「连接中断」，
        // 而连接其实好好的（所以点「重新连接」也没用）。用户实测点名。
        if replyTimeout != nil { armReplyTimeout() }
        switch msg.type {
        case "delta":
            if var a = currentAssistant(streamConv) { a.text += msg.deltaText ?? ""; a.thinking = false; updateAssistant(a, streamConv) }

        case "tool_call":
            if var a = currentAssistant(streamConv) {
                if !a.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    a.trace.append("💭 " + a.text.trimmingCharacters(in: .whitespaces))
                    a.text = ""
                }
                var argsStr = ""
                if let args = msg.toolArgs { argsStr = String(String(describing: args).prefix(120)) }
                a.trace.append("🔧 \(msg.toolName ?? "unknown")(\(argsStr))")
                updateAssistant(a, streamConv)
            }

        case "tool_result":
            if var a = currentAssistant(streamConv) {
                let preview = msg.toolResultPreview ?? ""
                let truncated = preview.count > 160 ? preview.prefix(160) + "…" : preview
                a.trace.append("↳ \(msg.toolName ?? "unknown") → \(truncated)")
                updateAssistant(a, streamConv)
            }

        case "reply":
            stopReplyTimeout()
            if var a = currentAssistant(streamConv) {
                a.text = msg.text ?? a.text
                a.thinking = false
                a.streaming = false
                // 秘书这条的服务端 id：长按删除 / 引用要指着它。
                a.serverId = (msg.json["message_id"] as? Int) ?? (msg.json["message_id"] as? NSNumber)?.intValue
                updateAssistant(a, streamConv)
            }
            // 我那条的 id 也在这个回执里（批次 011：用户消息在 handle() 里才落库，
            // WS 广播时还没有 id，所以由回执带回来）。认领到最近一条还没有 id 的我方消息上。
            if let uid = (msg.json["user_message_id"] as? Int) ?? (msg.json["user_message_id"] as? NSNumber)?.intValue {
                claimUserMessageId(uid, conv: streamConv)
            }
            store(streamConv).assistantIdx = nil
            setPreview(streamConv, msg.text ?? "", ISO8601DateFormatter().string(from: Date()))

        case "reply_cancelled":
            // 你停了这次回复（批次 011 ①）。两种收尾由服务端定：
            //   role=assistant → 半截保留 + meta.interrupted（气泡下一行「你停了这次回复 · 只写到这里」）
            //   role=system    → 一行居中提示「你停了这次回复 · 消息已经发出去了，秘书没回」
            // 两种都**替换掉正在流式的占位块**；工具轨迹留着 —— 那是真跑过的。
            stopReplyTimeout()
            let s = store(streamConv)
            let idx = s.assistantIdx
            let text = msg.text ?? ""
            let blk: ChatBlock
            if msg.chatRole == "assistant" {
                // 半截那份保留原占位块攒下的 trace（工具轨迹卡不该跟着消失）。
                var trace: [String] = []
                if let i = idx, i < s.blocks.count, case .assistant(let old) = s.blocks[i] { trace = old.trace }
                blk = .assistant(ChatBlock.AssistantBlock(
                    thinking: false, streaming: false, text: text, trace: trace, traceOpen: false,
                    ts: ISO8601DateFormatter().string(from: Date()),
                    serverId: msg.messageId, interrupted: true, toolsRun: msg.metaTools))
            } else {
                blk = .note(ChatBlock.NoteBlock(text: text, serverId: msg.messageId, toolsRun: msg.metaTools))
            }
            if let i = idx, i < s.blocks.count, case .assistant = s.blocks[i] { s.blocks[i] = blk }
            else { s.blocks.append(blk) }
            s.assistantIdx = nil
            setPreview(streamConv, text, ISO8601DateFormatter().string(from: Date()))
            reflect(streamConv)

        case "message_saved":
            // 落库回执（只发给发起端）：把在途的乐观气泡认领成正式消息 —— 有了 id，
            // 删除和引用才有对象可指。带附件的文字消息先回这条、再回 reply，两次认领同一个 id，
            // claimUserMessageId 里的「认过就不再找」保证不会把 id 错发给更早那条。
            if let mid = msg.messageId {
                if (msg.kind ?? "text") == "image" {
                    claimImageMessageId(mid, atts: msg.atts ?? [])
                } else {
                    claimUserMessageId(mid, conv: msg.conversation ?? ChatViewModel.mainConv)
                }
            }

        case "message_deleted":
            // 谁删的都一样处理（服务端不排除发起端）：本地还有这条就移除，已经没有就当没事。
            if let mid = msg.messageId { removeBlock(serverId: mid) }

        case "message_restored":
            // 回收站找回：往正确位置插一条旧消息，每端各写一遍必然各错各的 —— 重拉那个会话。
            reloadConv(msg.conversation ?? activeConv)

        case "device_presence":
            loadDevices()  // 设备上下线 → 刷新联系人列表（在线状态 / 能力目录）

        case "inspiration_saved", "inspiration_updated", "inspiration_deleted":
            // 灵感变更（可能来自任意端）→ 通知灵感页刷新。
            NotificationCenter.default.post(name: .inspirationChanged, object: nil)

        case "reminder_updated", "reminder_deleted":
            // 提醒变更（秘书在聊天里建/改/撤，或别的端改的）→ **立刻拉一次**。
            // 不能等下一轮定时同步：用户说「5 分钟后提醒我」，秘书答应了，
            // 这台手机却还不知道有这条，到点什么也不会响。
            // 拉完 ReminderStore 会顺手重排本机的本地通知（applyMerged 里做）。
            ReminderStore.shared.syncNow()

        case "task_update":   // 引擎里程碑 + 电脑操控共用（B 批起旧事件名已死）
            handleTaskUpdate(msg)

        case "device_message":
            let conv = msg.conversation ?? ChatViewModel.mainConv
            let s = store(conv)
            let ts = msg.created_at ?? ISO8601DateFormatter().string(from: Date())
            if msg.chatRole == "device" {
                s.blocks.append(.device(id: UUID(), text: msg.chatText ?? "", ts: ts))
            } else {
                s.blocks.append(.assistant(ChatBlock.AssistantBlock(thinking: false, streaming: false, text: msg.chatText ?? "", trace: [], traceOpen: false, ts: ts)))
            }
            setPreview(conv, msg.chatText ?? "", ts)
            reflect(conv)

        case "confirm_request":
            // confirm_id 是这张确认卡的单号（B 批改名：原来叫 task_id，和真任务 id 打架）。
            if let confirmId = msg.confirmId {
                let conv = msg.conversation ?? ChatViewModel.mainConv
                let s = store(conv)
                let exists = s.blocks.contains { if case .confirm(let c) = $0 { return c.confirmId == confirmId } else { return false } }
                if !exists {
                    s.blocks.append(.confirm(ChatBlock.ConfirmBlock(confirmId: confirmId, summary: msg.confirmSummary ?? L("chat.status.confirmRequired"), resolved: nil)))
                    confirmPending = ConfirmRequest(confirmId: confirmId, summary: msg.confirmSummary ?? "")
                    reflect(conv)
                }
                _ = autoApproveIfEnabled(confirmId)
            }

        case "operate_locate_request":
            if let askId = msg.askId, let img = msg.locateImageUrl {
                let s = mainStore
                let exists = s.blocks.contains { if case .locate(let l) = $0 { return l.askId == askId } else { return false } }
                if !exists {
                    s.blocks.append(.locate(ChatBlock.LocateBlock(
                        askId: askId, runId: msg.runId ?? "", imageUrl: img,
                        target: msg.locateTarget ?? "",
                        hint: msg.locateHint ?? L("operate.locate.hint"),
                        resolved: nil)))
                    reflect(ChatViewModel.mainConv)
                }
            }

        case "question_card":
            // 问答卡不落 messages 表，只走广播；服务端会在新连接握手时补发未答的卡，
            // 所以这里必须按 card_id 去重，否则重连一次就多出一张一模一样的卡。
            if let cardId = msg.cardId, !cardId.isEmpty {
                let conv = msg.conversation ?? ChatViewModel.mainConv
                let s = store(conv)
                let exists = s.blocks.contains {
                    if case .question(let q) = $0 { return q.cardId == cardId } else { return false }
                }
                let items = (msg.cardQuestions ?? []).compactMap { ChatBlock.QuestionItem(json: $0) }
                if !exists && !items.isEmpty {
                    let title = msg.cardTitle ?? ""
                    s.blocks.append(.question(ChatBlock.QuestionBlock(
                        cardId: cardId, title: title, questions: items)))
                    setPreview(conv, title.isEmpty ? "有几个问题要确认" : title,
                               ISO8601DateFormatter().string(from: Date()))
                    reflect(conv)
                }
            }

        case "question_resolved":
            // 别的端已经答过了 → 本端把卡标成已完成，别重复作答。
            if let cardId = msg.cardId { resolveQuestion(cardId: cardId) }

        case "history_cleared":
            // 别的端清空了某个会话 → 本端同步清空，并留一行说明，
            // 否则用户会以为是自己这边把消息弄丢了。
            let conv = msg.conversation ?? ChatViewModel.mainConv
            let s = store(conv)
            cancelUploads(in: s)
            s.blocks.removeAll()
            s.assistantIdx = nil
            s.taskMap.removeAll()
            s.oldestId = nil
            s.hasMoreHistory = false
            s.loaded = true
            previews[conv] = nil
            // 这一行以前有两个毛病，一起修了：
            //   1. 无条件插。广播发给所有在线端，本端自己点「清空」也会收到，
            //      结果是自己刚清完，聊天里立刻冒出一句「别的端清空了」——自己骗自己。
            //      现在拿广播里的 by 跟本端 clientId 比（服务端回填，见 app.py /history/clear）。
            //   2. 文案写死「电脑端」。清空的可能是另一台手机、也可能是网页端，
            //      服务端只告诉我们「不是你」，说不出是谁，所以不再瞎猜具体是哪一端。
            if msg.clearedBy != NetworkConfig.shared.clientId {
                s.blocks.append(.note(ChatBlock.NoteBlock(text: "其它端清空了这段聊天历史")))
            }
            reflect(conv)

        case "confirm_resolved":
            resolveConfirm(confirmId: msg.confirmId ?? "", approved: msg.confirmApproved ?? false)

        case "chat_message":
            // 其它端发出的消息（跨端同步），落到它所属的会话。
            // 批次 011 起多了两种形状：role/kind=system（别的端停了回复留下的提示行）、
            // 带 meta 的半截中断（那边停在一半，这边也该看到「只写到这里」）。
            let conv = msg.conversation ?? ChatViewModel.mainConv
            let ts = msg.created_at ?? ISO8601DateFormatter().string(from: Date())
            let s = store(conv)
            if (msg.kind ?? "text") == "image" {
                // 别的端发的图片消息。它只有 file_id，没有本地数据 —— 直接从服务端取图。
                // 重连补发会重复推同一条，按 id 去重。
                let atts = (msg.atts ?? []).filter { !$0.isEmpty }
                if let mid = msg.messageId,
                   s.blocks.contains(where: { if case .image(let i) = $0 { return i.serverId == mid } else { return false } }) {
                    return
                }
                // 一张都没有就当没这条：只更预览 / 标未读的话，联系人那行冒个红点、
                // 点进去什么都没有。
                guard !atts.isEmpty else { return }
                s.blocks.append(.image(ChatBlock.ImageBlock(
                    atts: atts, ts: ts, serverId: msg.messageId, state: .sent)))
                setPreview(conv, L("chat.imageMsgPreview"), ts)
                reflect(conv)
                return
            }
            if msg.chatRole == "system" || msg.kind == "system" {
                s.blocks.append(.note(ChatBlock.NoteBlock(
                    text: msg.chatText ?? "", serverId: msg.messageId, toolsRun: msg.metaTools)))
            } else if msg.chatRole == "user" {
                // 重连时服务端会补发，同 id 已经在了就别重复画一条。
                if let mid = msg.messageId,
                   s.blocks.contains(where: { if case .user(let u) = $0 { return u.serverId == mid } else { return false } }) {
                    return
                }
                s.blocks.append(.user(ChatBlock.UserBlock(
                    text: msg.chatText ?? "", ts: ts, serverId: msg.messageId,
                    quote: msg.metaQuote, atts: msg.atts ?? [])))
            } else if msg.chatRole == "assistant" {
                s.blocks.append(.assistant(ChatBlock.AssistantBlock(
                    thinking: false, streaming: false, text: msg.chatText ?? "",
                    trace: [], traceOpen: false, ts: ts, serverId: msg.messageId,
                    interrupted: msg.metaInterrupted, toolsRun: msg.metaTools)))
            }
            setPreview(conv, msg.chatText ?? "", ts)
            reflect(conv)

        case "error":
            stopReplyTimeout()
            let s = store(streamConv)
            if s.assistantIdx != nil {
                if var a = currentAssistant(streamConv) { a.thinking = false; a.streaming = false; updateAssistant(a, streamConv) }
                s.assistantIdx = nil
            }
            s.blocks.append(.error(id: UUID(), text: msg.errorMessage ?? L("chat.status.error")))
            reflect(streamConv)

        default: break
        }
    }

    /// 按服务端消息 id 移除一个块（message_deleted 广播用）。
    /// 扫**所有会话**而不只当前那个：广播不带足够信息保证我们猜对会话，而 id 是全局唯一的。
    /// 删掉的位置会让后面块的下标整体前移，由 `dropBlocks` 统一修正
    ///（被删的那条一定不是任务卡 —— 任务卡没有 serverId —— 所以只用前移，不用摘条目）。
    private func removeBlock(serverId: Int) {
        guard serverId > 0 else { return }
        for (conv, s) in stores {
            guard let i = s.blocks.firstIndex(where: { $0.serverId == serverId }) else { continue }
            dropBlocks(at: i, in: s)
            refresh(conv)
            return
        }
    }

    /// 重拉一个会话的历史（message_restored 用）。找回的消息要插回原来的位置，
    /// 那份排序逻辑每端各写一遍必然各错各的 —— 直接把这段重新拉一次最省事也最不会错。
    private func reloadConv(_ conv: String) {
        guard let s = stores[conv] else { return }
        // 正在等回复的会话不冲：重拉会把占位块连同 assistantIdx 一起抹掉，
        // 之后的 delta / reply 全部落空，这一轮的回复就在界面上人间蒸发了。
        // 找回一条旧消息不急在这一秒 —— 等这一轮结束后下次进这个会话自然会看到。
        guard s.assistantIdx == nil else { return }
        // 正在传图的也不冲：图片消息不设占位块，assistantIdx 拦不住它 ——
        // 冲掉之后上传照跑，跑完却找不到块，这条消息就这么无声无息地没了。
        guard !s.blocks.contains(where: {
            if case .image(let i) = $0 { return i.state == .uploading || i.state == .awaitingReceipt }
            else { return false }
        }) else { return }
        Task {
            let messages = await HTTPService.shared.fetchHistory(limit: 40, conversation: conv)
            await MainActor.run {
                // 再确认一次：这一趟 HTTP 是异步的，回来时可能已经有新的一轮在跑、
                // 或者用户刚发了一条图。前面那道守卫挡的是「发起的那一刻」。
                guard s.assistantIdx == nil else { return }
                guard !s.blocks.contains(where: {
                    if case .image(let i) = $0 { return i.state == .uploading || i.state == .awaitingReceipt }
                    else { return false }
                }) else { return }
                s.blocks = messages.compactMap { self.historyToBlock($0) }
                // 下标类的状态全部作废：块换了一整批，旧下标指到哪儿都不作数。
                // 顺带说明重拉的代价：任务卡 / 确认卡 / 问答卡 / locate 卡都不落 messages 表，
                // 重拉之后它们会消失。这是「插回原位置的排序逻辑每端各写一遍必然各错各的」
                // 换来的，两害相权取其轻 —— PC 端 reloadConv 也是这么做的。
                s.taskMap.removeAll()
                s.oldestId = messages.first?.id
                s.hasMoreHistory = messages.count >= 40
                self.refresh(conv)
            }
        }
    }

    // 某会话正在流式输出的助手气泡
    private func currentAssistant(_ conv: String) -> ChatBlock.AssistantBlock? {
        let s = store(conv)
        guard let idx = s.assistantIdx, idx < s.blocks.count, case .assistant(let a) = s.blocks[idx] else { return nil }
        return a
    }

    private func updateAssistant(_ a: ChatBlock.AssistantBlock, _ conv: String) {
        let s = store(conv)
        guard let idx = s.assistantIdx, idx < s.blocks.count else { return }
        s.blocks[idx] = .assistant(a)
        reflect(conv)
    }

    // 任务进度卡按 task_id 建：操控落库就是一条单步任务，聊天卡和任务页指同一条。
    private func handleTaskUpdate(_ msg: ChatMessage) {
        guard let id = msg.taskId else { return }
        let conv = msg.conversation ?? ChatViewModel.mainConv
        let s = store(conv)
        let overall = msg.taskOverall ?? (msg.taskStatus == "done" ? 1.0 : 0.0)
        let pct = min(100, max(0, Int(overall * 100)))

        if let idx = s.taskMap[id] {
            if case .task(var j) = s.blocks[idx] {
                j.pct = pct
                j.status = msg.taskStatus ?? j.status
                j.message = msg.taskMessage ?? j.message
                if let goal = msg.taskGoal { j.goal = goal }
                if let confirmId = msg.confirmId, msg.taskNeedsConfirm == true {
                    j.confirmId = confirmId
                    if autoApproveIfEnabled(confirmId) { j.confirmId = nil }
                }
                if let results = msg.taskResults { j.results = results }
                s.blocks[idx] = .task(j)
                if msg.taskStatus == "done" {
                    s.blocks.append(.done(id: UUID(), goal: j.goal, results: j.results ?? []))
                }
            }
        } else {
            let goal = msg.taskGoal ?? L("chat.status.task")
            let block = ChatBlock.taskBlock(
                taskId: id, goal: goal, pct: pct,
                status: msg.taskStatus ?? "running",
                message: msg.taskMessage ?? "",
                confirmId: msg.taskNeedsConfirm == true ? msg.confirmId : nil,
                results: msg.taskResults
            )
            s.taskMap[id] = s.blocks.count
            s.blocks.append(block)
        }
        setPreview(conv, msg.taskMessage ?? msg.taskGoal ?? "", ISO8601DateFormatter().string(from: Date()))
        reflect(conv)
    }

    // 跨所有会话统一更新某张确认单的状态（任务卡内嵌授权 + 独立确认卡都认 confirm_id）
    private func resolveConfirm(confirmId: String, approved: Bool) {
        for (conv, s) in stores {
            var changed = false
            for i in s.blocks.indices {
                if case .task(var j) = s.blocks[i], j.confirmId == confirmId {
                    j.confirmId = nil
                    j.message = approved ? L("chat.status.approved") : L("chat.status.denied")
                    s.blocks[i] = .task(j)
                    changed = true
                }
                if case .confirm(var c) = s.blocks[i], c.confirmId == confirmId {
                    c.resolved = approved ? .approved : .denied
                    s.blocks[i] = .confirm(c)
                    changed = true
                }
            }
            if changed && conv == activeConv { blocks = s.blocks }
        }
    }
}

// MARK: - Chat Blocks
enum ChatBlock: Identifiable {
    case user(UserBlock)
    /// 我发的一条图片消息（批次 011 ③）。**图文分条**：图片单独成条，配的文字紧跟一条 ——
    /// 塞进一个气泡的话，用户点「删除」时说不清删的是图还是话。
    case image(ImageBlock)
    case assistant(AssistantBlock)
    case device(id: UUID, text: String, ts: String?)
    case task(TaskBlock)
    case done(id: UUID, goal: String, results: [[String: String]])
    case confirm(ConfirmBlock)
    case locate(LocateBlock)
    case question(QuestionBlock)
    /// 居中的一行系统说明（如「电脑端清空了这段聊天历史」「你停了这次回复…」）。
    /// 不是气泡，不属于任何一方，**不接长按菜单**（`messageMenu.byKind.systemLine`：
    /// 那不是消息，给它一个只有「复制」的菜单反而暗示它是条）。
    case note(NoteBlock)
    case error(id: UUID, text: String)

    /// 这个块对应的服务端消息 id（没有落库的块 —— 任务卡、确认卡、问答卡 —— 是 nil）。
    /// 删除按它找块，「跳回被引用的那条」也按它找。
    var serverId: Int? {
        switch self {
        case .user(let u): return u.serverId
        case .image(let i): return i.serverId
        case .assistant(let a): return a.serverId
        case .note(let n): return n.serverId
        default: return nil
        }
    }

    // 稳定 id：每个块创建时就固定，供 SwiftUI 做行身份识别。
    var id: String {
        switch self {
        case .user(let u): return u.id.uuidString
        case .image(let i): return i.id.uuidString
        case .assistant(let a): return a.id.uuidString
        case .device(let id, _, _): return id.uuidString
        case .task(let j): return j.id.uuidString
        case .done(let id, _, _): return id.uuidString
        case .confirm(let c): return c.id.uuidString
        case .locate(let l): return l.id.uuidString
        case .question(let q): return q.id.uuidString
        case .note(let n): return n.id.uuidString
        case .error(let id, _): return id.uuidString
        }
    }
}

extension ChatBlock {
    /// 我发出去的一条消息。批次 011 起它不只有文字：
    ///   serverId  服务端消息 id（sendMessage 之后由 reply 的 user_message_id / message_saved 回执认领）。
    ///             **引用和删除都指着它** —— 没有 id 的消息删不了、也没法被引用（没有对象可指）。
    ///   quote     引用注脚：气泡顶部那块「引用 X」，点它跳回原消息。
    ///   atts      附件 file_id（批次 013 带附件的文字消息；纯图片消息走 .image 块）。
    ///   failure   发出去失败了、以及为什么。气泡压到 .72、下面跟一行原因 + 动作，
    ///             长按菜单把「重新发送」置顶。
    struct UserBlock: Hashable {
        let id = UUID()
        var text: String
        var ts: String?
        var serverId: Int?
        var quote: ChatQuote?
        var atts: [String] = []
        var failure: SendFailure?

        var failed: Bool { failure != nil }
    }

    /// 一条图片消息。**一条 = N 张图（N ≤ 9），不是 N 条** —— 预览器里左右切的就是这一条里的图。
    ///
    /// 上传是**逐张顺序**做的，`atts` 攒着已经传成功的 file_id：中途失败/取消之后点「重新发送」
    /// 从断的那张续传，已经传上去的不重传（重传会在服务端留孤儿文件，PC 端同一套做法）。
    struct ImageBlock: Hashable {
        let id = UUID()
        /// 已经上传成功的 file_id，按 `data` 的顺序前缀对齐。
        var atts: [String] = []
        /// 每张图的本地原始数据。**上传成功之后也留着** —— 「重新发送」要用。
        /// 别的端同步来的、以及拉历史拿到的那些只有 `atts` 没有本地数据，所以给默认空数组。
        var data: [Data] = []
        var ts: String?
        var serverId: Int?
        var state: State = .uploading
        /// 已传字节 / 总字节。meta 行「正在上传 · 1.8 MB / 2.9 MB」用它。
        var sentBytes: Int = 0
        var totalBytes: Int = 0
        /// 正在传第几张（= `atts.count`）的那一张自己的进度 0…1。稿把进度环画在**格子上**，
        /// 所以每格要各自的百分比：传完的不盖罩、正在传的走这个值、还没轮到的盖 0%。
        var currentFrac: Double = 0
        /// 失败原因（`state == .failed` 时给的那一行）。
        var failReason: String = ""
        /// 单图的宽高比，**发送时算一次存下来**。认领回执之后本地 data 会被清掉，
        /// 现算的话比例会在那一帧从真实比例跳成占位比例、图两边冒出灰边。
        var ratioHint: CGFloat?

        enum State: Hashable {
            case uploading
            /// 图都传完、WS 也送出去了，在等 message_saved。
            /// 单列一档是因为**这一档不能再「取消上传」** —— 服务端已经有这条了，
            /// 撤掉本地只会让用户再发一次，变成两条。
            case awaitingReceipt
            case sent, failed
        }

        var count: Int { max(data.count, atts.count) }
    }

    /// 为什么没发出去。**分档不是为了好看** —— `replyCancel.textFailed` 要求原因照实说、
    /// 动作跟着原因分：没连上给「重新发送 + 检查服务端」，服务端拒了只给「重新发送」
    ///（服务端都回话了，让人去检查地址是把人往错的方向支）。
    enum SendFailure: Hashable {
        /// WS 根本没连上，这一帧压根没出门。
        case offline
        /// 服务端收到了但拒了这条。**现在还没有生产者** —— 服务端的 `error` 事件不带
        /// 「是哪条用户消息出的错」，认不到具体气泡上。等服务端补了归属再接。
        case rejected
    }

    /// 居中的系统提示行。两个来源，形态一样但性质不同：
    ///   · 本地生成的（「其它端清空了这段聊天历史」）—— serverId 为空，服务端没有这条；
    ///   · 服务端落库的（取消收尾那句「你停了这次回复 · 消息已经发出去了，秘书没回」）——
    ///     它是真消息，进回收站也认这个 id，所以要留着。
    /// toolsRun 只有取消收尾那条会有：跟一条琥珀行说清停之前动过什么（`replyCancel.toolKept`）。
    struct NoteBlock: Hashable {
        let id = UUID()
        var text: String
        var serverId: Int?
        var toolsRun: [ChatToolRun] = []
    }

    struct AssistantBlock: Hashable {
        let id = UUID()
        var thinking: Bool
        var streaming: Bool
        var text: String
        var trace: [String]
        var traceOpen: Bool
        var ts: String?
        /// 服务端消息 id（reply 的 message_id / 历史里带）。删除与引用要它。
        var serverId: Int?
        /// 用户停在半截（批次 011 ①的第一种收尾）：时间戳后面缀「只写到这里」，不在正文里加括号。
        var interrupted: Bool = false
        /// 停之前已经跑掉的工具：卡下面那行琥珀提示「已经动过 X」靠它说得具体。
        var toolsRun: [ChatToolRun] = []
    }

    /// 任务进度卡（task_update）。taskId 就是任务 id；confirmId 是嵌在卡里的
    /// 授权单号（operate 的 confirm_id），不是任务 id —— B 批把这两个概念拆开了。
    struct TaskBlock: Hashable {
        let id = UUID()
        var taskId: String
        var goal: String
        var pct: Int
        var status: String
        var message: String
        var confirmId: String?
        var results: [[String: String]]?
    }

    struct ConfirmBlock: Hashable {
        let id = UUID()
        var confirmId: String
        var summary: String
        var resolved: ConfirmStatus?
    }

    // operate 人工求助：显示截图；用户可①拖箭头指位 ②文字纠偏 ③暂停我来（之后可继续）。
    struct LocateBlock: Hashable {
        let id = UUID()
        var askId: String          // 这次求助的单号（回答用它）；一次操控可能求助多次
        var runId: String          // 这次操控运行的编号（「暂停后继续」用它）
        var imageUrl: String       // 服务端相对路径（如 /files/<id>），显示时拼 baseUrl
        var target: String
        var hint: String
        var resolved: LocateStatus?
    }

    /// 问答卡里的一道题。字段与服务端 questions.normalize() 的输出一一对应。
    struct QuestionItem: Hashable, Identifiable {
        var id: String
        var text: String
        var multi: Bool
        var options: [String]
        var optional: Bool
        /// 服务端**强制**为 true（每题都留一个「自己填」的口子），这里仍然按收到的值走，
        /// 不在客户端写死 —— 写死了协议改动就发现不了。
        var allowCustom: Bool

        init?(json: [String: Any]) {
            guard let id = json["id"] as? String, let text = json["text"] as? String,
                  !id.isEmpty, !text.isEmpty else { return nil }
            self.id = id
            self.text = text
            self.multi = json["multi"] as? Bool ?? false
            self.options = (json["options"] as? [String]) ?? []
            self.optional = json["optional"] as? Bool ?? false
            self.allowCustom = json["allow_custom"] as? Bool ?? true
        }
    }

    /// 问答卡（QuestionCard）：分页式多题，一次性提交。
    /// 作答过程（当前第几题 / 选了什么 / 自己填了什么）就存在这个块里 ——
    /// 放 ViewModel 的全局字段会让两张同时在场的卡互相踩。
    struct QuestionBlock: Hashable {
        let id = UUID()
        var cardId: String
        var title: String
        var questions: [QuestionItem]
        /// 当前题序号。
        var at: Int = 0
        /// 题目 id → 选中的选项文本。
        var picked: [String: [String]] = [:]
        /// 题目 id → 自己填的内容。
        var custom: [String: String] = [:]
        /// 已提交（本端提交，或别的端先答了收到 question_resolved）。
        var done: Bool = false
        /// 提交后展示的「题 → 答」配对，供用户回看自己答了什么。
        var answered: [(q: String, v: String)] = []

        static func == (l: QuestionBlock, r: QuestionBlock) -> Bool {
            l.id == r.id && l.at == r.at && l.picked == r.picked
                && l.custom == r.custom && l.done == r.done
                && l.answered.map(\.v) == r.answered.map(\.v)
        }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }

        /// 某题是否已经答了（可选题永远算答了）。
        func filled(_ q: QuestionItem) -> Bool {
            if q.optional { return true }
            if !(picked[q.id] ?? []).isEmpty { return true }
            return !(custom[q.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        var allFilled: Bool { questions.allSatisfy { filled($0) } }
    }

    enum ConfirmStatus: Hashable { case approved, denied }
    // located=已指位；feedbackSent=已发纠偏；paused=已暂停(可继续)；resumed=已点继续
    enum LocateStatus: Hashable { case located, feedbackSent, paused, resumed }

    // Helper factory methods (enums don't provide these automatically with labels)
    static func assistantBlock(text: String, ts: String?) -> ChatBlock {
        .assistant(AssistantBlock(thinking: false, streaming: false, text: text, trace: [], traceOpen: false, ts: ts))
    }

    static func assistantBlock(thinking: Bool, streaming: Bool, text: String, trace: [String] = [], traceOpen: Bool = true, ts: String?) -> ChatBlock {
        .assistant(AssistantBlock(thinking: thinking, streaming: streaming, text: text, trace: trace, traceOpen: traceOpen, ts: ts))
    }

    static func assistantBlock(_ data: AssistantBlock) -> ChatBlock {
        .assistant(data)
    }

    static func taskBlock(taskId: String, goal: String, pct: Int, status: String, message: String, confirmId: String?, results: [[String: String]]?) -> ChatBlock {
        .task(TaskBlock(taskId: taskId, goal: goal, pct: pct, status: status, message: message, confirmId: confirmId, results: results))
    }
}

// MARK: - 取消收尾的琥珀行（批次 011 ①）
//
// 「⚠︎ 停之前它已经建好了提醒「明天十点打给张伟」。这条留着，不跟着撤销。 [去看提醒]」
// 稿方点名否掉了笼统的「已执行的操作不会撤销」：没执行过工具时它是句废话，
// 执行过时又不说到底留下了什么。所以只在跑过**会留下东西的**工具时才出这一行 ——
// 只读查询（search / list / web_search）停了就停了，说「不跟着撤销」反而吓人。
// 这张表与 PC 端 chat.ts 的 KEPT_TOOLS 一一对应，改一处要改两处。
@MainActor
enum ChatKeptTool {
    /// 一条留痕的说法：动词短语 + 去哪儿看那样东西。两个文案都是 key，不是成品字符串 ——
    /// 这一行是给人看的，英文界面下不能冒出半句中文。
    struct Kept {
        let verbKey: String
        let route: UmbraRoute
        let buttonKey: String
    }

    static let table: [String: Kept] = [
        "create_reminder":  Kept(verbKey: "chat.kept.createReminder", route: .remList,   buttonKey: "chat.goSeeReminder"),
        "update_reminder":  Kept(verbKey: "chat.kept.updateReminder", route: .remList,   buttonKey: "chat.goSeeReminder"),
        "delete_reminder":  Kept(verbKey: "chat.kept.deleteReminder", route: .remList,   buttonKey: "chat.goSeeReminder"),
        "add_money_entry":  Kept(verbKey: "chat.kept.addMoney",       route: .moneyList, buttonKey: "chat.goSeeMoney"),
        "add_phrase":       Kept(verbKey: "chat.kept.addPhrase",      route: .mePhrases, buttonKey: "chat.goSeePhrases"),
        "save_inspiration": Kept(verbKey: "chat.kept.saveIdea",       route: .inspList,  buttonKey: "chat.goSeeIdeas"),
        "create_task":      Kept(verbKey: "chat.kept.createTask",     route: .taskList,  buttonKey: "chat.goSeeTasks"),
    ]

    /// 从 args（JSON 字符串，服务端已截到 200）里捞一个能指认对象的词：提醒的 text、任务的 name…
    /// 捞不到就只说动词（「停之前它已经建好了提醒。」），**不编一个名字出来**。
    static func object(of args: String) -> String {
        guard let data = args.data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let raw = (d["text"] as? String) ?? (d["title"] as? String) ?? (d["name"] as? String) ?? ""
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        return L("chat.keptObject", s.count > 24 ? String(s.prefix(24)) + "…" : s)
    }

    /// 一串工具 → 琥珀行整句 + 该跳哪儿。一个「会留下东西」的都没有就返回 nil（这一行不出）。
    static func line(for tools: [ChatToolRun]) -> (text: String, route: UmbraRoute, button: String)? {
        let kept = tools.compactMap { t in table[t.name].map { (run: t, spec: $0) } }
        guard let first = kept.first else { return nil }
        let parts = kept.map { "\(L($0.spec.verbKey))\(object(of: $0.run.args))" }
        let tail = L(kept.count > 1 ? "chat.toolsKeptTailMany" : "chat.toolsKeptTailOne")
        return (L("chat.toolsKeptHead") + parts.joined(separator: L("chat.keptJoin")) + tail,
                first.spec.route, L(first.spec.buttonKey))
    }
}

// MARK: - Confirm Request
struct ConfirmRequest: Identifiable {
    let id: String
    let summary: String

    init(confirmId: String, summary: String) {
        self.id = confirmId
        self.summary = summary
    }
}
