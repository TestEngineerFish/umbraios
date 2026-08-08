// 任务 · 列表（task.list）与详情（task.detail）。
//
// 数据来自既有的 TasksViewModel / HTTPService（GET /jobs、GET /jobs/{id}、POST 停止）。
// 设计稿里有、服务端还没有的三块，这里**不画**，而不是画个空壳：
//   · 「验收清单」—— Job 结构里没有这个字段；
//   · 「生成结果 / 下载结果」—— 服务端只回一个 result_summary 字符串，没有文件清单；
//   · 「重试任务」—— 没有重试接口（只有停止）。
// 「计划」分段是设计稿自己标了「二期 · 待服务端」的，这里如实说明，不放假数据。
import SwiftUI
import UIKit

// MARK: - 列表

struct UmbraTaskListView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var tasks: TasksViewModel

    enum Seg: Hashable { case history, plan }
    @State private var seg: Seg = .history
    @State private var query = ""
    /// nil = 全部
    @State private var filter: UmbraStatus? = nil
    /// 搜索框焦点放在页面上（不塞组件里）：「点空白处收键盘」得由页面来收。
    @FocusState private var searchFocused: Bool

    var body: some View {
        UmbraScreen {
            // 大标题交给系统栏；数量小结放内容首行（v2 原型的位置）。
            Text(counts)
                .font(UmbraFont.sans(13, .w400))
                .foregroundColor(UmbraColor.muted)
                .padding(.horizontal, UmbraMetric.pagePadX)
                .padding(.bottom, UmbraMetric.sp3)

            UmbraSegmentedControl(items: [
                .init(value: Seg.history, label: "历史"),
                .init(value: Seg.plan, label: "计划")
            ], selection: $seg)
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.bottom, UmbraMetric.sp4)

            if seg == .history { history } else { plan }
        }
        .navigationTitle("任务")
        // 列表页不参与键盘避让：搜索框在页面上方用不着避让，
        // 反而搜索键盘收起后底部 inset 可能留着不走，让页面短一截（同保险箱首页的坑）。
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // 点内容区任意空白收键盘。simultaneousGesture 不吞行内按钮的点击；
        // 只在真有焦点时动手，避免和「点图标展开搜索」抢同一下点击。
        .simultaneousGesture(TapGesture().onEnded { if searchFocused { searchFocused = false } })
        .refreshable { await tasks.refreshJobs() }
        .onAppear { tasks.startPolling() }
        .onDisappear { tasks.stopPolling() }
    }

    private var counts: String {
        let running = tasks.jobs.filter { UmbraStatus(jobStatus: $0.status) == .running }.count
        return "共 \(tasks.jobs.count) 个 · \(running) 个执行中"
    }

    // MARK: 历史

    private var filtered: [Job] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return tasks.jobs.filter { j in
            if let f = filter, UmbraStatus(jobStatus: j.status) != f { return false }
            if !q.isEmpty && !(j.title + j.goal + (j.result_summary ?? "")).localizedCaseInsensitiveContains(q) { return false }
            return true
        }
    }

    /// 筛选胶囊。用 Optional<UmbraStatus> 当值，nil 就是「全部」——
    /// 比拿字符串当 key 少一层「中文标签 ↔ 状态」的翻译，也就少一处能对不上的地方。
    private var chipItems: [UmbraFilterChips<OptionalStatus>.Item] {
        var out: [UmbraFilterChips<OptionalStatus>.Item] = [
            .init(value: OptionalStatus(nil), label: "全部", count: tasks.jobs.count)
        ]
        for st in [UmbraStatus.running, .awaitingReview, .pending, .done, .failed] {
            let n = tasks.jobs.filter { UmbraStatus(jobStatus: $0.status) == st }.count
            out.append(.init(value: OptionalStatus(st), label: st.label, count: n))
        }
        return out
    }

    @ViewBuilder
    private var history: some View {
        VStack(alignment: .leading, spacing: 11) {
            // 默认收成一个搜索图标，点开才占一行（用户点名；灵感列表同款）。
            UmbraCollapsingSearch(placeholder: "搜索任务目标或结果摘要", text: $query,
                                  focused: $searchFocused)
                .padding(.horizontal, UmbraMetric.pagePadX)

            UmbraFilterChips(items: chipItems, selection: Binding(
                get: { OptionalStatus(filter) },
                set: { filter = $0.value }
            ))

            if filtered.isEmpty {
                UmbraEmptyState(
                    iconPath: UmbraIconPath.task,
                    title: emptyTitle,
                    hint: emptyBody)
            } else {
                VStack(spacing: 9) {
                    ForEach(filtered) { job in
                        taskRow(job)
                    }
                }
                .padding(.horizontal, UmbraMetric.pagePadX)
            }
        }
    }

    private var emptyTitle: String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { return "没有匹配「\(q)」的任务" }
        return filter == nil ? "暂无任务" : "这个筛选下暂无任务"
    }

    private var emptyBody: String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { return "换个词，或者清掉筛选试试。" }
        return filter == nil ? "在聊天里描述目标，Umbra 会自动建任务。" : "清掉筛选就能看到全部。"
    }

    private func taskRow(_ job: Job) -> some View {
        let st = UmbraStatus(jobStatus: job.status)
        let total = job.steps_total ?? 0
        let done = job.steps_done ?? 0
        return Button {
            router.go(.taskDetail(id: job.id))
        } label: {
            // 不再单画一个状态图标方块：标题下面那行 UmbraStatusBadge 已经是
            // 图标 + 文字的完整状态表达，再来一个就是同一信息说两遍（用户点名去掉）。
            VStack(alignment: .leading, spacing: 7) {
                // 标题位放**短标题**，描述降为副行 —— 与 PC 端一致。
                // 原来这里直接写 goal，整段需求描述占着标题位，两端看着像两个东西。
                Text(job.title)
                    .font(UmbraFont.sans(16, .w400))
                    .foregroundColor(UmbraColor.text)
                    .lineSpacing(16 * 0.4)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // 有短标题时才补一行描述；旧 Job 没有 name，title 已经是 goal，
                // 再画一遍就是同一句话说两遍。
                if job.name?.isEmpty == false {
                    Text(job.goal)
                        .font(UmbraFont.sans(13.5, .w400))
                        .foregroundColor(UmbraColor.muted)
                        .lineSpacing(13.5 * 0.4)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 7) {
                    UmbraStatusBadge(status: st)
                    if let ch = job.channel, !ch.isEmpty {
                        Text("来自 \(ch)")
                            .font(UmbraFont.sans(13, .w400))
                            .foregroundColor(UmbraColor.faint)
                    }
                    Text("· \(UmbraTime.relative(job.updated_at))")
                        .font(UmbraFont.sans(13, .w400))
                        .foregroundColor(UmbraColor.faint)
                    Spacer(minLength: 0)
                }

                // 进度只在**服务端真给了步骤数**时画。没有步骤数就不画进度条 ——
                // 画一根永远 0% 的条比不画更容易被当成「卡住了」。
                if st == .running && total > 0 {
                    UmbraProgressBar(progress: Double(done) / Double(total))
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, UmbraMetric.sp4)
            .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous).fill(UmbraColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous)
                    .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 计划
    //
    // 设计稿自己标了「二期 · 待服务端」。服务端确实没有定时任务接口，
    // 所以这里给一个说清楚状况的承接页，而不是照着设计稿摆两条假的定时任务。

    private var plan: some View {
        VStack(alignment: .leading, spacing: UmbraMetric.sp4) {
            UmbraCard {
                VStack(alignment: .leading, spacing: UmbraMetric.sp2) {
                    UmbraSectionLabel(text: "定时执行还没有接服务端")
                    Text("等服务端有了定时任务接口，这里会列出每条计划的目标设备、下次执行时间和开关。")
                        .font(UmbraFont.body)
                        .foregroundColor(UmbraColor.text)
                        .lineSpacing(UmbraFont.bodyLineSpacing)
                    Text("定时任务在手机上只做「看 + 启停 + 立即跑一次」。新建要选工作流、配 cron、选设备，去电脑上做。")
                        .font(UmbraFont.rowSub)
                        .foregroundColor(UmbraColor.muted)
                        .lineSpacing(4)
                }
            }
            .padding(.horizontal, UmbraMetric.pagePadX)
        }
    }
}

/// 让 `UmbraStatus?` 能当 ForEach 的 id 用。裸的 Optional 也 Hashable，
/// 但泛型参数里写 `UmbraStatus?` 会让 Binding 的类型推导变得很难读，包一层更清楚。
struct OptionalStatus: Hashable {
    let value: UmbraStatus?
    init(_ v: UmbraStatus?) { value = v }
}

// MARK: - 详情

struct UmbraTaskDetailView: View {
    let id: String

    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var tasks: TasksViewModel

    @State private var showRawError = false

    private var detail: JobDetail? { tasks.jobDetail?.job.id == id ? tasks.jobDetail : nil }

    var body: some View {
        UmbraScreen(content: {
            if let d = detail {
                content(d)
            } else {
                // 拉取中：不摆骨架屏假装有内容，就一行字。
                Text("正在读取任务…")
                    .font(UmbraFont.body)
                    .foregroundColor(UmbraColor.muted)
                    .padding(.horizontal, UmbraMetric.pagePadX)
                    .padding(.top, UmbraMetric.sp6)
            }
        }, bottom: {
            if let d = detail { bottomBar(d) }
        })
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await tasks.loadJobDetail(id: id) } }
        .onDisappear { tasks.closeJobDetail() }
    }

    /// 顶栏标题：优先用任务短标题，拿不到详情时退回短 ID。
    /// 原来固定显示短 ID —— 一串 06731c54 谁也读不出这是哪个任务，
    /// 而完整 ID 在下面的详情表里本来就有一行（不会丢）。
    private var navTitle: String {
        if let t = detail?.job.title, !t.isEmpty { return t }
        return String(id.prefix(8))
    }

    @ViewBuilder
    private func content(_ d: JobDetail) -> some View {
        let st = UmbraStatus(jobStatus: d.job.status)

        // 目标 + 状态
        VStack(alignment: .leading, spacing: 11) {
            // 同列表：标题位是短标题，整段描述放下面一行。
            Text(d.job.title)
                .font(UmbraFont.sans(19, .w560))
                .foregroundColor(UmbraColor.text)
                .lineSpacing(19 * 0.45)
                .frame(maxWidth: .infinity, alignment: .leading)
            if d.job.name?.isEmpty == false {
                Text(d.job.goal)
                    .font(UmbraFont.sans(15, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineSpacing(15 * 0.5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                UmbraStatusBadge(status: st, compact: false)
                if let ch = d.job.channel, !ch.isEmpty {
                    Text("来自 \(ch)")
                        .font(UmbraFont.sans(13, .w400))
                        .foregroundColor(UmbraColor.faint)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(UmbraMetric.pagePadX)
        .sectionDivider()

        // 总进度
        VStack(alignment: .leading, spacing: UmbraMetric.sp3) {
            HStack(alignment: .firstTextBaseline) {
                UmbraFieldLabel(text: "总进度")
                Spacer(minLength: 0)
                Text("\(doneCount(d)) / \(d.subtasks.count)")
                    .font(UmbraFont.mono(13, .w560))
                    .foregroundColor(UmbraColor.text)
            }
            UmbraProgressBar(progress: progress(d), color: st.bar, height: 8)
        }
        .padding(UmbraMetric.pagePadX)
        .sectionDivider()

        // 概要字段
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                            GridItem(.flexible(), alignment: .topLeading)],
                  spacing: UmbraMetric.sp4) {
            ForEach(Array(stats(d).enumerated()), id: \.offset) { _, kv in
                VStack(alignment: .leading, spacing: 3) {
                    UmbraFieldLabel(text: kv.0)
                    Text(kv.1)
                        .font(UmbraFont.sans(14.5, .w400))
                        .foregroundColor(UmbraColor.text)
                        .lineSpacing(14.5 * 0.4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, UmbraMetric.pagePadX)
        .padding(.vertical, UmbraMetric.sp5)
        .sectionDivider()

        // 步骤
        if !d.subtasks.isEmpty {
            VStack(alignment: .leading, spacing: UmbraMetric.sp3) {
                UmbraFieldLabel(text: "步骤 · \(d.subtasks.count)")
                VStack(spacing: 2) {
                    ForEach(d.subtasks) { s in stepRow(s) }
                }
            }
            .padding(UmbraMetric.pagePadX)
            .sectionDivider()
        }

        // 事件时间线
        if !d.events.isEmpty {
            VStack(alignment: .leading, spacing: UmbraMetric.sp3) {
                UmbraFieldLabel(text: "事件时间线 · \(d.events.count)")
                VStack(spacing: 0) {
                    ForEach(d.events) { e in eventRow(e) }
                }
            }
            .padding(UmbraMetric.pagePadX)
            .sectionDivider()
        }

        // 结果摘要 / 错误三段式
        if let summary = d.job.result_summary, !summary.isEmpty {
            if st == .failed {
                errorBlock(summary)
            } else {
                VStack(alignment: .leading, spacing: UmbraMetric.sp3) {
                    UmbraFieldLabel(text: "结果摘要")
                    Text(summary)
                        .font(UmbraFont.sans(14.5, .w400))
                        .foregroundColor(UmbraColor.text)
                        .lineSpacing(14.5 * 0.6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(UmbraMetric.pagePadX)
                .sectionDivider()
            }
        }
    }

    private func doneCount(_ d: JobDetail) -> Int {
        d.subtasks.filter { UmbraStatus(jobStatus: $0.status) == .done }.count
    }

    private func progress(_ d: JobDetail) -> Double {
        if d.job.status == "done" { return 1 }
        guard !d.subtasks.isEmpty else { return 0 }
        return Double(doneCount(d)) / Double(d.subtasks.count)
    }

    /// 概要字段只列**服务端真给了的**。给不了的（预计耗时、执行设备汇总）不占位。
    private func stats(_ d: JobDetail) -> [(String, String)] {
        var out: [(String, String)] = []
        out.append(("任务 ID", d.job.id))
        if let ch = d.job.channel, !ch.isEmpty { out.append(("来源", ch)) }
        out.append(("创建", UmbraTime.absolute(d.job.created_at)))
        out.append(("更新", UmbraTime.absolute(d.job.updated_at)))
        out.append(("步骤", "\(doneCount(d)) / \(d.subtasks.count)"))
        let failed = d.subtasks.filter { UmbraStatus(jobStatus: $0.status) == .failed }.count
        if failed > 0 { out.append(("失败步骤", "\(failed)")) }
        return out
    }

    private func stepRow(_ s: Subtask) -> some View {
        let st = UmbraStatus(jobStatus: s.status)
        return HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(st.soft)
                if st == .running {
                    UmbraSpinningIcon(d: st.iconPath, size: 12, strokeWidth: 2.2)
                } else {
                    UmbraIcon(d: st.iconPath, size: 12, strokeWidth: 2.2)
                }
            }
            .foregroundColor(st.fg)
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(s.seq). \(s.title ?? "未命名步骤")")
                    .font(UmbraFont.sans(15, .w400))
                    .foregroundColor(UmbraColor.text)
                    .lineSpacing(15 * 0.45)
                if let p = s.provider, !p.isEmpty {
                    Text("能力：\(p)\(s.skill.map { " · \($0)" } ?? "")")
                        .font(UmbraFont.sans(12.5, .w400))
                        .foregroundColor(UmbraColor.faint)
                }
                if let err = s.error, !err.isEmpty {
                    Text(err)
                        .font(UmbraFont.sans(13, .w400))
                        .foregroundColor(UmbraColor.muted)
                        .lineSpacing(13 * 0.55)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UmbraColor.chip))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, UmbraMetric.sp3)
        .overlay(alignment: .top) {
            Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
        }
    }

    private func eventRow(_ e: JobEvent) -> some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 0) {
                Circle()
                    .fill(eventColor(e.type))
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                Rectangle().fill(UmbraColor.border).frame(width: 1)
            }
            .frame(width: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(e.message ?? e.type)
                    .font(UmbraFont.sans(14.5, .w400))
                    .foregroundColor(UmbraColor.text)
                    .lineSpacing(14.5 * 0.45)
                Text(UmbraTime.absolute(e.created_at))
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(UmbraColor.faint)
            }
            .padding(.bottom, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func eventColor(_ type: String) -> Color {
        switch type {
        case "error", "failed": return UmbraColor.danger
        case "done", "finished", "succeeded": return UmbraColor.success
        case "warning", "awaiting_review": return UmbraColor.warning
        default: return UmbraColor.faint
        }
    }

    /// 错误三段式：发生了什么 → 为什么 → 现在能做什么。
    /// 第一段取失败步骤的名字（服务端给得出），第二段是它的错误信息，
    /// 第三段是可点的按钮。三段缺一不可 —— 这条是文案硬规则。
    private func errorBlock(_ summary: String) -> some View {
        let failedStep = detail?.subtasks.first { UmbraStatus(jobStatus: $0.status) == .failed }
        let what = failedStep.map { "第 \($0.seq) 步中断：\($0.title ?? "未命名步骤")" } ?? "任务失败"
        let why = failedStep?.error ?? summary
        return VStack(alignment: .leading, spacing: UmbraMetric.sp3) {
            HStack(spacing: 7) {
                UmbraIcon(d: UmbraIconPath.xCircle, size: 15, strokeWidth: 2.1)
                Text("任务失败")
                    .font(UmbraFont.sans(12, .w600))
                    .tracking(UmbraFont.labelTracking(12))
            }
            .foregroundColor(UmbraColor.danger)

            Text(what)
                .font(UmbraFont.sans(15.5, .w560))
                .foregroundColor(UmbraColor.text)
                .lineSpacing(15.5 * 0.45)
            Text(why)
                .font(UmbraFont.sans(14, .w400))
                .foregroundColor(UmbraColor.muted)
                .lineSpacing(14 * 0.6)

            HStack(spacing: 7) {
                UmbraButton(title: "去看能力", kind: .primary, height: 40) {
                    router.go(.meCaps)
                }
                UmbraButton(title: showRawError ? "收起原始返回" : "看原始返回", kind: .secondary, height: 40) {
                    showRawError.toggle()
                }
            }

            if showRawError {
                Text(summary)
                    .font(UmbraFont.mono(12, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineSpacing(12 * 0.7)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UmbraColor.card))
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous).fill(UmbraColor.dangerSoft))
        .padding(UmbraMetric.pagePadX)
    }

    /// 底部动作条。**没有「重试任务」**——服务端没有重试接口，
    /// 摆一个点了没反应的按钮比不摆更糟。
    private func bottomBar(_ d: JobDetail) -> some View {
        UmbraBottomBar {
            if TasksViewModel.isActive(d.job.status) {
                UmbraButton(title: "停止任务", kind: .dangerOutline) {
                    router.confirm(UmbraAlert(
                        title: "停止这个任务？",
                        body: "已完成的步骤会保留，正在跑的那一步会被打断。",
                        confirmLabel: "停止",
                        confirmDestructive: true,
                        onConfirm: {
                            Task {
                                await tasks.stopJob(id: d.job.id)
                                await tasks.loadJobDetail(id: d.job.id)
                            }
                            router.showToast("已发出停止")
                        }))
                }
            }
            UmbraButton(title: "复制详情", kind: .secondary) {
                UIPasteboard.general.string = plainText(d)
                router.showToast("已复制")
            }
        }
    }

    private func plainText(_ d: JobDetail) -> String {
        var lines = ["任务 \(d.job.id)", d.job.title, d.job.goal,
                     "状态：\(UmbraStatus(jobStatus: d.job.status).label)"]
        if let ch = d.job.channel { lines.append("来源：\(ch)") }
        lines.append("创建：\(UmbraTime.absolute(d.job.created_at))")
        lines.append("")
        for s in d.subtasks {
            lines.append("\(s.seq). [\(UmbraStatus(jobStatus: s.status).label)] \(s.title ?? "")")
            if let e = s.error, !e.isEmpty { lines.append("   错误：\(e)") }
        }
        if let sum = d.job.result_summary, !sum.isEmpty {
            lines.append("")
            lines.append("结果：\(sum)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 分节分隔线

private struct SectionDivider: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
        }
    }
}

extension View {
    /// 详情页的分节底线。详情页是**通栏分节**（不是卡片堆叠），节与节之间靠一条发丝线分开。
    func sectionDivider() -> some View { modifier(SectionDivider()) }
}

// MARK: - 时间

/// 时间显示。服务端给的都是 ISO8601 字符串，解析不了就原样返回 ——
/// 编一个「刚刚」出来会让人以为任务刚跑过。
enum UmbraTime {
    private static func parse(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    /// 「09:41」/「昨天」/「7月28日」。
    static func relative(_ iso: String?) -> String {
        guard let d = parse(iso) else { return iso ?? "" }
        let cal = Calendar.current
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(d) { df.dateFormat = "HH:mm"; return df.string(from: d) }
        if cal.isDateInYesterday(d) { return "昨天" }
        df.dateFormat = "M月d日"
        return df.string(from: d)
    }

    /// 「7月28日 09:41」。今年的不写年份。
    static func absolute(_ iso: String?) -> String {
        guard let d = parse(iso) else { return iso ?? "—" }
        let cal = Calendar.current
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = cal.component(.year, from: d) == cal.component(.year, from: Date())
            ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
        return df.string(from: d)
    }
}
