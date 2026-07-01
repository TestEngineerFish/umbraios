import Foundation

// MARK: - Abilities ViewModel
@MainActor
class AbilitiesViewModel: ObservableObject {
    @Published var capabilities: [Capability] = []
    @Published var loading: Bool = false

    func loadCapabilities() async {
        loading = true
        let caps = await HTTPService.shared.fetchCapabilities()
        await MainActor.run {
            self.capabilities = caps
            self.loading = false
        }
    }
}
