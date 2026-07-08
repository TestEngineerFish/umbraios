import SwiftUI

// MARK: - Inspirations View（灵感速记：列表 + 过滤 + 新增/编辑 + 状态 + 删除）
struct InspirationsView: View {
    @StateObject private var viewModel = InspirationsViewModel()
    @State private var editing: Inspiration?     // 编辑中的条目
    @State private var showEditor = false          // 新增/编辑 sheet

    private struct FilterOption: Identifiable {
        let id: String        // 状态值（""/open/done/archived）
        let labelKey: String
    }
    private let filters: [FilterOption] = [
        .init(id: "", labelKey: "insp.filterAll"),
        .init(id: "open", labelKey: "insp.statusOpen"),
        .init(id: "done", labelKey: "insp.statusDone"),
        .init(id: "archived", labelKey: "insp.statusArchived"),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                filterBar
                content
            }
            .background(umbraColor(\.bg))
            .task { viewModel.startPolling() }
            .onDisappear { viewModel.stopPolling() }
            .sheet(isPresented: $showEditor) {
                InspirationEditor(item: editing) { raw, title, tags, note in
                    Task {
                        if let item = editing {
                            await viewModel.update(id: item.id, raw: raw, title: title, tags: tags, note: note)
                        } else {
                            await viewModel.create(raw: raw, title: title, tags: tags, note: note)
                        }
                        showEditor = false
                        editing = nil
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text(L("insp.title"))
                .font(.system(size: 18, weight: .semibold))
            Spacer()
            Button {
                editing = nil
                showEditor = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.umbraOrange)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters) { opt in
                    let active = viewModel.filter == opt.id
                    Text(L(opt.labelKey))
                        .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                        .foregroundColor(active ? .white : .umbraMuted)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(active ? Color.umbraOrange : umbraColor(\.card))
                        .overlay(Capsule().stroke(active ? Color.umbraOrange : umbraColor(\.border), lineWidth: 1))
                        .clipShape(Capsule())
                        .onTapGesture { viewModel.setFilter(opt.id) }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        if viewModel.loading && viewModel.list.isEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        } else if viewModel.list.isEmpty {
            Text(L("insp.empty"))
                .font(.system(size: 13))
                .foregroundColor(.umbraMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.list) { item in
                        InspirationRow(
                            item: item,
                            onEdit: { editing = item; showEditor = true },
                            onStatus: { s in Task { await viewModel.setStatus(id: item.id, status: s) } },
                            onDelete: { Task { await viewModel.delete(id: item.id) } }
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 20)
            }
        }
    }
}

// MARK: - Row
struct InspirationRow: View {
    let item: Inspiration
    let onEdit: () -> Void
    let onStatus: (String) -> Void
    let onDelete: () -> Void

    private var displayTitle: String {
        if !item.title.isEmpty { return item.title }
        return String(item.raw.prefix(24)) + (item.raw.count > 24 ? "…" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(displayTitle)
                    .font(.system(size: 14.5, weight: .medium))
                    .lineLimit(1)
                statusBadge
                Spacer()
            }
            Text(item.raw)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if !item.summary.isEmpty {
                Text("💡 " + item.summary)
                    .font(.system(size: 12.5))
                    .foregroundColor(.umbraMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 11))
                            .foregroundColor(.umbraMuted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .background(umbraColor(\.track))
                            .clipShape(Capsule())
                    }
                }
            }
            HStack {
                Text(timeText)
                    .font(.system(size: 11))
                    .foregroundColor(.umbraMuted)
                Spacer()
            }
            .padding(.top, 2)

            Divider()
            HStack(spacing: 14) {
                if item.status != "done" {
                    actionButton(L("insp.markDone"), color: .green) { onStatus("done") }
                } else {
                    actionButton(L("insp.markOpen"), color: .orange) { onStatus("open") }
                }
                if item.status != "archived" {
                    actionButton(L("insp.archive"), color: .umbraMuted) { onStatus("archived") }
                }
                Spacer()
                actionButton(L("insp.edit"), color: .umbraOrange, action: onEdit)
            }
            .font(.system(size: 12.5))
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(umbraColor(\.card))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(umbraColor(\.border), lineWidth: 1))
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label(L("insp.delete"), systemImage: "trash")
            }
        }
    }

    private func actionButton(_ text: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(text).foregroundColor(color) }
            .buttonStyle(.plain)
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch item.status {
            case "done": return (L("insp.statusDone"), .green)
            case "archived": return (L("insp.statusArchived"), .umbraMuted)
            default: return (L("insp.statusOpen"), .orange)
            }
        }()
        return Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var timeText: String {
        guard let ts = item.created_at else { return "" }
        return String(ts.replacingOccurrences(of: "T", with: " ").prefix(16))
    }
}

// MARK: - Editor Sheet
struct InspirationEditor: View {
    let item: Inspiration?
    let onSave: (_ raw: String, _ title: String, _ tags: [String], _ note: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var raw: String
    @State private var title: String
    @State private var tags: String
    @State private var note: String

    init(item: Inspiration?, onSave: @escaping (_ raw: String, _ title: String, _ tags: [String], _ note: String) -> Void) {
        self.item = item
        self.onSave = onSave
        _raw = State(initialValue: item?.raw ?? "")
        _title = State(initialValue: item?.title ?? "")
        _tags = State(initialValue: (item?.tags ?? []).joined(separator: ", "))
        _note = State(initialValue: item?.summary ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("insp.rawLabel")) {
                    TextEditor(text: $raw).frame(minHeight: 90)
                }
                Section {
                    TextField(L("insp.titlePh"), text: $title)
                    TextField(L("insp.tagsPh"), text: $tags)
                    TextField(L("insp.notePh"), text: $note)
                }
            }
            .navigationTitle(item == nil ? L("insp.add") : L("insp.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("insp.save")) {
                        let parsed = tags
                            .split(whereSeparator: { $0 == "," || $0 == "，" })
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        onSave(raw.trimmingCharacters(in: .whitespacesAndNewlines), title, parsed, note)
                    }
                    .disabled(raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .tint(Color.umbraOrange)
                }
            }
        }
    }
}
