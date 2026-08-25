import Foundation
import UIKit
// ObservableObject / objectWillChange 定义在 Combine 里。主 App target 里靠别的文件
// 传递性带进来了；这个文件还要单独编进 AutoFillExtension，必须自己显式 import。
import Combine

// MARK: - 无缓存会话
//
// 对 Umbra 服务端的所有 REST 请求共用这一个会话，**彻底关掉 URL 缓存**。
// 为什么：服务端的 GET 响应不带 Cache-Control，URLSession 会按「启发式缓存」
// 自作主张存一份再直接回放 —— 实测：在 PC 端把流水从回收站恢复后，iOS 下拉
// 刷新拿到的仍是缓存里的旧列表，kill 掉 App 才能看到真数据。数据接口没有一个
// 是能吃缓存的：宁可每次多一个来回，也不能把旧账当新账。
//
// ⚠️ 定义**必须**放在这个文件里，不能放 HTTPService.swift：VaultCore.swift 也在用它，
// 而 VaultCore 会被单独编进 AutoFillExtension（pbxproj 的 exception set 只共享了
// 五个文件，HTTPService 不在其中）—— 放错文件扩展 target 当场编译失败（真炸过）。
// NetworkConfig.swift 本来就在共享名单里，网络配置和网络会话放一起也名正言顺。
enum APISession {
    static let shared: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()
}

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
