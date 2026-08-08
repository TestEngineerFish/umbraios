// 「我」这一 Tab 的全部页面：首页 + 设备与能力 + 设备详情 + 能力 + 工作区 +
// 用户画像 + 连接 / 通知 / 通用 / 关于。
//
// 除首页外都用 UmbraSettingsKit 的那套模板（设计稿本来就是同一个模板）。
//
// 与设计稿的差异，都是「服务端没有这个数据」而不是漏做，逐条写在各页注释里：
//   · 设备详情的「延迟 / 心跳 / 已注册 / 系统授权」—— /devices/all 只回
//     device_id / name / platform / online / last_seen / providers 六项；
//   · 工作区的「目录内容」二级页 —— 服务端没有列目录的接口（设计稿也标了二期）；
//   · 通知页的分类开关 —— 服务端没有推送订阅接口，这一页做成**本机通知权限**的真实入口。
import SwiftUI
import UIKit

// MARK: - 我 · 首页

struct UmbraMeHomeView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var chat: ChatViewModel

    var body: some View {
        UmbraScreen {
            UmbraHeroCard(iconPath: UmbraIconPath.smartphone,
                          name: NetworkConfig.shared.deviceName,
                          badge: "此设备",
                          badgeOn: false,
                          sub: serverHost,
                          subMono: true)
                .padding(.top, 2)
                .padding(.horizontal, UmbraMetric.pagePadX)
                .padding(.bottom, UmbraMetric.sp5)

            vaultEntry
                .padding(.horizontal, UmbraMetric.pagePadX)
                .padding(.bottom, UmbraMetric.sp6)

            VStack(alignment: .leading, spacing: UmbraMetric.sp6) {
                ForEach(groups) { UmbraSettingSectionView(section: $0) }
            }

            Text("电脑操作授权、computer-use 这类开关是执行设备的属性，在「设备与能力」里只读查看，要改去电脑上改。")
                .font(UmbraFont.sans(12, .w400))
                .foregroundColor(UmbraColor.faint)
                .lineSpacing(12 * 0.65)
                .padding(.horizontal, UmbraMetric.pagePadX)
                .padding(.top, UmbraMetric.sp6)
        }
        .navigationTitle("我")
        .refreshable { await chat.reloadDevices() }
        .onAppear { chat.loadDevices() }
    }

    private var serverHost: String {
        let raw = NetworkConfig.shared.serverUrl
        guard let c = URLComponents(string: raw), let h = c.host else { return raw }
        return c.port.map { "\(h):\($0)" } ?? h
    }

    /// 保险箱是「我」里最重的入口，设计稿单独给了一张大卡（40 图标块 + 两行字 + 右侧 Face ID 图形）。
    private var vaultEntry: some View {
        Button {
            router.go(.vaultHome)
        } label: {
            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(UmbraColor.orangeSoft)
                    .frame(width: 40, height: 40)
                    .overlay(
                        UmbraIcon(d: UmbraIconPath.lockKeyhole, size: 20, strokeWidth: 1.9)
                            .foregroundColor(UmbraColor.orangeText)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text("密码保险箱")
                        .font(UmbraFont.sans(17, .w600))
                        .foregroundColor(UmbraColor.text)
                    Text("本地加密保存账号密码，主密码解锁后才可读取。")
                        .font(UmbraFont.sans(12.5, .w400))
                        .foregroundColor(UmbraColor.muted)
                        .lineSpacing(12.5 * 0.5)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                UmbraIcon(d: UmbraIconPath.faceId, size: 30, strokeWidth: 1.6)
                    .foregroundColor(UmbraColor.orange)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous).fill(UmbraColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous)
                    .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var groups: [UmbraSettingSection] {
        [
            UmbraSettingSection(header: "常用", rows: [
                UmbraSettingRow(label: "常用语", chevron: true) { router.go(.mePhrases) },
                UmbraSettingRow(label: "工作区", chevron: true) { router.go(.meWorkspace) }
            ]),
            UmbraSettingSection(header: "设备", rows: [
                UmbraSettingRow(label: "设备与能力",
                                value: chat.devices.isEmpty ? nil : "\(chat.devices.count) 台",
                                chevron: true) { router.go(.meDevices) }
            ]),
            UmbraSettingSection(header: "助手", rows: [
                UmbraSettingRow(label: "用户画像", chevron: true) { router.go(.meProfile) }
            ]),
            UmbraSettingSection(header: "设置", rows: [
                UmbraSettingRow(label: "连接",
                                value: chat.ws.status == .online ? "已连接" : "未连接",
                                chevron: true) { router.go(.setConn) },
                UmbraSettingRow(label: "通知", chevron: true) { router.go(.setNotify) },
                UmbraSettingRow(label: "通用", chevron: true) { router.go(.setGeneral) },
                UmbraSettingRow(label: "关于", chevron: true) { router.go(.setAbout) }
            ])
        ]
    }
}

// MARK: - 设备与能力

struct UmbraDevicesView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var chat: ChatViewModel

    var body: some View {
        UmbraSettingsPage(
            backLabel: "我", title: "设备与能力", onBack: { router.back() },
            intro: "装了 Umbra 客户端的机器就是执行设备。iPhone 不是执行设备，这里只看状态。",
            sections: [
                UmbraSettingSection(
                    header: "设备",
                    footer: chat.devices.isEmpty
                        ? "还没有设备注册上来。在电脑上装好 Umbra 客户端并填上同一个服务端地址就会出现。"
                        : "能力、授权都在设备详情里只读查看。",
                    rows: chat.devices.map { d in
                        UmbraSettingRow(label: d.device_name, sub: deviceSub(d), chevron: true) {
                            router.go(.deviceDetail(id: d.device_id))
                        }
                    })
            ])
            .onAppear { chat.loadDevices() }
    }

    private func deviceSub(_ d: KnownDevice) -> String {
        let state = d.online ? "在线" : "离线 · 最后在线 \(UmbraTime.relative(d.last_seen))"
        return "\(d.platform) · \(state) · \(d.providers.count) 个 provider"
    }
}

