// 应用内图片预览器（批次 005 稿）。任务详情的步骤截图、聊天完成卡的产出图片、
// 记一笔的附件三处共用，所以放 DesignSystem 而不是某个 Feature ——
// 这是「被两个以上功能用到」的门槛真实达标的情形。
//
// 为什么要自己做而不是跳系统浏览器：截图任务的重点就是看那张图，
// 跳出去再跳回来要过两次 App 切换动画；而且 LAN 地址在 Safari 里一旦
// 服务端换端口就成死链，留在应用内至少还有上下文。
//
// 形态按稿：全屏 #0B0A09 底，顶部 44pt 关闭键 + 等宽文件名 + 44pt 分享键，
// 图片居中 contain，双指放大，点空白（含图本身）关闭，底部一行灰字说明手势。
import SwiftUI

/// 预览器的入参。Identifiable 是为了直接喂给 fullScreenCover(item:) ——
/// 换一张图（id 变）时 SwiftUI 会自动重建预览器，缩放状态不会串到下一张。
struct UmbraViewerItem: Identifiable, Equatable {
    let url: URL
    let name: String
    var id: String { url.absoluteString }

    /// url 看着像不像图片。/files/<id> 这类无扩展名的服务端文件路径按图处理 ——
    /// 判错的代价只是 AsyncImage 失败后退回文件图标，判漏的代价是图片永远点不开。
    /// 三个调用方（步骤截图 / 产出行 / 附件）用同一份口径，别各自再抄一遍正则。
    static func looksImage(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("/files/")
            || [".png", ".jpg", ".jpeg", ".gif", ".webp"].contains { lower.contains($0) }
    }
}

struct UmbraImageViewer: View {
    let item: UmbraViewerItem
    @Environment(\.dismiss) private var dismiss

    /// 双指缩放：steady 是上次手势结束后的稳定倍率，pinch 是本次手势的增量。
    /// 手势进行中允许越界（有橡皮筋感），松手时钳回 1…3（批次 006 稿定的档）——
    /// 直接在进行中钳会顿。稿里另有一条滚轮缩放，是稿内电脑预览专用，**不实现**。
    @State private var steady: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    /// 放大后的平移。只在 steady > 1 时有意义；缩回 1 时清零，
    /// 否则下次放大会从上次挪走的位置开始，图不知道飞哪去了。
    @State private var panSteady: CGSize = .zero
    @GestureState private var pan: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            topBar
            imageArea
            // 脚注跟行为走（批次 006 答复原话照抄）：补了平移，脚注就得说出来。
            Text("双指放大 · 放大后单指拖动 · 点空白关闭")
                .font(UmbraFont.sans(11.5, .w400))
                .foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 14)
        }
        .background(UmbraColor.viewerBg.ignoresSafeArea())
    }

    /// 顶栏：左 44pt 关闭、中间等宽文件名、右 44pt 分享。
    /// 「每个演示态都要有出口：左上关闭键常驻」是稿里的硬规则。
    private var topBar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                UmbraIcon(d: UmbraIconPath.x, size: 20, strokeWidth: 2.2)
                    .foregroundColor(.white.opacity(0.92))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(item.name)
                .font(UmbraFont.mono(13.5, .w560))
                .foregroundColor(.white.opacity(0.86))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            // 分享交给系统面板：存相册、AirDrop、发微信都在里面，不用自己排一排按钮。
            // ShareLink 分享的是 URL 本身（iOS 16 起有）——收到的人在局域网内就能打开原图。
            ShareLink(item: item.url) {
                UmbraIcon(d: UmbraIconPath.shareUp, size: 19, strokeWidth: 1.9)
                    .foregroundColor(.white.opacity(0.92))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private var imageArea: some View {
        // 点空白关闭盖住整个中区（稿：点图或点关闭退出，图本身也算「空白」）。
        // 缩放 + 平移挂在图上、点按挂在容器上：轻点不会被拖拽手势吃掉
        //（DragGesture 默认 10pt 起步距离，tap 够不到它）。
        GeometryReader { _ in
            ZStack {
                Color.clear.contentShape(Rectangle())
                AsyncImage(url: item.url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit()
                            .scaleEffect(steady * pinch)
                            .offset(x: panSteady.width + pan.width,
                                    y: panSteady.height + pan.height)
                            .gesture(zoomGesture.simultaneously(with: panGesture))
                    case .failure:
                        // 加载失败也要能出去/能分享，所以顶栏在外层不受影响；
                        // 这里给一句说明而不是空屏 —— 空屏像预览器坏了。
                        VStack(spacing: 8) {
                            UmbraIcon(d: UmbraIconPath.image, size: 26, strokeWidth: 1.8)
                            Text("图片加载失败")
                                .font(UmbraFont.sans(13, .w400))
                        }
                        .foregroundColor(.white.opacity(0.45))
                    default:
                        ProgressView().tint(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
        }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in
                let next = min(max(steady * value, 1), 3)
                withAnimation(UmbraMotion.tint) {
                    steady = next
                    if next <= 1 { panSteady = .zero }
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .updating($pan) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                // 没放大就不积累平移 —— contain 态图本来居中，拖走了没有手段拖回来。
                guard steady > 1 else { return }
                panSteady.width += value.translation.width
                panSteady.height += value.translation.height
            }
    }
}

extension View {
    /// 挂预览器的统一入口：`.umbraImageViewer(item: $viewerItem)`。
    /// 用 fullScreenCover 而不是自绘浮层：系统帮我们处理转场、手势冲突和状态栏配色，
    /// 且它天然在导航栈之上 —— 自绘浮层在推入页里会被 toolbar 盖住（踩过）。
    func umbraImageViewer(item: Binding<UmbraViewerItem?>) -> some View {
        fullScreenCover(item: item) { UmbraImageViewer(item: $0) }
    }
}
