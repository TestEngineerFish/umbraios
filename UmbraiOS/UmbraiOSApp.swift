import SwiftUI
import AVFoundation

@main
struct UmbraiOSApp: App {
    @StateObject private var appState = AppState.shared
    @ObservedObject private var languageManager = LanguageManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(languageManager)
                .environment(\.locale, languageManager.locale)
                .id(languageManager.localeRevision)
                .preferredColorScheme(appState.isDarkMode ? .dark : .light)
        }
    }
}

// MARK: - App State
@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isDarkMode: Bool {
        didSet { UserDefaults.standard.set(isDarkMode, forKey: "isDarkMode") }
    }

    @Published var autoReadReplies: Bool {
        didSet { UserDefaults.standard.set(autoReadReplies, forKey: "autoReadReplies") }
    }

    private init() {
        self.isDarkMode = UserDefaults.standard.bool(forKey: "isDarkMode")
        self.autoReadReplies = UserDefaults.standard.bool(forKey: "autoReadReplies")
    }
}

// MARK: - Keyboard shortcut support (external keyboard)
struct KeyboardShortcutModifier: ViewModifier {
    let action: (String) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Register for keyboard shortcuts if needed
            }
    }
}
