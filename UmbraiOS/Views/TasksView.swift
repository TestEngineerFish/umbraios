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
                    Text("任务")
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
                                TaskRow(job: job)
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

            Text(job.result_summary?.prefix(70) ?? job.channel.map { "来自 \($0)" } ?? "")
                .font(.system(size: 11.5))
                .foregroundColor(.umbraMuted)
                .lineLimit(1)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(umbraColor(\.card))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(job.status == "running" ? Color.orange : umbraColor(\.border), lineWidth: 1)
        )
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch job.status {
            case "done": return ("已完成", .green)
            case "running": return ("执行中", .orange)
            case "pending": return ("待执行", .umbraMuted)
            case "failed": return ("失败", .red)
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
        job.status == "done" ? 1.0 : (job.status == "running" ? 0.38 : 0)
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
                            Text("总进度")
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
                            Text("步骤")
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
                            Text("事件时间线")
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
                    Button("关闭") { dismiss() }
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