// MARK: - 设备详情

struct UmbraDeviceDetailView: View {
    let id: String

    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var chat: ChatViewModel
    /// 「允许在这里直接吩咐它」。工程里这是一个**全局**开关（NetworkConfig.allowDeviceSend），
    /// 设计稿画的是每台设备各一个。没有为它加本地 per-device 存储：
    /// 一个只存在于这台手机、服务端不知道的 per-device 开关，价值不足以换一处新的状态源。
    @State private var allowSend = NetworkConfig.shared.allowDeviceSend

    private var device: KnownDevice? { chat.devices.first { $0.device_id == id } }

    var body: some View {
        Group {
            if let d = device {
                page(d)
            } else {
                UmbraSettingsPage(backLabel: "返回", title: "设备", onBack: { router.back() },
                                  intro: "这台设备不在列表里了，可能已经被移除。")
            }
        }
        .onAppear { chat.loadDevices() }
    }

    private func page(_ d: KnownDevice) -> some View {
        UmbraSettingsPage(
            backLabel: "返回", title: d.device_name, onBack: { router.back() },
            hero: {
                AnyView(UmbraHeroCard(iconPath: UmbraIconPath.monitor,
                                      name: d.device_name,
                                      badge: d.online ? "在线" : "离线",
                                      badgeOn: d.online,
                                      sub: d.online ? "在线中" : "最后在线 \(UmbraTime.relative(d.last_seen))"))
            },
            sections: [
                UmbraSettingSection(header: "信息", rows: [
                    UmbraSettingRow(label: "平台", value: d.platform),
                    UmbraSettingRow(label: "设备 ID", value: d.device_id, mono: true) {
                        UIPasteboard.general.string = d.device_id
                        router.showToast("已复制设备 ID")
                    },
                    UmbraSettingRow(label: "最后在线", value: d.last_seen == nil ? "—" : UmbraTime.absolute(d.last_seen))
                ]),
                capabilitySection(d),
                UmbraSettingSection(
                    header: "会话",
                    footer: "关掉时设备会话是只读的 —— 秘书派下来的任务照样推进来，你只是不能在这里直接吩咐它。这个开关对所有设备生效。",
                    rows: [
                        UmbraSettingRow(label: "允许在这里直接吩咐设备",
                                        sub: "打开后设备会话底部出现输入框",
                                        toggle: allowSend) {
                            allowSend.toggle()
                            NetworkConfig.shared.allowDeviceSend = allowSend
                        }
                    ])
            ],
            footnote: "系统授权（辅助功能、屏幕录制、computer-use 总开关）是执行设备的属性，服务端目前不上报，要看要改都去电脑上。",
            danger: (label: "从联系人列表移除", action: {
                router.confirm(UmbraAlert(
                    title: "把「\(d.device_name)」从联系人列表移除？",
                    body: "它下次上线会重新出现，聊天记录不会删除。",
                    confirmLabel: "移除",
                    confirmDestructive: true,
                    onConfirm: {
                        chat.forgetDevice(d.device_id)
                        router.back()
                        router.showToast("已从联系人列表移除")
                    }))
            }))
    }

