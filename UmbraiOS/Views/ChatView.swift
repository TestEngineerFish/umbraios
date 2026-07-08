import SwiftUI

// MARK: - Time Formatter
private func parseServerDate(_ ts: String) -> Date? {
    // 1) 严格 ISO8601（带/不带小数秒）
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: ts) { return d }
    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: ts) { return d }

    // 2) 常见服务端格式（无时区 / 空格分隔 / 微秒），按 UTC 解析
    let patterns = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss.SSSSSS",
        "yyyy-MM-dd HH:mm:ss.SSS",
        "yyyy-MM-dd HH:mm:ss"
    ]
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone(identifier: "UTC")
    for p in patterns {
        df.dateFormat = p
        if let d = df.date(from: ts) { return d }
    }
    return nil
}

@MainActor
private func formatMessageTime(_ ts: String?) -> String? {
    guard let ts = ts, let date = parseServerDate(ts) else { return nil }

    let calendar = Calendar.current
    let now = Date()
    let components = calendar.dateComponents([.day], from: date, to: now)
    let daysAgo = components.day ?? 0

    let locale = LanguageManager.shared.locale
    let timeFormatter = DateFormatter()
    timeFormatter.locale = locale
    timeFormatter.dateFormat = "HH:mm"

    if daysAgo <= 0 {
        return timeFormatter.string(from: date)
    } else if daysAgo == 1 {
        return L("date.yesterday", timeFormatter.string(from: date))
    } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
        let monthFormatter = DateFormatter()
        monthFormatter.locale = locale
        monthFormatter.dateFormat = L("date.monthDayTime")
        return monthFormatter.string(from: date)
    } else {
        let fullFormatter = DateFormatter()
        fullFormatter.locale = locale
        fullFormatter.dateFormat = L("date.fullDateTime")
        return fullFormatter.string(from: date)
    }
}

// MARK: - Image URL Detection
private func isImageUrl(_ url: String) -> Bool {
    let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]
    if let ext = url.components(separatedBy: ".").last?.components(separatedBy: "?").first?.lowercased() {
        return imageExtensions.contains(ext)
    }
    // Check for common image URL patterns
    if url.contains("chatglm") || url.contains("bigmodel") || url.contains("cogview") || url.contains("aigc") {
        return true
    }
    if url.contains("/files/") {
        return true
    }
    return false
}

