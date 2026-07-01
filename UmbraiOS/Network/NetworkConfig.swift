import Foundation
import UIKit

// MARK: - Configuration
@MainActor
class NetworkConfig: ObservableObject {
    static let shared = NetworkConfig()

    private let defaults = UserDefaults.standard
    private let serverKey = "umbra.serverUrl"
    private let tokenKey = "umbra.token"
    private let clientIdKey = "umbra.clientId"
    private let deviceNameKey = "umbra.deviceName"

    var serverUrl: String {
        get {
            defaults.string(forKey: serverKey) ?? "https://umbra.tingyusha.xyz"
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
            defaults.set(normalized, forKey: serverKey)
            objectWillChange.send()
        }
    }

    var token: String {
        get { defaults.string(forKey: tokenKey) ?? "" }
        set { defaults.set(newValue, forKey: tokenKey) }
    }

    var clientId: String {
        if let id = defaults.string(forKey: clientIdKey) { return id }
        let id = "ios-" + UUID().uuidString.prefix(8)
        defaults.set(id, forKey: clientIdKey)
        return id
    }

    var deviceName: String {
        get {
            defaults.string(forKey: deviceNameKey) ?? UIDevice.current.name
        }
        set {
            defaults.set(newValue, forKey: deviceNameKey)
        }
    }

    var wsUrl: String {
        var base = serverUrl
        if base.hasPrefix("https://") {
            base = base.replacingOccurrences(of: "https://", with: "wss://")
        } else if base.hasPrefix("http://") {
            base = base.replacingOccurrences(of: "http://", with: "ws://")
        }
        return base + "/ws/chat"
    }

    var isConnected: Bool {
        !serverUrl.isEmpty
    }
}
