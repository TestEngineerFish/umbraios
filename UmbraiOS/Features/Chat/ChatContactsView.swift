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
        // v2：List 承载（系统左滑移除设备行要它），大标题交给系统栏。
        List {
            Section {
                ForEach(chat.contacts, id: \.self) { conv in
                    contactRow(conv)
                        .listRowBackground(UmbraColor.card)
                }
            } header: {
                // 分区标题行：左「联系人」，右侧是连接状态（StatusBarChip）。
                // 状态不占一整行 —— 增补规范里这条组件就是为了替掉占行的状态卡。
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("联系人")
                        .font(UmbraFont.sans(12, .w600))
                        .tracking(UmbraFont.labelTracking(12))
                        .foregroundColor(UmbraColor.faint)
                        .textCase(nil)
                    Spacer(minLength: 0)
                    // 单独一个小组件去 observe ws：ChatWebSocket 是嵌套的 ObservableObject，
                    // 直接在这里读 chat.ws.status 不会触发重绘 —— 状态会停在首次渲染的值。
                    UmbraConnChip(ws: chat.ws, server: serverHost)
                }
            }

        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UmbraColor.bg)
        .navigationTitle("聊天")
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .refreshable { await chat.reloadDevices() }
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
                            // 未读用圆点而不是数字：ChatViewModel 只记「有没有未读」
                            // （unread 是 Set<String>），编不出一个真实的条数。
                            // 摆一个假数字比不摆更糟。
                            //
                            // 取色跟计数角标同源（badgeRed = systemRed）：2026-08-22 稿的
                            // 硬规则是「角标一律 --danger 实底」，但底栏回归系统 bar 后
                            // 徽标是系统红 —— iOS 端把「角标红」统一映射到 systemRed
                            //（--danger 留给破坏性操作；已记台账待设计确认）。
                            // 不用橙的理由不变：秘书行头像本来就是橙的，橙点会糊在一起。
                            Circle().fill(UmbraColor.badgeRed).frame(width: 8, height: 8)
                        } else if let d = dev, !d.online, let seen = d.last_seen {
                            Text("最后在线 \(timeLabel(seen))")
                                .font(UmbraFont.sans(12, .w400))
                                .foregroundColor(UmbraColor.faint)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // 只有设备行能移除；秘书行不给动作。破坏性操作必进确认弹窗。
            if let d = dev {
                Button {
                    router.confirm(UmbraAlert(
                        title: "从联系人移除「\(chat.convLabel(conv))」？",
                        body: "只是从列表里拿掉，设备重新连上会再次出现。",
                        confirmLabel: "移除",
                        confirmDestructive: true,
                        onConfirm: {
                            chat.forgetDevice(d.device_id)
                            router.showToast("已移除")
                        }))
                } label: {
                    Label("移除", systemImage: "minus.circle")
                }
                .tint(UmbraColor.danger)
            }
        }
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

    /// 服务端时间 → 「09:41」/「昨天」/「7月28日」。解析不了就原样返回，不要给个假时间。
    ///
    /// 走 UmbraShared 那一份统一解析：这里原本自己又挂了一遍 ISO8601（全 App 第三份），
    /// 而 /history 回的 created_at 是 SQLite 的「2026-08-08 14:15:09」——
    /// 两个 ISO 解析器都吃不下，于是会话列表右上角直接显示一串原始时间戳。
    private func timeLabel(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "" }
        guard let d = UmbraShared.parseServerDate(iso) else { return iso }
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