// MARK: - Chat View
struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var viewModel: ChatViewModel
    @State private var scrollTarget: String?
    @State private var isScrolledToBottom: Bool = true
    @StateObject private var tts = TTSService.shared
    @StateObject private var speech = SpeechRecognizer()
    @FocusState private var inputFocused: Bool
    @State private var showNewChatConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            chatHeader

            // Conversation switcher (与秘书 + 各设备只读)
            if viewModel.conversationOrder.count > 1 {
                conversationBar
            }

            // Messages
            messageList

            if viewModel.isReadonly(viewModel.activeConv) {
                readonlyBanner
            } else {
                // Quick chips
                quickChips

                // Input bar
                inputBar
            }
        }
        .background(umbraColor(\.bg))
        .sheet(isPresented: $viewModel.showAttachSheet) {
            AttachSheet { action in
                viewModel.showAttachSheet = false
                handleAttach(action)
            }
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $viewModel.showLightbox) {
            ImageLightboxView(imageURL: viewModel.lightboxImageURL)
        }
    }

    private func handleAttach(_ action: AttachSheet.Action) {
        // 目前仅关闭弹窗；具体的相册/拍照/文件选择接入后端上传后再实现。
        switch action {
        case .voice:
            inputFocused = false
            speech.toggle { text in
                if !text.isEmpty { viewModel.draft += text }
            }
        default:
            break
        }
    }

    // MARK: - Header
    private var chatHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("U")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text("Umbra")
                        .font(.system(size: 15, weight: .semibold))
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(L("chat.connected"))
                        .font(.system(size: 11))
                        .foregroundColor(.umbraMuted)
                }
            }

            Spacer()

            Button {
                showNewChatConfirm = true
            } label: {
                Image(systemName: "trash")
                    .frame(width: 34, height: 34)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .background(umbraColor(\.card))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(umbraColor(\.border)),
            alignment: .bottom
        )
        .confirmationDialog(L("chat.clear.confirm"), isPresented: $showNewChatConfirm, titleVisibility: .visible) {
            Button(L("chat.clear.title"), role: .destructive) { viewModel.clearActiveHistory() }
            Button(L("common.cancel"), role: .cancel) { }
        }
    }

    // MARK: - Conversation switcher
    private var conversationBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.conversationOrder, id: \.self) { conv in
                    let on = conv == viewModel.activeConv
                    let readonly = viewModel.isReadonly(conv)
                    Button {
                        viewModel.switchConversation(conv)
                    } label: {
                        HStack(spacing: 5) {
                            if readonly {
                                Image(systemName: "lock.fill").font(.system(size: 9))
                            }
                            Text(viewModel.convLabel(conv))
                                .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                            if viewModel.unread.contains(conv) && !on {
                                Circle().fill(Color.orange).frame(width: 6, height: 6)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(on ? Color.orange.opacity(0.14) : umbraColor(\.card))
                        .foregroundColor(on ? .orangeText : umbraColor(\.text))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(on ? Color.orange : umbraColor(\.border), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(umbraColor(\.card))
        .overlay(
            Rectangle().frame(height: 1).foregroundColor(umbraColor(\.border)),
            alignment: .bottom
        )
    }

    // MARK: - Read-only banner（设备会话默认只读）
    private var readonlyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 12))
            Text(L("chat.conv.readonly"))
                .font(.system(size: 12))
            Spacer()
        }
        .foregroundColor(.umbraMuted)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(umbraColor(\.bar))
        .overlay(
            Rectangle().frame(height: 1).foregroundColor(umbraColor(\.border)).offset(y: -1),
            alignment: .top
        )
    }

    // MARK: - Messages
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 15) {
                    if viewModel.blocks.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(viewModel.blocks.enumerated()), id: \.element.id) { index, block in
                            blockView(block, at: index)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
                .id("bottom")
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.blocks.count) { _ in
                if isScrolledToBottom || viewModel.stickToBottom {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 180)
            Text("U")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 56, height: 56)
                .background(Color.orange)
                .clipShape(RoundedRectangle(cornerRadius: 15))

            Text(L("chat.empty.title"))
                .font(.system(size: 16, weight: .semibold))

            Text(L("chat.empty.subtitle"))
                .font(.system(size: 12.5))
                .foregroundColor(.umbraMuted)
                .multilineTextAlignment(.center)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                chipSuggestion(L("chat.suggestion.summary"))
                chipSuggestion(L("chat.suggestion.screenshot"))
                chipSuggestion(L("chat.suggestion.tool"))
            }
            .padding(.horizontal, 20)
            Spacer()
        }
    }

    private func chipSuggestion(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .padding(.vertical, 7)
            .padding(.horizontal, 13)
            .background(umbraColor(\.card))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(umbraColor(\.border), lineWidth: 1)
            )
    }

    // MARK: - Block Views
    @ViewBuilder
    private func blockView(_ block: ChatBlock, at index: Int) -> some View {
        switch block {
        case .user(_, let text, let ts):
            VStack(alignment: .trailing, spacing: 4) {
                userBubble(text)
                if let timeStr = formatMessageTime(ts) {
                    Text(timeStr)
                        .font(.system(size: 10.5))
                        .foregroundColor(.umbraMuted)
                        .padding(.trailing, 4)
                }
            }
            .contextMenu { copyButton(text) }
        case .assistant(let data):
            VStack(alignment: .leading, spacing: 4) {
                assistantBubble(data, at: index)
                if !data.streaming, let timeStr = formatMessageTime(data.ts) {
                    Text(timeStr)
                        .font(.system(size: 10.5))
                        .foregroundColor(.umbraMuted)
                        .padding(.leading, 4)
                }
            }
            .contextMenu { copyButton(data.text) }
        case .device(_, let text, let ts):
            VStack(alignment: .trailing, spacing: 4) {
                deviceBubble(text)
                if let timeStr = formatMessageTime(ts) {
                    Text(timeStr)
                        .font(.system(size: 10.5))
                        .foregroundColor(.umbraMuted)
                        .padding(.trailing, 4)
                }
            }
            .contextMenu { copyButton(text) }
        case .job(let data):
            jobCard(data)
        case .done(_, let goal, let results):
            doneCard(goal: goal, results: results)
        case .confirm(let data):
            confirmCard(data)
        case .locate(let data):
            LocateCard(data: data,
                       onLocate: { nx, ny in viewModel.handleLocate(taskId: data.taskId, nx: nx, ny: ny) },
                       onCancel: { viewModel.handleLocateCancel(taskId: data.taskId) })
        case .error(_, let text):
            errorBubble(text)
        }
    }

    // 长按消息 → 复制到剪贴板（常见 IM 操作）。
    @ViewBuilder
    private func copyButton(_ text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
        } label: {
            Label(L("chat.copy"), systemImage: "doc.on.doc")
        }
    }

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(4)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(umbraColor(\.userBubble))
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 14,
                        bottomLeadingRadius: 14,
                        bottomTrailingRadius: 4,
                        topTrailingRadius: 14
                    )
                )
                .frame(maxWidth: UIScreen.main.bounds.width * 0.82, alignment: .trailing)
        }
    }

    // 设备上报（服务端↔设备只读流里的“设备”一侧）：靠右、灰底气泡区分秘书。
    private func deviceBubble(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(4)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(umbraColor(\.track))
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 14,
                        bottomLeadingRadius: 14,
                        bottomTrailingRadius: 4,
                        topTrailingRadius: 14
                    )
                )
                .overlay(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 14,
                        bottomLeadingRadius: 14,
                        bottomTrailingRadius: 4,
                        topTrailingRadius: 14
                    )
                    .stroke(umbraColor(\.border), lineWidth: 1)
                )
                .frame(maxWidth: UIScreen.main.bounds.width * 0.82, alignment: .trailing)
        }
    }

    private func assistantBubble(_ data: ChatBlock.AssistantBlock, at index: Int) -> some View {
        HStack(spacing: 9) {
            Text("U")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Color.orange)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 7) {
                // Trace toggle
                if !data.trace.isEmpty {
                    Button {
                        viewModel.toggleTrace(at: index)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11))
                                .rotationEffect(data.traceOpen ? .degrees(90) : .zero)
                            Text(L("chat.toolTrace", Int64(data.trace.count)))
                                .font(.system(size: 11.5))
                                .foregroundColor(.umbraMuted)
                        }
                    }
                }

                // Trace content
                if data.traceOpen && !data.trace.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(data.trace, id: \.self) { trace in
                            Text(trace)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.umbraMuted)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(umbraColor(\.track))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(umbraColor(\.border), lineWidth: 1)
                    )
                }

                // Main text
                VStack(alignment: .leading, spacing: 0) {
                    if data.thinking {
                        ThinkingDotsView()
                    }
                    if !data.text.isEmpty {
                        assistantTextContent(data.text)
                    }
                    if data.streaming && !data.text.isEmpty {
                        Text("▎")
                            .foregroundColor(.orange)
                            .blink()
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(umbraColor(\.card))
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 4,
                        bottomLeadingRadius: 14,
                        bottomTrailingRadius: 14,
                        topTrailingRadius: 14
                    )
                )
                .overlay(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 4,
                        bottomLeadingRadius: 14,
                        bottomTrailingRadius: 14,
                        topTrailingRadius: 14
                    )
                    .stroke(umbraColor(\.border), lineWidth: 1)
                )

                // TTS bar (only when text is not empty and not streaming)
                if !data.text.isEmpty && !data.streaming {
                    ttsBar(id: data.id.uuidString, text: data.text)
                }
            }
        }
        .frame(maxWidth: UIScreen.main.bounds.width * 0.88, alignment: .leading)
    }


    private func jobCard(_ data: ChatBlock.JobBlock) -> some View {
        let barColor: Color = {
            switch data.status {
            case "done": return .green
            case "failed": return .red
            default: return .orange
            }
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(data.goal)
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Text("\(data.pct)%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orangeText)
            }

            // Progress bar
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 999)
                    .fill(umbraColor(\.track))
                    .overlay(
                        RoundedRectangle(cornerRadius: 999)
                            .fill(barColor)
                            .frame(width: geo.size.width * CGFloat(data.pct) / 100),
                        alignment: .leading
                    )
            }
            .frame(height: 5)

            HStack(spacing: 6) {
                Circle()
                    .fill(barColor)
                    .frame(width: 6, height: 6)
                Text(data.message)
                    .font(.system(size: 12))
                    .foregroundColor(.umbraMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(umbraColor(\.card))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(umbraColor(\.border), lineWidth: 1)
        )
        .overlay(
            Rectangle()
                .fill(Color.orange)
                .frame(width: 3),
            alignment: .leading
        )
        .frame(maxWidth: UIScreen.main.bounds.width * 0.9)
    }

    private func doneCard(goal: String, results: [[String: String]]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("chat.done", goal))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(.green)

            ForEach(results.enumerated().map { $0 }, id: \.offset) { _, result in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 13))
                    if let title = result["title"] {
                        Text(title)
                            .foregroundColor(.orangeText)
                    }
                }
                .font(.system(size: 12.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.green, lineWidth: 1)
        )
        .overlay(
            Rectangle()
                .fill(Color.green)
                .frame(width: 3),
            alignment: .leading
        )
        .frame(maxWidth: UIScreen.main.bounds.width * 0.9)
    }

    private func confirmCard(_ data: ChatBlock.ConfirmBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orangeText)
                Text(L("chat.confirm.title"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.orangeText)
            }

            Text(data.summary)
                .font(.system(size: 12.5))
                .lineSpacing(4)
                .padding(.bottom, 12)

            HStack(spacing: 9) {
                Button(L("chat.confirm.approve")) {
                    viewModel.handleConfirm(taskId: data.taskId, approved: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .frame(maxWidth: .infinity)

                Button(L("chat.confirm.deny")) {
                    viewModel.handleConfirm(taskId: data.taskId, approved: false)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity)
            }

            Button(L("chat.confirm.approveAlways")) {
                viewModel.handleConfirmAlways(taskId: data.taskId)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .foregroundColor(.orangeText)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange, lineWidth: 1)
        )
        .frame(maxWidth: UIScreen.main.bounds.width * 0.9)
    }

    private func errorBubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundColor(.red)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.red.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.red.opacity(0.3), lineWidth: 1)
            )
            .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: .leading)
    }

    // MARK: - Quick Chips
    private var quickChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(L("chat.chip.summary")) { viewModel.draft = L("chat.chip.draft.summary") }
                chip(L("chat.chip.image")) { viewModel.draft = L("chat.chip.draft.image") }
                chip(L("chat.chip.computer")) { viewModel.draft = L("chat.chip.draft.computer") }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }

    private func chip(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.umbraMuted)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(umbraColor(\.card))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(umbraColor(\.border), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input Bar
    private var inputBar: some View {
        HStack(spacing: 9) {
            // Attach button
            Button {
                viewModel.showAttachSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20))
                    .frame(width: 38, height: 38)
                    .background(umbraColor(\.card))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(umbraColor(\.border), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            // Text field
            HStack(spacing: 6) {
                TextField(L("chat.input.placeholder"), text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .tint(Color.umbraOrange)
                    .lineLimit(1...4)
                    .frame(maxWidth: .infinity)
                    .focused($inputFocused)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button(L("chat.input.done")) { inputFocused = false }
                                .tint(Color.umbraOrange)
                        }
                    }

                Button {
                    inputFocused = false
                    speech.toggle { text in
                        if !text.isEmpty { viewModel.draft += text }
                    }
                } label: {
                    Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 19))
                        .foregroundColor(speech.isRecording ? Color.umbraOrange : .umbraMuted)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(umbraColor(\.card))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(umbraColor(\.border), lineWidth: 1)
            )

            // Send button
            Button {
                viewModel.send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? umbraColor(\.border) : .orange)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 9)
        .background(umbraColor(\.bar))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(umbraColor(\.border))
                .offset(y: -1),
            alignment: .top
        )
    }
}

