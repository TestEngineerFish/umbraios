import SwiftUI

// MARK: - Me View
struct MeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var languageManager: LanguageManager
    @StateObject private var config = NetworkConfig.shared
    @State private var showingEditServer = false
    @State private var showingEditToken = false
    @State private var showingLanguagePicker = false
    @State private var cuEnabled: Bool = UserDefaults.standard.bool(forKey: "cuEnabled")
    @State private var allowDeviceSend: Bool = NetworkConfig.shared.allowDeviceSend
    @State private var autoApproveOperate: Bool = NetworkConfig.shared.autoApproveOperate

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    deviceCard

                    section(title: L("me.connection")) {
                        settingRow(title: L("me.serverUrl"), value: config.serverUrl) {
                            showingEditServer = true
                        }
                        rowDivider
                        settingRow(title: L("me.accessToken"), value: "••••••") {
                            showingEditToken = true
                        }
                    }

                    section(title: L("me.execution")) {
                        ToggleRow(title: L("me.accessibility"), isOn: .constant(true))
                            .disabled(true)
                        rowDivider
                        ToggleRow(title: L("me.computerUse"), isOn: $cuEnabled)
                            .onChange(of: cuEnabled) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "cuEnabled")
                            }
                    }

                    section(title: L("me.allowDeviceSend")) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L("me.allowDeviceSend"))
                                    .font(.system(size: 13.5))
                                Text(L("me.allowDeviceSend.desc"))
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.umbraMuted)
                            }
                            Spacer()
                            Toggle("", isOn: $allowDeviceSend)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .tint(Color.umbraOrange)
                                .onChange(of: allowDeviceSend) { newValue in
                                    NetworkConfig.shared.allowDeviceSend = newValue
                                }
                        }
                        .padding(.vertical, 13)
                        rowDivider
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L("me.autoApproveOperate"))
                                    .font(.system(size: 13.5))
                                Text(L("me.autoApproveOperate.desc"))
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.umbraMuted)
                            }
                            Spacer()
                            Toggle("", isOn: $autoApproveOperate)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .tint(Color.umbraOrange)
                                .onChange(of: autoApproveOperate) { newValue in
                                    NetworkConfig.shared.autoApproveOperate = newValue
                                }
                        }
                        .padding(.vertical, 13)
                    }

                    section(title: L("me.general")) {
                        settingRow(title: L("me.language"), value: languageManager.currentDisplayName) {
                            showingLanguagePicker = true
                        }
                        rowDivider
                        ToggleRow(title: L("me.autoRead"), isOn: $appState.autoReadReplies)
                        rowDivider
                        ToggleRow(title: L("me.darkMode"), isOn: $appState.isDarkMode)
                        rowDivider
                        HStack {
                            Text(L("me.about"))
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
            .navigationTitle(L("me.title"))
            .sheet(isPresented: $showingEditServer) {
                EditServerSheet()
            }
            .sheet(isPresented: $showingEditToken) {
                EditTokenSheet()
            }
            .sheet(isPresented: $showingLanguagePicker) {
                LanguagePickerSheet()
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
                Text(L("me.deviceRegistered"))
                    .font(.system(size: 12))
                    .foregroundColor(.umbraMuted)
            }

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text(L("me.online"))
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
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.umbraMuted)
            }
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(umbraColor(\.border))
            .frame(height: 1)
    }
}

// MARK: - Language Picker Sheet
struct LanguagePickerSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var languageManager: LanguageManager

    var body: some View {
        NavigationStack {
            List {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        languageManager.preference = language
                        dismiss()
                    } label: {
                        HStack {
                            Text(language.nativeDisplayName)
                                .foregroundColor(.primary)
                            Spacer()
                            if languageManager.preference == language {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.umbraOrange)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("me.language"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
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
                Section(L("me.serverUrl")) {
                    TextField("https://...", text: $serverUrl)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(L("me.editServer"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) {
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
                Section(L("me.accessToken")) {
                    SecureField(L("me.enterToken"), text: $token)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(L("me.editToken"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) {
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
