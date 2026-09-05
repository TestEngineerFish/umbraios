// 聊天里的图片消息（批次 011 ③）。
//
// 这个文件只管**画**和**选**，发和传在 ChatViewModel 里（sendImages / runUpload）。
// 拆出来是因为 ChatThreadView 已经一千多行，再塞进去就没人愿意读了。
//
// 三条稿定的规矩，改之前先看这里：
//   1. **图文分条**：图片单独成条，配的文字紧跟一条。塞进一个气泡的话，用户点「删除」
//      时说不清删的是图还是话（`imageMessage.whySplit`）。
//   2. **一条 = N 张图，不是 N 条**：预览器里左右切的就是这一条里的图。
//   3. **多张走固定格子**，不按比例排：按比例排 5 张竖图，那一屏会歪得没法看
//      （`imageMessage.bubble.grid`）。
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 取值

enum ChatImageMetric {
    /// 单图长边上限（`imageMessage.bubble.single`，iOS 档）。**保比例**，不是固定框。
    static let singleMax: CGFloat = 220
    /// 多图的固定格子边长。
    static let cell: CGFloat = 68
    /// 多图一行几个。
    static let columns = 3
    /// 多图外面那层气泡的内边距与格间距。
    static let gridPad: CGFloat = 5
    static let gridGap: CGFloat = 6
    /// 待发缩略条里一格的边长（`imageMessage.pendingStrip`）。
    static let pending: CGFloat = 64
    /// 单张上限 10 MB、一次 9 张（`imageMessage.limits`）。
    static let maxBytes = 10 * 1024 * 1024
    static let maxCount = 9
}

/// 字节 → 「1.8 MB」。上传进度行用；不足 0.1 MB 的也照 MB 说 —— 单位一致才好比大小。
func umbraMB(_ n: Int) -> String {
    String(format: "%.1f MB", max(0, Double(n)) / 1_048_576)
}

// MARK: - 待发的一张

/// 还没发出去、攒在输入框上方那条里的一张图。
/// `oversize` 的那张**留在条里标红**，不是直接吞掉 —— 吞掉的话用户会以为自己没选中
///（`imageMessage.limits.overLimit` 点名）。
struct ChatPendingImage: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    /// 第几张（错误文案要说清是哪一张），由条自己按下标算，这里不存。
    var bytes: Int { data.count }
    var oversize: Bool { bytes > ChatImageMetric.maxBytes }
}

// MARK: - 消息里的图片块

/// 一条图片消息。单图按比例给 220 上限，多图走 3 列固定 68 网格外套一层气泡底。
struct ChatImageBubble: View {
    let block: ChatBlock.ImageBlock
    /// 点某一张：交给外面开预览器（要带上这一条里的全部图，好左右切）。
    var onOpen: (Int) -> Void

    private var single: Bool { block.count == 1 }

    var body: some View {
        if single {
            // ⚠️ 框要**自己算死**，不能只给 `.aspectRatio(ratio, .fit)` + `maxWidth/maxHeight`：
            // 竖直 ScrollView 给下来的高度提案是 nil，弹性 frame 在那一维不会把 220 传下去，
            // 于是竖图算成 220×293（长边破了 220）再被 clipShape 裁掉上下 —— 就是「中心裁切」。
            // 横图看不出来，所以自测很容易漏。
            cell(0)
                .frame(width: box.width, height: box.height)
                .clipShape(UmbraBubbleShape(mine: true))
                .overlay(UmbraBubbleShape(mine: true)
                    .stroke(borderColor, lineWidth: UmbraMetric.borderW))
                .opacity(block.state == .failed ? 0.55 : 1)
        } else {
            grid
        }
    }

    /// 单图的框：长边 220，短边按比例。
    /// 比例优先用发送时存下的 `ratioHint`（认领回执之后本地原图会被清掉，现算的话
    /// 比例会在那一帧从真实值跳成占位值、图两边冒灰边）；拿不到就按 4:3 占位 ——
    /// 服务端没有尺寸字段，猜一个总比让布局先塌再跳好。
    private var box: CGSize {
        let m = ChatImageMetric.singleMax
        let r = block.ratioHint ?? 4.0 / 3.0
        return r >= 1 ? CGSize(width: m, height: m / r) : CGSize(width: m * r, height: m)
    }