    private func capabilitySection(_ d: KnownDevice) -> UmbraSettingSection {
        if d.providers.isEmpty {
            return UmbraSettingSection(
                header: "能力",
                footer: "这台设备还没上报任何能力。",
                rows: [UmbraSettingRow(label: "（还没上报能力）", tint: UmbraColor.faint)])
        }
        return UmbraSettingSection(
            header: "能力",
            footer: "要新增程序或改技能命令模板，去电脑上的「能力」页。",
            rows: d.providers.map { p in
                UmbraSettingRow(label: p.display_name.isEmpty ? p.provider : p.display_name,
                                sub: "\(p.kind) · \(p.skills.count) 个技能",
                                value: p.available ? "已就绪" : (p.unavailable_reason.isEmpty ? "不可用" : p.unavailable_reason),
                                chevron: true) {
                    router.go(.meCaps)
                }
            })
    }
}

// MARK: - 能力（只读）

struct UmbraCapabilitiesView: View {
    @EnvironmentObject private var router: UmbraRouter
    @StateObject private var vm = AbilitiesViewModel()

    var body: some View {
        UmbraSettingsPage(
            backLabel: "返回", title: "能力", onBack: { router.back() },
            intro: "设备上报的 provider 与 skill，手机上一律只读。要改这些去电脑上的「能力」页。",
            sections: sections)
            .onAppear { Task { await vm.loadCapabilities() } }
    }

    private var sections: [UmbraSettingSection] {
        guard !vm.capabilities.isEmpty else {
            return [UmbraSettingSection(
                header: "能力",
                footer: "设备引擎未就绪或暂无 Provider 时这里会空着。",
                rows: [UmbraSettingRow(label: vm.loading ? "正在读取…" : "（还没有能力上报）",
                                       tint: UmbraColor.faint)])]
        }
        // 一台设备的一个 provider = 一个分组。分组标题带设备名，
        // 因为多台设备可能都有同名 provider（两台机器都有 python）。
        return vm.capabilities.flatMap { cap in
            cap.providers.map { p in
                UmbraSettingSection(
                    header: "\(p.display_name.isEmpty ? p.provider : p.display_name) · \(cap.device_name)",
                    footer: p.available ? nil : (p.unavailable_reason.isEmpty ? "当前不可用。" : p.unavailable_reason),
                    rows: p.skills.isEmpty
                        ? [UmbraSettingRow(label: "（这个 provider 没有技能）", tint: UmbraColor.faint)]
                        : p.skills.map { s in
                            UmbraSettingRow(label: s.name, sub: s.description.isEmpty ? nil : s.description,
                                            value: p.available ? "已就绪" : "不可用")
                        })
            }
        }
    }
}

// MARK: - 工作区（只读）

struct UmbraWorkspaceView: View {
    @EnvironmentObject private var router: UmbraRouter
    @State private var list: [Workspace] = []
    @State private var loaded = false

