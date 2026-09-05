// 提醒附件（一期只收图片，2026-08-27 补齐，与 PC 同规则）。
//
// 形态**暂借记账「记一笔」的附件区**（批次 004 正式形态：缩略 78 / 圆角 13、≤4 张、
// 加图走来源选择）—— 提醒自己的附件区样式已在批次 007 请 ClaudeDesign 定稿，稿来了再改。
//
// 与记账最大的不同：记账的附件是**独立接口**（/money/entries/{id}/atts，改一张动一次网络），
// 提醒的附件是**整行的一部分**（reminders.atts 行内 JSON，跟着提醒 LWW 同步）——
// 所以这里的加图 / 摘图都只改草稿，**点「保存」才生效**：
// 新图先攒本地（pending），保存时逐张上传拿 file_id 再随 PUT 落库；
// 摘掉已存的图也只是从草稿数组里移除，服务端在收到 PUT 时按差集清文件。
// 中途取消编辑 = 什么都没发生，不会留孤儿文件。
import PhotosUI
import SwiftUI
import UIKit

/// 新建 / 编辑时先攒在本地、还没上传的一张图。
/// label 存**来源**（相册图片 / 拍的照片 / 文件图片，批次 007 答复：72–78 宽的标签条里
/// 文件名截成「IMG_2026…」没有信息量，来源才是用户当时唯一记得的线索）；
/// filename 只给预览器标题用（相册 / 拍照没有文件名，空串就用来源顶上）。
struct ReminderPendingImage: Identifiable, Equatable {
    let id: UUID
    let data: Data
    let label: String
    var filename: String = ""
}

/// 逐张上传攒着的图。全部成功返回追加后的附件数组；哪张失败点名哪张 ——
/// 批量吞掉失败的话用户只会看到「怎么少了一张」。
/// 返回 (追加到哪一步的数组, 已传成功的 pending id, 失败的文件名?)：
/// 失败时调用方把成功的先记进草稿、从 pending 摘掉，再点一次保存只补传剩下的，
/// 不会把同一张传两遍留孤儿文件（与 PC 的处理一致）。
enum ReminderAttUploader {
    static func upload(_ pending: [ReminderPendingImage],
                       onto atts: [ReminderAtt]) async -> (atts: [ReminderAtt], uploaded: [UUID], failed: String?) {
        var out = atts
        var done: [UUID] = []
        for p in pending {
            // 上传文件名带扩展名 —— /files/{id} 靠它带 .jpg 后缀，各端 <img>/AsyncImage 才按图片处理；
            // 落到 label 的是**来源**（批次 007 答复），文件名只进预览器标题。
            let name = p.filename.isEmpty ? "photo-\(Int(Date().timeIntervalSince1970)).jpg" : p.filename
            guard let up = try? await HTTPService.shared.uploadFile(name: name, data: p.data) else {
                return (out, done, p.label)
            }
            out.append(ReminderAtt(fileId: up.file_id, label: p.label))
            done.append(p.id)
        }
        return (out, done, nil)
    }
}

/// 编辑表单里的附件区。已存的（draft.atts）和攒着的（pending）都能摘；
/// 满 maxAtts 张收起「加图」，不给禁用态（沿用记账的稿）。
struct ReminderAttsSection: View {
    @Binding var atts: [ReminderAtt]
    @Binding var pending: [ReminderPendingImage]
    /// 新建 = true：脚注提示「保存时才上传」，免得用户以为加上就存好了。
    var creating: Bool

    @EnvironmentObject private var router: UmbraRouter
    // viewerItem 已删：编辑态不给点开预览（`attachThumb.editing`，见 savedThumb 的注释），
    // 这一屏没有预览器了。看大图去详情页（ReminderAttsPreviewRow 那边照旧）。
    @State private var showPhotos = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showFiles = false

