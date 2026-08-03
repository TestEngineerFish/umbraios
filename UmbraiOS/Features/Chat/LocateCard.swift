// 电脑操作的「人工求助」卡：显示 operate 当前截图，用户可以①拖箭头指位
// ②文字纠偏 ③暂停我来（之后可继续）。箭头尖端换算成归一化坐标(0-1000)回传。
//
// 这段是从旧的 ChatView.swift 里**原样搬过来**的，一行没改：那套交互
//（缩放、平移、抓箭杆整体移动、以尖端为锚点放大）已经调好了，
// 而 iOS 设计交接包里没有这一块的设计稿 —— 没有新稿之前重画一遍只会更差。
// 旧的 ChatView.swift 已经删掉，这个文件是它唯一还活着的部分。
//
// 等这块出了 iOS 设计稿，按 UmbraVaultKit / UmbraPrimitives 那套语言重做，再删掉这个文件。
import SwiftUI

// MARK: - Locate Card（人工求助：箭头指位 / 文字纠偏 / 暂停我来 → 继续）
// 显示 operate 当前截图；箭头尖端(tip)=要点的位置，换算成归一化(0-1000)回传。
struct LocateCard: View {
    let data: ChatBlock.LocateBlock
    let onLocate: (Int, Int) -> Void
    let onFeedback: (String) -> Void
    let onPause: () -> Void
    let onResume: () -> Void

    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var arrowTail: CGPoint?       // 箭尾（图内像素坐标）
    @State private var arrowTip: CGPoint?        // 箭头尖端（图内像素坐标）
    @State private var tipNorm: CGPoint?         // 尖端归一化 0-1000（回传用）
    @State private var feedbackText = ""
    // 缩放（放大后点小目标更准）：支持双指捏合 + 右上角 ＋/－ 按钮，以尖端为锚点放大。
    @State private var zoom: CGFloat = 1
    @State private var pinchBase: CGFloat = 1
    // 拖拽模式：创建新箭头 vs 抓住箭杆整体平移（避免手指挡住尖端）。
    @State private var dragMode: LocateDragMode?
    @State private var moveGrab: CGPoint?        // 平移时的抓取起点（未缩放图内坐标）
    @State private var moveTail0: CGPoint?       // 平移起始的箭尾
    @State private var moveTip0: CGPoint?        // 平移起始的尖端
    // 画箭头 / 拖动画面：默认「画箭头」；放大后关掉它就能拖动查看图片其它区域。
    @State private var drawArrow = true
    @State private var panOffset: CGSize = .zero
    @State private var panBase: CGSize?

