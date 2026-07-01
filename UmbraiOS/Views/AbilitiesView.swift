import SwiftUI

// MARK: - Abilities View
struct AbilitiesView: View {
    @StateObject private var viewModel = AbilitiesViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if viewModel.loading {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if viewModel.capabilities.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 40))
                                .foregroundColor(.umbraMuted)
                            Text("暂无能力")
                                .font(.system(size: 16))
                                .foregroundColor(.umbraMuted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        ForEach(viewModel.capabilities, id: \.device_id) { cap in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(cap.device_name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.umbraMuted)

                                ForEach(cap.providers, id: \.provider) { provider in
                                    ProviderCard(provider: provider)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)
            }
            .navigationTitle("能力")
            .task {
                await viewModel.loadCapabilities()
            }
        }
    }
}

// MARK: - Provider Card
struct ProviderCard: View {
    let provider: ProviderInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 11) {
                // Icon
                Image(systemName: providerIcon)
                    .font(.system(size: 18))
                    .foregroundColor(provider.available ? .orangeText : .umbraMuted)
                    .frame(width: 34, height: 34)
                    .background(provider.available ? Color.orange.opacity(0.1) : umbraColor(\.chip))
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.display_name)
                        .font(.system(size: 14, weight: .semibold))
                    Text(provider.version.map { "v\($0)" } ?? (provider.available ? "可用" : provider.unavailable_reason))
                        .font(.system(size: 11))
                        .foregroundColor(.umbraMuted)
                }

                Spacer()

                // Status badge
                if provider.available {
                    Text("可用")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.green)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.1))
                        .clipShape(Capsule())
                } else {
                    Text("不可用")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.umbraMuted)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(umbraColor(\.chip))
                        .clipShape(Capsule())
                }
            }

            // Skills
            if !provider.skills.isEmpty {
                LazyFlexWrap(spacing: 6) {
                    ForEach(provider.skills, id: \.name) { skill in
                        Text(skill.name)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.umbraMuted)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(umbraColor(\.chip))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(14)
        .background(umbraColor(\.card))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(provider.available ? umbraColor(\.border) : umbraColor(\.border), lineWidth: 1)
        )
        .opacity(provider.available ? 1 : 0.6)
    }

    private var providerIcon: String {
        switch provider.provider.lowercased() {
        case "claude_code": return "terminal"
        case "ffmpeg": return "film"
        case "system": return "gear"
        case "computer": return "desktopcomputer"
        case "codex": return "cpu"
        default: return "puzzlepiece"
        }
    }
}

// MARK: - Lazy Flex Wrap (simplified)
struct LazyFlexWrap<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}