// MARK: - Attach Sheet（加号 → 底部弹出更多操作，匹配设计稿）
struct AttachSheet: View {
    enum Action { case photo, camera, file, voice }
    let onSelect: (Action) -> Void

    private var items: [(Action, String, String)] {
        [
            (.photo, "photo.on.rectangle", L("chat.attach.album")),
            (.camera, "camera", L("chat.attach.camera")),
            (.file, "doc", L("chat.attach.file")),
            (.voice, "mic", L("chat.attach.voice"))
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(L("chat.attach.add"))
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 14)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    Button {
                        onSelect(item.0)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: item.1)
                                .font(.system(size: 18))
                                .foregroundColor(Color.umbraOrange)
                                .frame(width: 40, height: 40)
                                .background(umbraColor(\.orangeSoft))
                                .clipShape(RoundedRectangle(cornerRadius: 11))
                            Text(item.2)
                                .font(.system(size: 15))
                                .foregroundColor(umbraColor(\.text))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .foregroundColor(.umbraMuted)
                        }
                        .padding(.vertical, 11)
                        .padding(.horizontal, 20)
                    }
                    .buttonStyle(.plain)

                    if idx < items.count - 1 {
                        Rectangle()
                            .fill(umbraColor(\.border))
                            .frame(height: 1)
                            .padding(.leading, 74)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(umbraColor(\.card))
    }
}

