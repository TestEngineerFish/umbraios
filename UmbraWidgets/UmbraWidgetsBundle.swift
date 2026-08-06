// UmbraWidgets 扩展入口：两个主屏小组件 + 一个任务 Live Activity（灵动岛 + 锁屏实况）。
//
// ⚠️ 这个文件夹属于 **UmbraWidgets 扩展 target**，不要加进主 App target ——
// 这里有 @main，加错 target 会跟主 App 的入口撞车。建 target 步骤见
// doc/Widget与AutoFill-接入步骤.md。
// 共享代码只有一份：主 App 的 Utils/WidgetShared.swift（要勾双 target），
// 快照模型和 ActivityAttributes 都在那里 —— 三处同源同 tick 的保证。
import WidgetKit
import SwiftUI

@main
struct UmbraWidgetsBundle: WidgetBundle {
    var body: some Widget {
        UmbraTaskWidget()
        UmbraReminderWidget()
        UmbraTaskLiveActivity()
    }
}