    private var count: Int { atts.count + pending.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("附件").font(UmbraFont.sans(12, .w600)).foregroundColor(UmbraColor.faint)
                Text("\(count) / \(UmbraReminder.maxAtts)")
                    .font(UmbraFont.sans(11)).foregroundColor(UmbraColor.faint)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(atts) { a in savedThumb(a) }
                    ForEach(pending) { p in pendingThumb(p) }
                    if count < UmbraReminder.maxAtts { addTile }
                }
            }
            Text(creating ? "只收图片，跟提醒一起存；点右上角保存时才上传。"
                          : "只收图片，加图 / 摘图都在点保存时一起生效。")
                .font(UmbraFont.sans(11.5)).foregroundColor(UmbraColor.faint)
                .lineSpacing(11.5 * 0.55)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
        .overlay(
            RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                .strokeBorder(UmbraColor.borderSoft, lineWidth: UmbraMetric.borderW)
        )
        // 加图的三个来源（沿用记账批次 004）。相册的有限授权、权限弹窗都在 PhotosPicker 里；
        // 文件要先拿安全作用域，不拿在真机上必读不出来。
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { item in
            guard let item else { return }
            photoItem = nil
            Task { @MainActor in
                if let d = try? await item.loadTransferable(type: Data.self) {
                    take(data: d, label: "相册图片")
                } else {
                    router.showToast("这张图读不出来，换一张试试")
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in
                if let d = img.jpegData(compressionQuality: 0.85) { take(data: d, label: "拍的照片") }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let d = try? Data(contentsOf: url) else {
                router.showToast("这张图读不出来，换一张试试"); return
            }
            take(data: d, label: "文件图片", filename: url.lastPathComponent)
        }
    }

    /// 已存在服务端的一张：点开预览；× 只从草稿里摘掉，保存才真删（过确认，说清这一点）。
    private func savedThumb(_ a: ReminderAtt) -> some View {
        VStack(spacing: 5) {
            AsyncImage(url: HTTPService.shared.moneyFileURL(a.fileId)) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default:
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(UmbraColor.chip)
                        .overlay(UmbraIcon(d: UmbraIconPath.image, size: 18, strokeWidth: 1.8)
                            .foregroundColor(UmbraColor.faint))
                }
            }
            .frame(width: 78, height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW))
            // ⚠️ 这一屏是**编辑态**，所以按 `attachThumb.editing` 走：
            // **图不再点开预览**，× 是这张图上唯一的动作。
            // 原来两个动作叠在一张 78 的图上：点图预览 + 右上角一颗约 25 的 ×。
            // × 撑到 44 的话正中心会落进删除区，不撑又违反 minTapTarget ——
            // 设计侧的解法是把预览这一档从编辑态**拿掉**（编辑时看大图不是主诉求），
            // 冲突就不存在了。看大图去详情页。
            .overlay(alignment: .topTrailing) {
                UmbraAttachRemoveBadge(label: "移除这张附件") {
                    router.confirm(UmbraAlert(
                        title: "移除这张附件？",
                        body: "保存后这张图会从这条提醒上摘掉，服务端的文件也一起清。",
                        confirmLabel: "移除",
                        confirmDestructive: true,
                        onConfirm: { atts.removeAll { $0.fileId == a.fileId } }))
                }
            }
            Text(a.label.isEmpty ? "图片" : a.label)
                .font(UmbraFont.sans(10.5)).foregroundColor(UmbraColor.faint)
                .lineLimit(1)
        }
    }

    /// 本地攒着的一张：还没上传，× 直接撤，不用确认（什么都还没发生）。
    private func pendingThumb(_ p: ReminderPendingImage) -> some View {
        VStack(spacing: 5) {
            Group {
                if let img = UIImage(data: p.data) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(UmbraColor.chip)
                        .overlay(UmbraIcon(d: UmbraIconPath.image, size: 18, strokeWidth: 1.8)
                            .foregroundColor(UmbraColor.faint))
                }
            }
            .frame(width: 78, height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW))
            .overlay(alignment: .topTrailing) {
                UmbraAttachRemoveBadge(label: "撤掉这张") { pending.removeAll { $0.id == p.id } }
            }
            Text("待上传 · \(p.label)")
                .font(UmbraFont.sans(10.5)).foregroundColor(UmbraColor.faint)
                .lineLimit(1)
        }
    }

    /// 「加图」瓦片：虚线框，点了先出来源选择（记账稿：不直接塞空位）。
    private var addTile: some View {
        Button { askAdd() } label: {
            VStack(spacing: 4) {
                UmbraIcon(d: UmbraIconPath.image, size: 18, strokeWidth: 1.9)
                Text("加图").font(UmbraFont.sans(11, .w600))
            }
            .foregroundColor(UmbraColor.muted)
            .frame(width: 78, height: 78)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(UmbraColor.border, style: StrokeStyle(lineWidth: UmbraMetric.borderW, dash: [4, 3]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func askAdd() {
        guard count < UmbraReminder.maxAtts else {
            router.showToast("一条提醒最多留 \(UmbraReminder.maxAtts) 张图"); return
        }
        router.present(UmbraSheet(title: "加图", subtitle: "一条最多 \(UmbraReminder.maxAtts) 张，跟提醒一起存。", items: [
            UmbraSheetItem(label: "从相册选择") { showPhotos = true },
            UmbraSheetItem(label: "拍照") {
                // 模拟器 / 无摄像头设备直说，不给一个点了闪退的入口。
                if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
                else { router.showToast("这台设备没有可用的相机") }
            },
            UmbraSheetItem(label: "从「文件」选择") { showFiles = true },
        ]))
    }

    private func take(data: Data, label: String, filename: String = "") {
        guard count < UmbraReminder.maxAtts else {
            router.showToast("一条提醒最多留 \(UmbraReminder.maxAtts) 张图"); return
        }
        pending.append(ReminderPendingImage(id: UUID(), data: data, label: label, filename: filename))
    }
}

/// 详情**查看态**的附件行：只看不改（改在编辑态），点开应用内预览器。没有附件整块不出现。
struct ReminderAttsPreviewRow: View {
    let atts: [ReminderAtt]
    @State private var viewerItem: UmbraViewerItem?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(atts) { a in
                    AsyncImage(url: HTTPService.shared.moneyFileURL(a.fileId)) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default:
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(UmbraColor.chip)
                                .overlay(UmbraIcon(d: UmbraIconPath.image, size: 18, strokeWidth: 1.8)
                                    .foregroundColor(UmbraColor.faint))
                        }
                    }
                    .frame(width: 78, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW))
                    .onTapGesture {
                        if let u = HTTPService.shared.moneyFileURL(a.fileId) {
                            viewerItem = UmbraViewerItem(url: u, name: a.label.isEmpty ? "图片" : a.label)
                        }
                    }
                }
            }
        }
        .umbraImageViewer(item: $viewerItem)
    }
}