    var body: some View {
        UmbraSettingsPage(
            backLabel: "我", title: "工作区", onBack: { router.back() },
            intro: "工作区是 AI 写文件的落地目录。写代码类任务会自动按目标名建一个，也可以手动指向已有目录。",
            sections: [
                UmbraSettingSection(
                    header: header,
                    footer: "手机上是只读查看：看有哪些工作区、复制路径。新增、删除、打开位置都在电脑上做。",
                    rows: rows)
            ])
            .onAppear {
                guard !loaded else { return }
                loaded = true
                Task { list = await HTTPService.shared.fetchWorkspaces() }
            }
    }

    private var header: String {
        guard !list.isEmpty else { return "工作区" }
        let auto = list.filter { $0.origin == "auto" }.count
        return "共 \(list.count) 个 · \(auto) 个自动创建"
    }

    private var rows: [UmbraSettingRow] {
        guard !list.isEmpty else {
            return [UmbraSettingRow(label: loaded ? "（还没有工作区）" : "正在读取…", tint: UmbraColor.faint)]
        }
        return list.map { w in
            // 点一行 = 复制路径。设计稿写的是进二级页看目录内容，但服务端没有列目录的接口，
            // 与其进一个空页，不如把手机上真正做得到的那件事（复制路径）做顺。
            UmbraSettingRow(
                label: w.name,
                sub: "\(w.dir ?? "路径未知") · \(w.origin == "auto" ? "自动创建" : "手动") · \(UmbraTime.relative(w.last_active_at)) 活动",
                value: w.task_count.map { "\($0) 个任务" }) {
                    UIPasteboard.general.string = w.dir ?? w.name
                    router.showToast("已复制路径")
                }
        }
    }
}

// MARK: - 用户画像

struct UmbraProfileView: View {
    @EnvironmentObject private var router: UmbraRouter
    @State private var markdown = ""
    @State private var loaded = false
    @State private var saving = false

    var body: some View {
        UmbraSettingsPage(
            backLabel: "我", title: "用户画像", onBack: { router.back() },
            intro: "秘书对你的当前认知快照，随对话自动更新；内容有误可直接编辑保存，或重置为空白模板。",
            sections: [],
            extra: {
                VStack(alignment: .leading, spacing: UmbraMetric.sp3) {
                    // 画像是 markdown，用等宽 13/1.75 —— 和设计稿一致。
                    TextEditor(text: $markdown)
                        .font(UmbraFont.mono(13))
                        .lineSpacing(13 * 0.75)
                        .scrollContentBackground(.hidden)
                        .padding(9)
                        .frame(minHeight: 230)
                        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous).fill(UmbraColor.card))
                        .overlay(
                            RoundedRectangle(cornerRadius: UmbraMetric.radiusCard - 2, style: .continuous)
                                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
                        )

                    HStack(spacing: 8) {
                        UmbraButton(title: saving ? "保存中…" : "保存", kind: saving ? .disabled : .primary, height: 46) {
                            save()
                        }
                        UmbraButton(title: "重置为空白模板", kind: .dangerOutline, height: 46) {
                            router.confirm(UmbraAlert(
                                title: "确定要清空用户画像吗？",
                                body: "会重置为空白模板，秘书将重新认识你（不可恢复）。",
                                confirmLabel: "重置",
                                confirmDestructive: true,
                                onConfirm: { reset() }))
                        }
                        .frame(maxWidth: 160)
                    }
                }
                .padding(.horizontal, UmbraMetric.pagePadX)
            })
            .onAppear {
                guard !loaded else { return }
                loaded = true
                Task { markdown = await HTTPService.shared.fetchProfile() }
            }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            let result = await HTTPService.shared.saveProfile(markdown)
            saving = false
            if let result {
                markdown = result          // 以服务端回存的为准
                router.showToast("已保存")
            } else {
                router.showToast("保存失败，检查一下连接")
            }
        }
    }

    private func reset() {
        Task {
            if let result = await HTTPService.shared.resetProfile() {
                markdown = result
                router.showToast("已重置为空白模板")
            } else {
                router.showToast("重置失败，检查一下连接")
            }
        }
    }
}

// MARK: - 连接

struct UmbraConnSettingsView: View {
    @EnvironmentObject private var router: UmbraRouter
    @EnvironmentObject private var chat: ChatViewModel

