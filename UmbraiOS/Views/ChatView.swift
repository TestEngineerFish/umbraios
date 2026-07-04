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

            // Messages
            messageList

            // Quick chips
            quickChips

            // Input bar
            inputBar
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
                Image(systemName: "square.and.pencil")
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
        .confirmationDialog(L("chat.newSession.confirm"), isPresented: $showNewChatConfirm, titleVisibility: .visible) {
            Button(L("chat.newSession.title"), role: .destructive) { viewModel.newSession() }
            Button(L("common.cancel"), role: .cancel) { }
        }
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
        case .job(let data):
            jobCard(data)
        case .done(_, let goal, let results):
            doneCard(goal: goal, results: results)
        case .confirm(let data):
            confirmCard(data)
        case .error(_, let text):
            errorBubble(text)
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
