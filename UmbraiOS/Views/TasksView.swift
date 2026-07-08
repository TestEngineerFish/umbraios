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

                    // Steps
                    if !detail.subtasks.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(L("tasks.steps"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.umbraMuted)
                            ForEach(detail.subtasks.sorted(by: { $0.seq < $1.seq })) { sub in
                                HStack(spacing: 9) {
                                    stepIcon(status: sub.status)
                                    Text(sub.title ?? "\(sub.provider ?? "").\(sub.skill ?? "")")
                                        .font(.system(size: 13))
                                        .foregroundColor(sub.status == "pending" ? .umbraMuted : .primary)
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
        }
    }

    private var pct: Int {
        let done = detail.subtasks.filter { $0.status == "done" }.count
        guard detail.subtasks.count > 0 else { return detail.job.status == "done" ? 100 : 0 }
        return Int(Double(done) / Double(detail.subtasks.count) * 100)
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