    @State private var editingAddr = false
    @State private var editingToken = false
    @State private var addr = NetworkConfig.shared.serverUrl
    @State private var tokenInput = ""

    var body: some View {
        UmbraSettingsPage(
            backLabel: "我", title: "连接", onBack: { router.back() },
            sections: [
                UmbraSettingSection(
                    header: "服务端",
                    footer: "访问 Token 就是服务端的 ASSIST_TOKEN（设备注册、常用语与保险箱同步都要用它）。",
                    rows: [
                        UmbraSettingRow(label: "服务端地址", value: NetworkConfig.shared.serverUrl,
                                        mono: true, chevron: true) {
                            addr = NetworkConfig.shared.serverUrl
                            editingAddr = true
                        },
                        UmbraSettingRow(label: "访问 Token",
                                        value: NetworkConfig.shared.token.isEmpty ? "未设置" : "••••••",
                                        chevron: true) {
                            tokenInput = ""
                            editingToken = true
                        },
                        UmbraSettingRow(label: "连接状态", value: statusLabel)
                    ]),
                UmbraSettingSection(rows: [
                    UmbraSettingRow(label: "保存并重连", tint: UmbraColor.orange) {
                        chat.ws.reconnect()
                        router.showToast("正在重连")
                    }
                ])
            ])
            // 输入类的浮层用系统 alert 承接：Router 的 UmbraSheet 只支持选项，没有输入框。
            //
            // **两个 alert 必须挂在两个不同的视图上。** 直接连着写
            // `.alert(A).alert(B)` 的话 SwiftUI 只认第一个，第二个点了毫无反应 ——
            // 「访问 Token」那一行之前就是这么哑掉的，而且它哑掉会连带保险箱解不开。
            .background(
                Color.clear.alert("访问 Token", isPresented: $editingToken) {
                    TextField("粘贴 ASSIST_TOKEN", text: $tokenInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Button("取消", role: .cancel) {}
                    Button("保存 Token") { saveToken() }
                } message: {
                    Text("填服务端的 ASSIST_TOKEN，要和电脑端一模一样。只存在这台手机上。")
                }
            )
            .alert("服务端地址", isPresented: $editingAddr) {
                TextField("https://主机名:端口", text: $addr)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                Button("取消", role: .cancel) {}
                Button("保存并重连") { saveAddr() }
            } message: {
                Text("改完会立刻重连一次。要带上 http:// 或 https://。")
            }
    }

    private var statusLabel: String {
        switch chat.ws.status {
        case .online: return "已连接"
        case .connecting: return "连接中"
        case .offline: return "未连接"
        }
    }

    private func saveAddr() {
        let v = addr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: v), u.scheme != nil, u.host != nil else {
            router.showToast("地址格式不对，应该像 https://umbra.example.com")
            return
        }
        NetworkConfig.shared.serverUrl = v
        chat.ws.reconnect()
        router.showToast("已保存，正在重连")
    }

    private func saveToken() {
        let v = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        NetworkConfig.shared.token = v
        chat.ws.reconnect()
        router.showToast("Token 已更新 · 已重新握手")
    }
}

// MARK: - 通知

struct UmbraNotifySettingsView: View {
    @EnvironmentObject private var router: UmbraRouter
    /// 权限状态直接观察 ReminderStore，不再自己查一遍 ——
    /// 原来这一页和 ReminderStore.refreshAuthorization 是两份一模一样的实现，
    /// 改了一处忘另一处就会出现「提醒页说没授权、通知页说已授权」。
    @ObservedObject private var reminders = ReminderStore.shared

    var body: some View {
        UmbraSettingsPage(
            backLabel: "我", title: "通知", onBack: { router.back() },
            sections: [
                UmbraSettingSection(
                    header: "系统权限",
                    footer: "推送只是提醒你一下。真正的清单以服务端为准，打开应用时会自动补齐漏掉的。",
                    rows: [
                        UmbraSettingRow(label: "通知权限", value: authLabel),
                        UmbraSettingRow(label: "去系统设置", tint: UmbraColor.orange, chevron: true) {
                            openSystemSettings()
                        }
                    ])
            ],
            footnote: "分类开关（提醒到点 / 任务完成 / 任务失败 / 待确认）要等服务端有推送订阅接口才能做。现在还没有，所以这里不摆一排点了不生效的开关。")
            .onAppear { reminders.refreshAuthorization() }
    }

