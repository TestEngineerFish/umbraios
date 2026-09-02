// 小组件与轻点背面（稿 widgets）：一整屏**说明页**，不是设置页。
//
// 稿里这屏是主屏样机演示（展示两个小组件长什么样）；App 里没法真的画一块
// 别人的主屏，落地成「长什么样 + 怎么开」的说明 —— 小组件的添加入口和
// 轻点背面的开关都在系统侧，App 只能把路指清楚，一步都不能替用户点。
//
// 「双击背面记一笔」的可用前提是 App 认得 umbra://money/add 这条深链
//（见 Notifications.swift 的 UmbraDeepLink）：轻点背面本身不能直接指到
// 某个 App 的页面，要借快捷指令的「打开 URL」转一手。
import SwiftUI

struct UmbraWidgetsGuideView: View {
    var body: some View {
        UmbraScreen {
            VStack(alignment: .leading, spacing: UmbraMetric.sp6) {
                section(title: "主屏小组件",
                        intro: "跟随任务和提醒的变化刷新，点击直达对应页面。") {
                    item(icon: UmbraIconPath.bell, name: "中号 · 今天的提醒",
                         desc: "今天到点和已过期的提醒。圆圈只作展示，勾选要进 App —— 小组件不做写操作。")
                    UmbraRowDivider()
                    item(icon: UmbraIconPath.task, name: "小号 · 执行中任务",
                         desc: "进度环 + 任务名；没有执行中任务时显示今天完成数。点击直达任务详情。")
                }
                steps(title: "怎么添加",
                      lines: ["长按主屏空白处，点左上角「编辑」→「添加小组件」",
                              "搜「Umbra」，挑中号或小号，拖到想放的位置"])

                // 这一组只有标题 + 说明，没有内容卡（要说的都在下面的步骤里）。
                VStack(alignment: .leading, spacing: 8) {
                    Text("轻点背面记一笔")
                        .font(UmbraFont.sans(12, .w600))
                        .foregroundColor(UmbraColor.faint)
                        .padding(.horizontal, 2)
                    Text("设置好之后，双击手机背面就直接打开记一笔 —— 掏出手机、敲两下、金额已经等着输了。")
                        .font(UmbraFont.sans(13))
                        .foregroundColor(UmbraColor.muted)
                        .lineSpacing(13 * 0.55)
                        .padding(.horizontal, 2)
                }
                steps(title: "怎么设置",
                      lines: ["打开「快捷指令」App，新建一条快捷指令，动作选「打开 URL」，填 umbra://money/add",
                              "打开「设置」→「辅助功能」→「触控」→「轻点背面」",
                              "选「轻点两下」，在列表里勾上刚建的那条快捷指令"])
            }
            .padding(.horizontal, UmbraMetric.pagePadX)
            .padding(.top, UmbraMetric.sp4)
        }
        .navigationTitle("小组件与轻点背面")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 分组：小标题 + 一句定位说明 + 卡片内容。
    private func section(title: String, intro: String,
                         @ViewBuilder body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(UmbraFont.sans(12, .w600))
                .foregroundColor(UmbraColor.faint)
                .padding(.horizontal, 2)
            Text(intro)
                .font(UmbraFont.sans(13))
                .foregroundColor(UmbraColor.muted)
                .lineSpacing(13 * 0.55)
                .padding(.horizontal, 2)
            body()
                .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                    .fill(UmbraColor.card))
        }
    }

    /// 一个小组件的介绍行：图标块 + 名称 + 说明。纯展示，不可点。
    private func item(icon: String, name: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(UmbraColor.chip)
                .frame(width: 32, height: 32)
                .overlay(UmbraIcon(d: icon, size: 16, strokeWidth: 1.9)
                    .foregroundColor(UmbraColor.muted))
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(UmbraFont.sans(15, .w560))
                    .foregroundColor(UmbraColor.text)
                Text(desc)
                    .font(UmbraFont.sans(12.5))
                    .foregroundColor(UmbraColor.faint)
                    .lineSpacing(12.5 * 0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
    }

    /// 操作步骤卡：数字序号 + 一步一行。系统侧的路径没法代点，
    /// 所以照系统菜单的原文写，用户能逐字对上。
    private func steps(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(UmbraFont.sans(12, .w600))
                .foregroundColor(UmbraColor.faint)
                .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(i + 1)")
                            .font(UmbraFont.mono(11.5, .w600))
                            .foregroundColor(UmbraColor.orangeText)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(UmbraColor.orangeSoft))
                        Text(line)
                            .font(UmbraFont.sans(13.5))
                            .foregroundColor(UmbraColor.text)
                            .lineSpacing(13.5 * 0.5)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                .fill(UmbraColor.card))
        }
    }
}
