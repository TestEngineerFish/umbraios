// 聊天 · 会话列表（chat.contacts）。
//
// 数据全部来自既有的 ChatViewModel：contacts / convLabel / device(for:) / previews /
// unread / ws.status。**没有 mock** —— 服务端连不上时就是空预览 + 离线态，那也是真实状态。
//
// 取值来自主设计稿：分区标题 600/12/.06em、卡片圆角 12（注意这里是 12 不是 14，
// 设计稿上会话卡就是 12）、行 11/13 内边距、头像 48（秘书圆形、设备圆角 14）、
// 图标 22/stroke 1.9、名字 560/16、在线徽标 560/11。
import SwiftUI

struct UmbraChatContactsView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var chat: ChatViewModel

    var body: some View {
        UmbraPage(navBar: {
            EmptyView()
        }, content: {
            UmbraTitleHeader(title: "聊天")

            // 分区标题行：左「联系人」，右侧是连接状态（StatusBarChip）。
            // 状态不占一整行 —— 增补规范里这条组件就是为了替掉占行的状态卡。
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                UmbraSectionLabel(text: "联系人")
                Spacer(minLength: 0)
                // 单独一个小组件去 observe ws：ChatWebSocket 是嵌套的 ObservableObject，
                // 直接在这里读 chat.ws.status 不会触发重绘 —— 连接状态会永远停在首次渲染的值。
                UmbraConnChip(ws: chat.ws, server: serverHost)
            }
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.top, 2)
            .padding(.bottom, 8)

            UmbraGroupCard {
                ForEach(Array(chat.contacts.enumerated()), id: \.element) { idx, conv in
                    if idx > 0 { UmbraRowDivider() }
                    contactRow(conv)
                }
            }
            .padding(.horizontal, UmbraMetric.pagePadX)

            Text("左滑设备行可从联系人列表移除。秘书行不可移除。")
                .font(UmbraFont.sans(12, .w400))
                .foregroundColor(UmbraColor.faint)
                .lineSpacing(12 * 0.7)
                .padding(.horizontal, UmbraMetric.pagePadX)
                .padding(.top, UmbraMetric.sp4)
        })
        .onAppear { chat.loadDevices() }
    }

    // MARK: - 行

    @ViewBuilder
    private func contactRow(_ conv: String) -> some View {
        let isSecretary = conv == ChatViewModel.mainConv
        let dev = chat.device(for: conv)
        let preview = chat.previews[conv]
        let unread = chat.unread.contains(conv)

        Button {
            chat.switchConversation(conv)
            router.go(.chatThread(conv: conv))
        } label: {
            HStack(spacing: UmbraMetric.sp4) {
                avatar(isSecretary: isSecretary, online: dev?.online ?? false)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(chat.convLabel(conv))
                            .font(UmbraFont.sans(16, .w560))
                            .foregroundColor(UmbraColor.text)
                            .lineLimit(1)

                        // 在线用「绿点 + 已连接」文字；离线只有空心圈。
                        // 状态不只靠颜色 —— 在线那档带文字，离线那档靠形状（空心）区分。
                        if let d = dev, d.online {
                            HStack(spacing: 4) {
                                Circle().fill(UmbraColor.success).frame(width: 6, height: 6)
                                Text("已连接").font(UmbraFont.sans(11, .w560))
                            }
                            .foregroundColor(UmbraColor.success)
                        } else if dev != nil {
                            Circle()
                                .strokeBorder(UmbraColor.faint, lineWidth: 1.5)
                                .frame(width: 7, height: 7)
                        }

                        Spacer(minLength: 0)

                        Text(timeLabel(preview?.at))
                            .font(UmbraFont.sans(12, .w400))
                            .foregroundColor(UmbraColor.faint)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(previewText(conv, preview: preview, isSecretary: isSecretary))
                            .font(UmbraFont.rowSub)
                            .foregroundColor(UmbraColor.muted)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        if unread {
                            // 未读用橙色圆点而不是数字：ChatViewModel 只记「有没有未读」
                            // （unread 是 Set<String>），编不出一个真实的条数。
                            // 摆一个假数字比不摆更糟。
                            Circle().fill(UmbraColor.orange).frame(width: 8, height: 8)
                        } else if let d = dev, !d.online, let seen = d.last_seen {
                            Text("最后在线 \(timeLabel(seen))")
                                .font(UmbraFont.sans(12, .w400))
                                .foregroundColor(UmbraColor.faint)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func avatar(isSecretary: Bool, online: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: isSecretary ? 24 : 14, style: .continuous)
        shape
            .fill(isSecretary ? UmbraColor.orange : UmbraColor.chip)
            .frame(width: 48, height: 48)
            .overlay(
                UmbraIcon(d: isSecretary ? UmbraIconPath.robot : UmbraIconPath.monitor,
                          size: 22, strokeWidth: 1.9)
                    .foregroundColor(isSecretary ? .white : (online ? UmbraColor.muted : UmbraColor.faint))
            )
    }

    // MARK: - 取值

    /// 状态行只显示 host（+端口），不显示协议 —— 设计稿是 `assist.umbra.local:8770` 这种形态。
    private var serverHost: String {
        let raw = NetworkConfig.shared.serverUrl
        guard let c = URLComponents(string: raw), let h = c.host else { return raw }
        return c.port.map { "\(h):\($0)" } ?? h
    }

    private func previewText(_ conv: String, preview: ChatViewModel.ConvPreview?, isSecretary: Bool) -> String {
        if let t = preview?.text, !t.isEmpty {
            // 预览是单行的，把换行压成空格，否则会把第二行整段吞掉只剩半句
            return t.replacingOccurrences(of: "\n", with: " ")
        }
        return isSecretary ? "你的 AI 秘书" : "还没有对话"
    }

    /// ISO8601 → 「09:41」/「昨天」/「7月28日」。解析不了就原样返回，不要给个假时间。
    private func timeLabel(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let d = date else { return iso }
        let cal = Calendar.current
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(d) {
            df.dateFormat = "HH:mm"
            return df.string(from: d)
        }
        if cal.isDateInYesterday(d) { return "昨天" }
        df.dateFormat = "M月d日"
        return df.string(from: d)
    }
}

/// 连接状态小组件。**必须**单独 observe ChatWebSocket：
/// 它是挂在 ChatViewModel 上的嵌套 ObservableObject，父层的 objectWillChange 不会因为
/// 它的 @Published 变化而发出，写成 chat.ws.status 的话状态点只在别的东西变时才顺带刷新。
private struct UmbraConnChip: View {
    @ObservedObject var ws: ChatWebSocket
    let server: String

    var body: some View {
        UmbraStatusBarChip(online: ws.status == .online, text: "\(label) · \(server)")
    }

    private var label: String {
        switch ws.status {
        case .online: return "已连接"
        case .connecting: return "连接中"
        case .offline: return "未连接"
        }
    }
}