    private var authLabel: String {
        switch reminders.notifyAuthorized {
        case .some(true): return "已授权"
        case .some(false): return "未授权"
        case .none: return "读取中…"
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - 通用

struct UmbraGeneralSettingsView: View {
    @EnvironmentObject private var router: UmbraRouter
    @ObservedObject private var lang = LanguageManager.shared
    @AppStorage("umbra.appearance") private var appearance = UmbraAppearance.system.rawValue

    var body: some View {
        UmbraSettingsPage(
            backLabel: "我", title: "通用", onBack: { router.back() },
            sections: [
                UmbraSettingSection(
                    header: "外观与语言",
                    footer: "切换语言后立即生效；跟随系统时会随日夜自动切换。",
                    rows: [
                        UmbraSettingRow(label: "界面语言", value: langLabel, chevron: true) { pickLanguage() },
                        UmbraSettingRow(label: "外观", value: current.label, chevron: true) { pickAppearance() }
                    ])
            ])
    }

    private var current: UmbraAppearance { UmbraAppearance(rawValue: appearance) ?? .system }

    /// 当前语言的显示名。「跟随系统」要标出实际解析成了哪种语言 ——
    /// 只写「跟随系统」的话，用户看不出现在到底是中文还是英文。
    private var langLabel: String {
        switch lang.preference {
        case .chinese: return "中文"
        case .english: return "English"
        case .system: return lang.effectiveLanguage == .english ? "跟随系统 · English" : "跟随系统 · 中文"
        }
    }

    private func pickAppearance() {
        router.present(UmbraSheet(title: "外观", items: UmbraAppearance.allCases.map { a in
            UmbraSheetItem(label: a.label, checked: current == a) { appearance = a.rawValue }
        }))
    }

    /// 语言切换走既有的 LanguageManager（工程里已经有一整套 xcstrings 本地化）。
    /// 设计稿只列了「中文 / English」两项，这里多一项「跟随系统」——
    /// LanguageManager 本来就有这一档，藏起来等于把已有能力关掉。
    private func pickLanguage() {
        router.present(UmbraSheet(
            title: "界面语言",
            subtitle: "切换后立即生效。",
            items: [
                UmbraSheetItem(label: "中文", checked: lang.preference == .chinese) { lang.preference = .chinese },
                UmbraSheetItem(label: "English", checked: lang.preference == .english) { lang.preference = .english },
                UmbraSheetItem(label: "跟随系统", checked: lang.preference == .system) { lang.preference = .system }
            ]))
    }
}

/// 外观三档。存 UserDefaults，由根视图读出来设 preferredColorScheme。
enum UmbraAppearance: String, CaseIterable {
    case light, dark, system
    var label: String {
        switch self {
        case .light: return "浅色"
        case .dark: return "深色"
        case .system: return "跟随系统"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

// MARK: - 关于

struct UmbraAboutView: View {
    @EnvironmentObject private var router: UmbraRouter

    var body: some View {
        UmbraSettingsPage(
            backLabel: "我", title: "关于", onBack: { router.back() },
            sections: [
                UmbraSettingSection(rows: [
                    UmbraSettingRow(label: "Umbra", value: version),
                    UmbraSettingRow(label: "客户端 ID", value: NetworkConfig.shared.clientId, mono: true) {
                        UIPasteboard.general.string = NetworkConfig.shared.clientId
                        router.showToast("已复制")
                    }
                ])
            ],
            footnote: "iPhone 端只做「接头与随手记」：收通知、随手记、随手查、随手答一句。要坐下来配的东西在电脑上做。")
    }

    /// 版本号从 Info.plist 读，**不写死** —— 写死的版本号在下一次发版时一定忘了改。
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b)) · iOS"
    }
}
