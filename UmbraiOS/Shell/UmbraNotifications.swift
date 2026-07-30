// 通知：分类与动作按钮、前台横幅、点通知直接进对应页面。
//
// 之前的提醒通知是「弹一条、点了打开 App 首页」—— 到点看见通知还得自己找回那条提醒。
// 这里把三件缺的事补上：
//   1. 锁屏 / 通知中心上直接有「完成」和「再等 10 分钟」两个动作，不用打开 App；
//   2. App 在前台时也显示横幅（默认是**静默**的，用户会以为提醒没响）；
//   3. 点通知本体 → 直接跳到那条提醒的详情页。
//
// 「去确认」这类任务确认动作要等服务端有推送通道才谈得上（现在确认卡只走 WebSocket，
// App 不在前台就收不到）。所以这一版只给提醒配动作，不摆一个点了没反应的按钮。
import Foundation
import UserNotifications

// MARK: - 深链

/// 从通知（以后还有 URL Scheme）过来的待处理跳转。
/// 单独一个对象而不是塞进 Router：通知回调可能在 Router 还没建好时就到了。
@MainActor
final class UmbraDeepLink: ObservableObject {
    static let shared = UmbraDeepLink()
    /// 外壳消费一次就置回 nil。
    @Published var route: UmbraRoute?
    private init() {}
}

// MARK: - 通知代理

final class UmbraNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UmbraNotificationDelegate()

    /// 提醒类通知的分类标识。排通知时要把它写进 content.categoryIdentifier，
    /// 否则动作按钮不会出现 —— 这是最容易漏的一步。
    static let reminderCategory = "umbra.reminder"
    static let actionDone = "umbra.reminder.done"
    static let actionSnooze = "umbra.reminder.snooze"

    /// 在 App 启动时调一次。**必须在 App 完全启动前设好 delegate**，
    /// 否则「用户点通知冷启动 App」这一条会丢掉（系统只在启动早期投递一次）。
    func bootstrap() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let done = UNNotificationAction(identifier: Self.actionDone, title: "完成", options: [])
        // 不给 .destructive —— 完成一条提醒不是破坏性操作，红色留给真正删东西的地方。
        let snooze = UNNotificationAction(identifier: Self.actionSnooze, title: "再等 10 分钟", options: [])
        let category = UNNotificationCategory(identifier: Self.reminderCategory,
                                              actions: [done, snooze],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
    }

    // App 在前台时也要显示。系统默认是静默的，那样用户会以为提醒压根没响。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        // 提前提醒那条的 id 是「主 id + .ahead」，动作要作用在主提醒上，所以取 userInfo 里的原始 id。
        let reminderId = info["reminderId"] as? String
        let action = response.actionIdentifier

        Task { @MainActor in
            defer { completionHandler() }
            guard let rid = reminderId else { return }
            switch action {
            case Self.actionDone:
                ReminderStore.shared.toggleDone(id: rid)
            case Self.actionSnooze:
                ReminderStore.shared.snooze(id: rid)
            case UNNotificationDefaultActionIdentifier:
                // 点通知本体 = 进这条提醒的详情页。
                UmbraDeepLink.shared.route = .remDetail(id: rid)
            default:
                break   // 「关闭」等系统动作不处理
            }
        }
    }
}