    /// 多图：3 列固定格子。外层宽度写死成「3 格 + 2 间距 + 2 内边距」，
    /// 让第二行的格子和第一行严格对齐 —— 用 flex 换行的话最后一行会被拉开。
    private var grid: some View {
        // 列数跟着张数走：2 张就 2 列，气泡跟着收窄。写死 3 列的话 2 张也画成
        // 226 宽的气泡、右边空一格 —— 那不是「格子对齐」，是气泡比内容宽。
        let cols = min(ChatImageMetric.columns, block.count)
        let w = CGFloat(cols) * ChatImageMetric.cell
            + CGFloat(cols - 1) * ChatImageMetric.gridGap
            + 2 * ChatImageMetric.gridPad
        return LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(ChatImageMetric.cell),
                                               spacing: ChatImageMetric.gridGap),
                           count: cols),
            spacing: ChatImageMetric.gridGap
        ) {
            ForEach(0..<block.count, id: \.self) { i in
                cell(i)
                    .frame(width: ChatImageMetric.cell, height: ChatImageMetric.cell)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: UmbraMetric.borderW))
            }
        }
        .padding(ChatImageMetric.gridPad)
        .frame(width: w)
        .background(UmbraBubbleShape(mine: true).fill(UmbraColor.userBubble))
        .opacity(block.state == .failed ? 0.55 : 1)
    }

    /// 失败时描边转 --danger（`imageMessage.failed`）。
    private var borderColor: Color {
        block.state == .failed ? UmbraColor.danger : UmbraColor.borderSoft
    }

    /// 一格：图 + 上传罩。已经有 file_id 的从服务端取（那份是正本），
    /// 还没传上去的用本地数据顶着 —— 不然从选图到传完那几秒是一片空白。
    private func cell(_ i: Int) -> some View {
        ZStack {
            if i < block.atts.count, let url = HTTPService.shared.moneyFileURL(block.atts[i]) {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: single ? .fit : .fill)
                    }
                }
            } else if i < block.data.count, let ui = UIImage(data: block.data[i]) {
                Image(uiImage: ui).resizable().aspectRatio(contentMode: single ? .fit : .fill)
            }
            if let frac = uploadFrac(i) { UmbraUploadVeil(frac: frac) }
        }
        // 底色走 background：它不参与父级的尺寸计算，不会像 Rectangle 那样把比例吃掉。
        // 单图用气泡底（比例是猜的时候两边会露出来，露出气泡色比露出 chip 灰自然），
        // 多图的格子仍是 chip —— 它外面已经套了一层气泡底。
        .background(single ? UmbraColor.userBubble : UmbraColor.chip)
        .contentShape(Rectangle())
        .onTapGesture {
            // 传到一半的点不开 —— 服务端上还没有这张，预览器只会转个圈然后失败。
            if uploadFrac(i) == nil { onOpen(i) }
        }
    }

    /// 这一格该不该盖上传罩，以及盖多少。
    /// 已经传完的不盖；正在传的走它自己的百分比；还没轮到的盖 0% ——
    /// 稿把环画在**格子上**，所以每格各有各的进度，不是全条共用一个。
    private func uploadFrac(_ i: Int) -> Double? {
        // `.awaitingReceipt` 时 atts 已经齐了，下面那句自然返回 nil —— 不盖罩是对的：
        // 那一档在等回执，不是在传。
        guard block.state == .uploading else { return nil }
        if i < block.atts.count { return nil }
        return i == block.atts.count ? block.currentFrac : 0
    }
}

/// 上传罩：半透明黑底 + 白色**确定型**进度环 + 百分比。
/// 「有真百分比就别用旋转弧 —— 旋转弧说的是『不知道要多久』」（`imageMessage.uploading`）。
struct UmbraUploadVeil: View {
    let frac: Double

    var body: some View {
        ZStack {
            Color(red: 12 / 255, green: 10 / 255, blue: 9 / 255).opacity(0.5)
            VStack(spacing: 6) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.26), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(0.001, min(1, frac)))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))   // 从 12 点起画，不是 3 点
                }
                .frame(width: 30, height: 30)
                Text("\(Int((max(0, min(1, frac)) * 100).rounded()))%")
                    .font(UmbraFont.mono(12, .w600))
                    .foregroundColor(.white)
            }
            // 68 的格子里塞不下 38 环 + 12 字，多图时只留环。
            .scaleEffect(0.9)
        }
    }
}

// MARK: - 待发缩略条

