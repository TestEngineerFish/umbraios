import SwiftUI

// MARK: - Tasks View
struct TasksView: View {
    @StateObject private var viewModel = TasksViewModel()
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text(L("tasks.title"))
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button {
                        Task { await viewModel.refreshJobs() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(viewModel.refreshing ? 360 : 0))
                            // 停止时用有限动画覆盖 repeatForever，否则 repeatForever 不会被 nil 取消、会一直转。
                            .animation(viewModel.refreshing
                                ? .linear(duration: 1).repeatForever(autoreverses: false)
                                : .linear(duration: 0.2),
                                value: viewModel.refreshing)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 12)

                // Task list
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if viewModel.loading && viewModel.jobs.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 200)
                        } else {
                            ForEach(viewModel.jobs) { job in
                                TaskRow(job: job, onStop: {
                                    Task { await viewModel.stopJob(id: job.id) }
                                })
                                .onTapGesture {
                                    Task { await viewModel.loadJobDetail(id: job.id) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
            .background(umbraColor(\.bg))
            .task {
                viewModel.startPolling()
            }
            .onDisappear {
                viewModel.stopPolling()
            }
            .sheet(isPresented: Binding(
                get: { viewModel.jobDetail != nil },
                set: { if !$0 { viewModel.closeJobDetail() } }
            )) {
                if let detail = viewModel.jobDetail {
                    JobDetailView(detail: detail)
                }
            }
        }
    }
}

// MARK: - Task Row
struct TaskRow: View {
    let job: Job
    var onStop: (() -> Void)? = nil
    @State private var confirmingStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text(job.goal)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                statusBadge
            }

            // Progress bar
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 999)
                    .fill(umbraColor(\.track))
                    .overlay(
                        RoundedRectangle(cornerRadius: 999)
                            .fill(barColor)
                            .frame(width: geo.size.width * CGFloat(barPct)),
                        alignment: .leading
                    )
            }
            .frame(height: 5)

            HStack {
                Text(taskSubtitle(for: job))
                    .font(.system(size: 11.5))
                    .foregroundColor(.umbraMuted)
                    .lineLimit(1)
                Spacer()
                // 运行/待执行/暂停中的任务可强制结束（放在任务列表上）。
                if onStop != nil, TasksViewModel.isActive(job.status) {
                    Button(role: .destructive) {
                        confirmingStop = true
                    } label: {
                        Text(L("tasks.stop"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.red)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Color.red.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(umbraColor(\.card))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(job.status == "running" ? Color.orange : umbraColor(\.border), lineWidth: 1)
        )
        .confirmationDialog(L("tasks.stopConfirm"), isPresented: $confirmingStop, titleVisibility: .visible) {
            Button(L("tasks.stop"), role: .destructive) { onStop?() }
            Button(L("common.cancel"), role: .cancel) {}
        }
    }

    private func taskSubtitle(for job: Job) -> String {
        // 优先展示步骤进度（x/y 步）。
        if let total = job.steps_total, total > 0, let done = job.steps_done, job.status != "done" {
            return L("tasks.stepsProgress", "\(done)/\(total)")
        }
        if let summary = job.result_summary, !summary.isEmpty {
            return String(summary.prefix(70))
        }
        if let channel = job.channel {
            return L("tasks.fromChannel", channel)
        }
        return ""
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch job.status {
            case "done": return (L("tasks.done"), .green)
            case "running": return (L("tasks.running"), .orange)
            case "pending": return (L("tasks.pending"), .umbraMuted)
            case "paused": return (L("tasks.paused"), .orange)
            case "failed": return (L("tasks.failed"), .red)
            default: return (job.status, .umbraMuted)
            }
        }()
        return Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }

    private var barColor: Color {
        switch job.status {
        case "done": return .green
        case "running", "pending": return .orange
        case "failed": return .red
        default: return .umbraMuted
        }
    }

    private var barPct: Double {
        if job.status == "done" { return 1.0 }
        // 有真实步骤统计就按「已完成/总数」显示，否则退回粗略估计。
        if let total = job.steps_total, total > 0, let done = job.steps_done {
            return min(1.0, Double(done) / Double(total))
        }
        return job.status == "running" ? 0.38 : 0
    }
}