// MARK: - Thinking dots（用 @State 驱动，避免 value: UUID() 每帧重触发动画/刷新）
struct ThinkingDotsView: View {
    @State private var animating = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(umbraColor(\.muted))
                    .frame(width: 7, height: 7)
                    .opacity(animating ? 1 : 0.35)
                    .animation(.easeInOut(duration: 1.2).repeatForever().delay(Double(i) * 0.2), value: animating)
            }
        }
        .padding(.vertical, 2)
        .onAppear { animating = true }
    }
}

// MARK: - Blink animation
extension View {
    func blink() -> some View {
        self.modifier(BlinkModifier())
    }
}

struct BlinkModifier: ViewModifier {
    @State private var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
                withAnimation(.none) { opacity = opacity == 1 ? 0 : 1 }
            }
    }
}

// MARK: - Assistant Text Content (with image support)
extension ChatView {
    @ViewBuilder
    private func assistantTextContent(_ text: String) -> some View {
        let imageUrls = extractUrls(from: text).filter { isImageUrl($0) }

        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(4)

            ForEach(imageUrls, id: \.self) { url in
                AsyncImage(url: URL(string: url)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 320, maxHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(umbraColor(\.border), lineWidth: 1)
                            )
                            .onTapGesture {
                                viewModel.showLightbox = true
                                viewModel.lightboxImageURL = url
                            }
                    case .failure:
                        EmptyView()
                    case .empty:
                        ProgressView()
                            .frame(height: 200)
                    @unknown default:
                        EmptyView()
                    }
                }
            }
        }
    }

    private func extractUrls(from text: String) -> [String] {
        let pattern = "https?://[\\w\\-._~:/?#\\[\\]@!$&'()*+,;=%]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var urls: [String] = []
        let nsRange = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
            if let matchRange = match?.range(at: 0),
               let swiftRange = Range(matchRange, in: text) {
                urls.append(String(text[swiftRange]))
            }
        }
        return urls
    }

    // MARK: - TTS Bar
    private func ttsBar(id: String, text: String) -> some View {
        let speaking = tts.isSpeaking(id: id)
        return Button {
            tts.toggle(text, id: id)
        } label: {
            HStack(spacing: 9) {
                // Play/Pause icon
                Image(systemName: speaking ? "pause.fill" : "play.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.orange)
                    .clipShape(Circle())

                if speaking {
                    // Waveform animation
                    HStack(spacing: 2.5) {
                        ForEach(0..<5) { i in
                            Rectangle()
                                .fill(Color.orange)
                                .frame(width: 2.5, height: 16)
                                .animation(
                                    .easeInOut(duration: 0.9).repeatForever().delay(Double(i) * 0.15),
                                    value: speaking
                                )
                                .scaleEffect(y: 0.3 + 0.7 * Double(sin(Double(i) * 0.8)))
                        }
                    }
                    .frame(height: 16)
                    Text(L("chat.tts.reading"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.orangeText)
                } else {
                    Text(L("chat.tts.readReply"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.orangeText)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.08))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.orange, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Image Lightbox
struct ImageLightboxView: View {
    @Environment(\.dismiss) var dismiss
    let imageURL: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            AsyncImage(url: URL(string: imageURL)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .padding()
                        .transition(.opacity)
                case .failure:
                    Text(L("chat.image.loadFailed"))
                        .foregroundColor(.white)
                case .empty:
                    ProgressView()
                        .tint(.white)
                @unknown default:
                    EmptyView()
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Locate Card（人工箭头指位）
// 显示 operate 当前截图；用户在图上拖一个箭头，箭头尖端(tip)=要点击的位置。
// tip 换算成相对图片的归一化坐标(0-1000)回传，与服务端/设备的 click nx,ny 对齐。
struct LocateCard: View {
    let data: ChatBlock.LocateBlock
    let onLocate: (Int, Int) -> Void
    let onCancel: () -> Void

    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var arrowStart: CGPoint?     // 图内像素坐标（画箭头用）
    @State private var arrowTip: CGPoint?
    @State private var tipNorm: CGPoint?         // 归一化 0-1000（回传用）

    private var fullURL: URL? {
        if data.imageUrl.hasPrefix("http") { return URL(string: data.imageUrl) }
        return URL(string: NetworkConfig.shared.serverUrl + data.imageUrl)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "hand.point.up.left.fill").foregroundColor(.orangeText)
                Text(L("operate.locate.title"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.orangeText)
            }
            Text(data.hint).font(.system(size: 12.5)).lineSpacing(4)

            if let resolved = data.resolved {
                Text(resolved == .located ? L("operate.locate.done") : L("operate.locate.cancelled"))
                    .font(.system(size: 12)).foregroundColor(.umbraMuted)
            } else if let image {
                imageWithArrow(image)
                HStack(spacing: 9) {
                    Button(L("operate.locate.confirm")) {
                        if let n = tipNorm { onLocate(Int(n.x), Int(n.y)) }
                    }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .disabled(tipNorm == nil)
                    .frame(maxWidth: .infinity)
                    Button(L("operate.locate.manual")) { onCancel() }
                        .buttonStyle(.bordered).tint(.gray)
                        .frame(maxWidth: .infinity)
                }
            } else if loadFailed {
                Text(L("operate.locate.loadFailed")).font(.system(size: 12)).foregroundColor(.red)
                Button(L("operate.locate.manual")) { onCancel() }.buttonStyle(.bordered).tint(.gray)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange, lineWidth: 1))
        .frame(maxWidth: UIScreen.main.bounds.width * 0.92)
        .task { await load() }
    }

    private func imageWithArrow(_ img: UIImage) -> some View {
        let aspect = img.size.width / max(img.size.height, 1)
        return GeometryReader { geo in
            let w = geo.size.width
            let h = w / aspect
            ZStack {
                Image(uiImage: img).resizable().frame(width: w, height: h)
                if let start = arrowStart, let tip = arrowTip {
                    ArrowShape(from: start, to: tip)
                        .stroke(Color.red, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    Circle().fill(Color.red).frame(width: 10, height: 10).position(tip)
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if arrowStart == nil { arrowStart = v.startLocation }
                        let tip = CGPoint(x: min(max(v.location.x, 0), w), y: min(max(v.location.y, 0), h))
                        arrowTip = tip
                        tipNorm = CGPoint(x: tip.x / w * 1000, y: tip.y / h * 1000)
                    }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    private func load() async {
        guard let url = fullURL else { loadFailed = true; return }
        do {
            let (bytes, _) = try await URLSession.shared.data(from: url)
            if let ui = UIImage(data: bytes) { image = ui } else { loadFailed = true }
        } catch {
            loadFailed = true
        }
    }
}

// 从 from 画到 to 的箭头（含箭头尖）。
struct ArrowShape: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addLine(to: to)
        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLen: CGFloat = 14
        let spread: CGFloat = .pi / 7
        let left = CGPoint(x: to.x - headLen * cos(angle - spread), y: to.y - headLen * sin(angle - spread))
        let right = CGPoint(x: to.x - headLen * cos(angle + spread), y: to.y - headLen * sin(angle + spread))
        p.move(to: to); p.addLine(to: left)
        p.move(to: to); p.addLine(to: right)
        return p
    }
}