/// 输入框上方那条：64 缩略 + 右上角 × + 末尾虚线「+」+ 右端计数「3 / 9」。
/// 超限那张留在条里标红，下面一行说清是哪张、多大。
struct ChatPendingStrip: View {
    @Binding var items: [ChatPendingImage]
    var onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { _, p in
                            thumb(p)
                        }
                        addButton
                    }
                }
                Text("\(items.count) / \(ChatImageMetric.maxCount)")
                    .font(UmbraFont.mono(11.5, .w600))
                    .foregroundColor(UmbraColor.faint)
                    .fixedSize()
            }
            if let bad = items.firstIndex(where: { $0.oversize }) {
                oversizeNote(index: bad)
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 8)
    }

    private func thumb(_ p: ChatPendingImage) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Rectangle().fill(UmbraColor.chip)
                if let ui = UIImage(data: p.data) {
                    Image(uiImage: ui).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: ChatImageMetric.pending, height: ChatImageMetric.pending)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(p.oversize ? UmbraColor.danger : UmbraColor.borderSoft,
                              lineWidth: UmbraMetric.borderW))

            // 待发缩略条是 `attachThumb` 点名的三处**编辑态**之一（另两处是提醒编辑、记一笔编辑），
            // 所以它和那两处用同一个件。这里原来是自己写的一份 —— 行为一样（贴角 44、
            // 不用负边距，`cornerPinFirst` 那条规矩就是从这处的做法采纳上去的），
            // 但长相和另两处不同，同一个「摘掉这张图」的动作不该有两种样子。
            // 64 的格上贴角内缩 4：热区 x∈[16,60]、y∈[4,48]，仍然整块落在自己那格里，
            // 不越过 HStack 的 8pt 间隙。
            UmbraAttachRemoveBadge(label: L("chat.img.remove")) {
                items.removeAll { $0.id == p.id }
            }
        }
    }

    /// 末尾那颗虚线「+」。选满 9 张转 --faint（`imageMessage.limits.tooMany`）。
    private var addButton: some View {
        let full = items.count >= ChatImageMetric.maxCount
        return Button(action: onAdd) {
            UmbraIcon(d: UmbraIconPath.plus, size: 18, strokeWidth: 1.9)
                .foregroundColor(full ? UmbraColor.faint : UmbraColor.muted)
                .frame(width: ChatImageMetric.pending, height: ChatImageMetric.pending)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(UmbraColor.border,
                                  style: StrokeStyle(lineWidth: UmbraMetric.borderW, dash: [4, 3])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("chat.attach.add"))
    }

    /// 超限那一行：说清是**第几张**、多大。「有图片超限」这种笼统说法用户会以为自己没选中。
    private func oversizeNote(index: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            UmbraIcon(d: UmbraIconPath.alertTriangle, size: 13, strokeWidth: 1.9)
                .foregroundColor(UmbraColor.danger)
                .padding(.top, 2)
            Text(L("chat.img.oversize", index + 1, umbraMB(items[index].bytes),
                   umbraMB(ChatImageMetric.maxBytes)))
                .font(UmbraFont.sans(12, .w400))
                .foregroundColor(UmbraColor.danger)
                .lineSpacing(12 * 0.55)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 选图

/// 相册 / 拍照 / 文件三个入口的宿主。三条路挑出来的都是 Data，交给同一个回调。
///
/// 做成 modifier 而不是塞进对话页：PhotosPicker / UIImagePickerController / fileImporter
/// 各自要一个 @State 开关和一个 sheet，三套堆在已经很长的对话页里没法读。
struct ChatImagePickers: ViewModifier {
    @Binding var showPhotos: Bool
    @Binding var showCamera: Bool
    @Binding var showFiles: Bool
    /// 还能再收几张 —— 相册多选的上限跟着它走，选超了系统自己会拦。
    var remaining: Int
    var onPick: ([Data]) -> Void

    @State private var picked: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $showPhotos, selection: $picked,
                          maxSelectionCount: max(1, remaining), matching: .images)
            .onChange(of: picked) { items in
                guard !items.isEmpty else { return }
                picked = []
                Task {
                    var out: [Data] = []
                    for it in items {
                        if let d = try? await it.loadTransferable(type: Data.self) { out.append(d) }
                    }
                    if !out.isEmpty { onPick(out) }
                }
            }
            .sheet(isPresented: $showCamera) {
                // 相机给的是 UIImage，压成 JPEG 再走同一条上传路 —— 原图 HEIC 有的服务端认不了，
                // 而且随手一张就十几 MB，正好撞上单张 10 MB 的上限。
                CameraPicker { img in
                    if let d = img.jpegData(compressionQuality: 0.9) { onPick([d]) }
                }
                .ignoresSafeArea()
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image],
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                // 「文件」给的是沙箱外的 URL，必须先要安全域访问权限，否则读出来是空的。
                let out = urls.compactMap { url -> Data? in
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    return try? Data(contentsOf: url)
                }
                if !out.isEmpty { onPick(out) }
            }
    }
}

extension View {
    func chatImagePickers(showPhotos: Binding<Bool>, showCamera: Binding<Bool>,
                          showFiles: Binding<Bool>, remaining: Int,
                          onPick: @escaping ([Data]) -> Void) -> some View {
        modifier(ChatImagePickers(showPhotos: showPhotos, showCamera: showCamera,
                                  showFiles: showFiles, remaining: remaining, onPick: onPick))
    }
}
