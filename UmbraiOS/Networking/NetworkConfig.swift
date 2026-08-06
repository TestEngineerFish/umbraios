import Foundation
import UIKit
// ObservableObject / objectWillChange 定义在 Combine 里。主 App target 里靠别的文件
// 传递性带进来了；这个文件还要单独编进 AutoFillExtension，必须自己显式 import。
import Combine

// MARK: - Configuration
@MainActor
class NetworkConfig: ObservableObject {
    static let shared = NetworkConfig()

    /// 配置走 App Group 共享域：AutoFill 扩展是独立进程，读不到主 App 的
    /// UserDefaults.standard —— 不共享的话填充面板会说「这台手机上还没填访问令牌」，
    /// 可用户明明在主 App 里填过了（用户实测点名）。没配 App Group 时自动退回私有域。
    private var defaults: UserDefaults { UmbraGroupStore.defaults }
    private let serverKey = "umbra.serverUrl"
    private let tokenKey = "umbra.token"
    private let clientIdKey = "umbra.clientId"
    private let deviceNameKey = "umbra.deviceName"
    private let allowDeviceSendKey = "umbra.allowDeviceSend"
    private let autoApproveOperateKey = "umbra.autoApproveOperate"

    var serverUrl: String {
        get {
            UmbraGroupStore.string(serverKey) ?? "https://umbra.tingyusha.xyz"
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
            defaults.set(normalized, forKey: serverKey)
            objectWillChange.send()
        }
    }

    var token: String {
        get { UmbraGroupStore.string(tokenKey) ?? "" }
        set { defaults.set(newValue, forKey: tokenKey) }
    }

    var clientId: String {
        if let id = UmbraGroupStore.string(clientIdKey) { return id }
        let id = "ios-" + UUID().uuidString.prefix(8)
        defaults.set(id, forKey: clientIdKey)
        return id
    }

    var deviceName: String {
        get {
            UmbraGroupStore.string(deviceNameKey) ?? UIDevice.current.name
        }
        set {
            defaults.set(newValue, forKey: deviceNameKey)
        }
    }

    // 是否允许向设备会话发送消息（默认关，设备会话仅查看）。
    var allowDeviceSend: Bool {
        get { UmbraGroupStore.bool(allowDeviceSendKey) }
        set {
            defaults.set(newValue, forKey: allowDeviceSendKey)
            objectWillChange.send()
        }
    }

    // 是否自动批准电脑操作(operate)授权卡（默认关；开了则确认卡自动批准）。
    var autoApproveOperate: Bool {
        get { UmbraGroupStore.bool(autoApproveOperateKey) }
        set {
            defaults.set(newValue, forKey: autoApproveOperateKey)
            objectWillChange.send()
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