    private var fullURL: URL? {
        if data.imageUrl.hasPrefix("http") { return URL(string: data.imageUrl) }
        return URL(string: NetworkConfig.shared.serverUrl + data.imageUrl)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "hand.point.up.left.fill").foregroundColor(UmbraColor.orangeText)
                Text(L("operate.locate.title"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(UmbraColor.orangeText)
            }
            Text(data.hint).font(.system(size: 12.5)).lineSpacing(4)

            if let resolved = data.resolved {
                resolvedView(resolved)
            } else if let image {
                activeView(image)
            } else if loadFailed {
                Text(L("operate.locate.loadFailed")).font(.system(size: 12)).foregroundColor(.red)
                actionRow()  // 加载失败也允许纠偏/暂停
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

    // 已处理后的状态显示（暂停可再点「继续」）。
    @ViewBuilder
    private func resolvedView(_ status: ChatBlock.LocateStatus) -> some View {
        switch status {
        case .located:
            Text(L("operate.locate.done")).font(.system(size: 12)).foregroundColor(UmbraColor.muted)
        case .feedbackSent:
            Text(L("operate.locate.feedbackSent")).font(.system(size: 12)).foregroundColor(UmbraColor.muted)
        case .resumed:
            Text(L("operate.locate.resumed")).font(.system(size: 12)).foregroundColor(UmbraColor.muted)
        case .paused:
            VStack(alignment: .leading, spacing: 8) {
                Text(L("operate.locate.paused")).font(.system(size: 12)).foregroundColor(UmbraColor.muted)
                Button(L("operate.locate.resume")) { onResume() }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // 未处理时的完整交互：截图+箭头、确定指位、文字纠偏、暂停我来。
    private func activeView(_ img: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("operate.locate.arrowHint"))
                .font(.system(size: 11)).foregroundColor(UmbraColor.muted)
            imageWithArrow(img)
            Button(L("operate.locate.confirm")) {
                if let n = tipNorm { onLocate(Int(n.x), Int(n.y)) }
            }
            .buttonStyle(.borderedProminent).tint(.orange)
            .disabled(tipNorm == nil)
            .frame(maxWidth: .infinity)
            actionRow()
        }
    }

    // 文字纠偏输入 + 暂停按钮（指位之外的两条路）。
    private func actionRow() -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField(L("operate.locate.feedbackPlaceholder"), text: $feedbackText, axis: .vertical)
                    .font(.system(size: 12.5))
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                Button(L("operate.locate.sendFeedback")) { onFeedback(feedbackText) }
                    .font(.system(size: 12.5))
                    .buttonStyle(.bordered).tint(.orange)
                    .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button(L("operate.locate.manual")) { onPause() }
                .font(.system(size: 12.5))
                .buttonStyle(.bordered).tint(.gray)
                .frame(maxWidth: .infinity)
        }
    }

    private func imageWithArrow(_ img: UIImage) -> some View {
        let aspect = img.size.width / max(img.size.height, 1)
        return GeometryReader { geo in
            let w = geo.size.width
            let h = w / aspect
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Image(uiImage: img).resizable().frame(width: w, height: h)
                    if let tail = arrowTail, let tip = arrowTip {
                        ArrowShape(from: tail, to: tip)
                            .stroke(Color.red, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        Circle().stroke(Color.red, lineWidth: 2).frame(width: 16, height: 16).position(tip)
                        Circle().fill(Color.red).frame(width: 5, height: 5).position(tip)
                    }
                }
                .frame(width: w, height: h)
                .scaleEffect(zoom, anchor: .center)   // 从中心缩放，配合 panOffset 平移查看
                .offset(panOffset)
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                .gesture(unifiedDrag(w: w, h: h))
                .simultaneousGesture(  // 双指捏合缩放（与单指手势互不冲突）
                    MagnificationGesture()
                        .onChanged { v in zoom = min(max(pinchBase * v, 1), 4) }
                        .onEnded { _ in pinchBase = zoom; if zoom <= 1 { panOffset = .zero } }
                )

                toolbar  // 右上角：箭头开关 + ＋/－
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .coordinateSpace(name: "loc")
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    // 右上角工具：箭头开关（默认开，选中才画箭头；关掉后拖动=移动画面）+ 缩放。
    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { drawArrow.toggle() } label: {
                Image(systemName: "arrow.up.left").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white).padding(6)
                    .background(drawArrow ? Color.orange : Color.black.opacity(0.45))
                    .clipShape(Circle())
            }.buttonStyle(.plain)
            zoomBtn("minus.magnifyingglass") { zoom = max(zoom - 0.5, 1); pinchBase = zoom; if zoom <= 1 { panOffset = .zero } }
            zoomBtn("plus.magnifyingglass") { zoom = min(zoom + 0.5, 4); pinchBase = zoom }
        }
        .padding(6)
    }
    private func zoomBtn(_ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white).padding(6)
                .background(Color.black.opacity(0.45)).clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // 单指拖拽：箭头模式=画/移箭头；关掉箭头模式=平移画面（放大后可查看别处）。
    private func unifiedDrag(w: CGFloat, h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("loc"))
            .onChanged { v in
                if !drawArrow {
                    if panBase == nil { panBase = panOffset }
                    panOffset = CGSize(width: (panBase?.width ?? 0) + v.translation.width,
                                       height: (panBase?.height ?? 0) + v.translation.height)
                    return
                }
                // 把屏幕坐标反算回未缩放图内坐标（考虑当前缩放与平移）。
                let p = unscaled(v.location, w: w, h: h)
                if dragMode == nil {
                    if let tail = arrowTail, let tip = arrowTip,
                       distanceToSegment(unscaled(v.startLocation, w: w, h: h), tail, tip) < 26 {
                        dragMode = .move
                        moveGrab = unscaled(v.startLocation, w: w, h: h); moveTail0 = tail; moveTip0 = tip
                    } else {
                        dragMode = .create
                        arrowTail = clampPt(unscaled(v.startLocation, w: w, h: h), w, h)
                    }
                }
                if dragMode == .create {
                    setTip(clampPt(p, w, h), w: w, h: h)
                } else if let grab = moveGrab, let t0 = moveTail0, let p0 = moveTip0 {
                    let dx = p.x - grab.x, dy = p.y - grab.y
                    arrowTail = clampPt(CGPoint(x: t0.x + dx, y: t0.y + dy), w, h)
                    setTip(clampPt(CGPoint(x: p0.x + dx, y: p0.y + dy), w, h), w: w, h: h)
                }
            }
            .onEnded { _ in dragMode = nil; moveGrab = nil; panBase = nil }
    }

    // 屏幕("loc" 空间)坐标 → 未缩放图内坐标：p = center + (V - center - pan)/zoom
    private func unscaled(_ v: CGPoint, w: CGFloat, h: CGFloat) -> CGPoint {
        let cx = w / 2, cy = h / 2
        return CGPoint(x: cx + (v.x - cx - panOffset.width) / zoom,
                       y: cy + (v.y - cy - panOffset.height) / zoom)
    }

    private func setTip(_ p: CGPoint, w: CGFloat, h: CGFloat) {
        arrowTip = p
        tipNorm = CGPoint(x: p.x / w * 1000, y: p.y / h * 1000)
    }
    private func clampPt(_ p: CGPoint, _ w: CGFloat, _ h: CGFloat) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), w), y: min(max(p.y, 0), h))
    }
    // 点到线段距离（判断是否按在箭杆上）。
    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = min(max(t, 0), 1)
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
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

enum LocateDragMode { case create, move }

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
