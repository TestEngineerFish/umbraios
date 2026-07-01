import SwiftUI

// MARK: - Me View
struct MeView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var config = NetworkConfig.shared
    @State private var showingEditServer = false
    @State private var showingEditToken = false
    @State private var cuEnabled: Bool = UserDefaults.standard.bool(forKey: "cuEnabled")

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Device card
                    deviceCard

                    // Connection section
                    section(title: "连接") {
                        settingRow(title: "服务端地址", value: config.serverUrl) {
                            showingEditServer = true
                        }
                        rowDivider
                        settingRow(title: "访问 Token", value: "••••••") {
                            showingEditToken = true
                        }
                    }

                    // Execution section
                    section(title: "执行与权限") {
                        ToggleRow(title: "辅助功能", isOn: .constant(true))
                            .disabled(true)
                        rowDivider
                        ToggleRow(title: "computer-use 总开关", isOn: $cuEnabled)
                            .onChange(of: cuEnabled) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "cuEnabled")
                            }
                    }

                    // General section
                    section(title: "通用") {
                        ToggleRow(title: "自动朗读回复", isOn: $appState.autoReadReplies)
                        rowDivider
                        ToggleRow(title: "深色模式", isOn: $appState.isDarkMode)
                        rowDivider
                        HStack {
                            Text("关于")
                                .font(.system(size: 13.5))
                            Spacer()
                            Text("v0.4.2")
                                .font(.system(size: 12))
                                .foregroundColor(.umbraMuted)
                        }
                        .padding(.vertical, 13)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)
            }
            .navigationTitle("我的")
            .sheet(isPresented: $showingEditServer) {
                EditServerSheet()
            }
            .sheet(isPresented: $showingEditToken) {
                EditTokenSheet()
            }
        }
    }

    // MARK: - Device Card
    private var deviceCard: some View {
        HStack(spacing: 12) {
            Text("U")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.orange)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(UIDevice.current.name)
                    .font(.system(size: 15, weight: .semibold))
                Text("iOS · 已登记为执行设备")
                    .font(.system(size: 12))
                    .foregroundColor(.umbraMuted)
            }

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text("在线")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
            }
        }
        .padding(15)
        .background(umbraColor(\.card))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(umbraColor(\.border), lineWidth: 1)
        )
    }

    // MARK: - Section
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.umbraMuted)
                .padding(.horizontal, 4)
                .padding(.bottom, 7)

            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 4)
            .background(umbraColor(\.card))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(umbraColor(\.border), lineWidth: 1)
            )
        }
    }

    // MARK: - Setting Row
    private func settingRow(title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13.5))
                Spacer()
                Text(value)
                    .font(.system(size: 12))
                    .foregroundColor(.umbraMuted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.umbraMuted)
            }
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Row Divider（行与行之间的分割线；不再用每行 overlay，避免错位/横切开关）
    private var rowDivider: some View {
        Rectangle()
            .fill(umbraColor(\.border))
            .frame(height: 1)
    }
}

// MARK: - Toggle Row
struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13.5))
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color.umbraOrange)
        }
        .padding(.vertical, 13)
    }
}

// MARK: - Edit Server Sheet
struct EditServerSheet: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var config = NetworkConfig.shared
    @State private var serverUrl: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("服务端地址") {
                    TextField("https://...", text: $serverUrl)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("编辑服务端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        config.serverUrl = serverUrl
                        dismiss()
                    }
                }
            }
            .onAppear { serverUrl = config.serverUrl }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Edit Token Sheet
struct EditTokenSheet: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var config = NetworkConfig.shared
    @State private var token: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("访问 Token") {
                    SecureField("输入 Token", text: $token)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("编辑 Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        config.token = token
                        dismiss()
                    }
                }
            }
            .onAppear { token = config.token }
        }
        .presentationDetents([.medium])
    }
}