// MARK: - Job Detail View
struct JobDetailView: View {
    let detail: JobDetail
    @Environment(\.dismiss) private var dismiss
    @State private var previewURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Progress
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("tasks.progress"))
                                .font(.system(size: 12))
                                .foregroundColor(.umbraMuted)
                            Spacer()
                            Text("\(pct)%")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.orangeText)
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 999)
                                .fill(umbraColor(\.track))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 999)
                                        .fill(barColor)
                                        .frame(width: geo.size.width * CGFloat(pct) / 100),
                                    alignment: .leading
                                )
                        }
                        .frame(height: 6)
                    }

                    // Steps（每步下方显示「该步完成后」的状态截图）
                    if !detail.subtasks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L("tasks.steps"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.umbraMuted)
                            ForEach(detail.subtasks.sorted(by: { $0.seq < $1.seq })) { sub in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(spacing: 9) {
                                        stepIcon(status: sub.status)
                                        Text(sub.title ?? "\(sub.provider ?? "").\(sub.skill ?? "")")
                                            .font(.system(size: 13))
                                            .foregroundColor(sub.status == "pending" ? .umbraMuted : .primary)
                                    }
                                    if let url = stepShotURL(sub) {
                                        AsyncImage(url: url) { phase in
                                            if case .success(let image) = phase {
                                                image.resizable().scaledToFit()
                                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(umbraColor(\.border), lineWidth: 1))
                                                    .onTapGesture { previewURL = url }   // 点击全屏预览
                                            } else if case .empty = phase {
                                                ProgressView().frame(maxWidth: .infinity, minHeight: 50)
                                            }
                                        }
                                        .padding(.leading, 27)
                                    }
                                }
                            }
                        }
                    }

                    // Timeline
                    if !detail.events.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(L("tasks.events"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.umbraMuted)
                                .padding(.bottom, 10)

                            ForEach(detail.events) { event in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(event.created_at?.suffix(5) ?? "")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.umbraMuted)
                                    Text(event.message ?? event.type)
                                        .font(.system(size: 12.5))
                                }
                                .padding(.leading, 16)
                                .overlay(
                                    Circle()
                                        .fill(.orange)
                                        .frame(width: 9, height: 9)
                                        .offset(x: -4),
                                    alignment: .leading
                                )
                                .padding(.bottom, 13)
                                .overlay(
                                    Rectangle()
                                        .frame(width: 2)
                                        .foregroundColor(umbraColor(\.border))
                                        .offset(x: -1),
                                    alignment: .leading
                                )
                            }
                        }
                    }

                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
            }
            .navigationTitle(detail.job.goal)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("common.close")) { dismiss() }
                        .tint(Color.umbraOrange)
                }
            }
            .fullScreenCover(item: $previewURL) { url in
                ImagePreview(url: url) { previewURL = nil }
            }
        }
    }

    private var pct: Int {
        let done = detail.subtasks.filter { $0.status == "done" }.count
        guard detail.subtasks.count > 0 else { return detail.job.status == "done" ? 100 : 0 }
        return Int(Double(done) / Double(detail.subtasks.count) * 100)
    }

    // 单个步骤的「完成后」状态截图链接（result_json.url，相对路径拼 baseUrl）。
    private func stepShotURL(_ sub: Subtask) -> URL? {
        guard let raw = sub.result_json,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj["url"] as? String, !s.isEmpty else { return nil }
        let full = s.hasPrefix("http") ? s : NetworkConfig.shared.serverUrl + s
        return URL(string: full)
    }

    private var barColor: Color {
        switch detail.job.status {
        case "done": return .green
        case "failed": return .red
        default: return .orange
        }
    }

    private func stepIcon(status: String) -> some View {
        Group {
            switch status {
            case "done":
                Text("✓")
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(.green)
                    .clipShape(Circle())
            case "failed":
                Text("✕")
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(.red)
                    .clipShape(Circle())
            case "running", "dispatched":
                Circle()
                    .stroke(Color.orange, lineWidth: 2)
                    .frame(width: 18, height: 18)
            default:
                Circle()
                    .stroke(umbraColor(\.border), lineWidth: 2)
                    .frame(width: 18, height: 18)
            }
        }
    }
}

// 让 URL 可用于 .fullScreenCover(item:)。
extension URL: Identifiable { public var id: String { absoluteString } }

// MARK: - 全屏图片预览（缩放/拖动/双击复位/分享）。图片走 URLCache（服务端已设长缓存），不重复下载。
struct ImagePreview: View {
    let url: URL
    let onClose: () -> Void

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offBase: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { v in scale = min(max(base * v, 1), 6) }
                            .onEnded { _ in base = scale; if scale <= 1 { offset = .zero; offBase = .zero } }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { v in
                                guard scale > 1 else { return }
                                offset = CGSize(width: offBase.width + v.translation.width,
                                                height: offBase.height + v.translation.height)
                            }
                            .onEnded { _ in offBase = offset }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation { if scale > 1 { scale = 1; base = 1; offset = .zero; offBase = .zero } else { scale = 2.5; base = 2.5 } }
                    }
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white).padding(10)
                            .background(Color.white.opacity(0.18)).clipShape(Circle())
                    }
                    Spacer()
                    if let image {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("screenshot", image: Image(uiImage: image))) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white).padding(10)
                                .background(Color.white.opacity(0.18)).clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12)
                Spacer()
            }
        }
        .task {
            if image == nil {
                if let (data, _) = try? await URLSession.shared.data(from: url), let ui = UIImage(data: data) {
                    image = ui
                }
            }
        }
    }
}
