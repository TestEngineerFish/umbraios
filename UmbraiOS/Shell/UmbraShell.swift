// 应用外壳：把 Router 的栈渲染成页面，挂底部 Tab 栏与三种浮层。
//
// 转场：push 时新页从右滑入、back 时从左滑入（对应设计稿的 umpushA / umbackA，
// 都是 .22s 横向位移 26px）。**没有**缩放和弹跳 —— 规范写的是「无弹跳、无缩放」。
import SwiftUI

struct UmbraShell: View {
    @StateObject private var router = UmbraRouter()

    /// 底栏角标。一期还是设计稿里的种子值；接了真实数据之后这里要换成
    /// 「未读会话数 / 待办提醒数」的真实来源，别把 mock 留在发版里。
    private var badges: [UmbraTab: Int] { [.chat: 2, .reminder: 1] }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // 用 id 让路由变化触发转场；栈深度参与 id，是为了让同一路由的
                // push / pop 也能各自播一次动画。
                UmbraRouteView(route: router.current)
                    .environmentObject(router)
                    .id("\(router.stack.count)-\(String(describing: router.current))")
                    .transition(.asymmetric(
                        insertion: .move(edge: router.goingBack ? .leading : .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if router.current.showsTabBar {
                UmbraTabBar(
                    selection: .constant(router.tab),
                    badges: badges,
                    onSelect: { router.root($0) }
                )
            }
        }
        .background(UmbraColor.bg)
        .umbraOverlays(router)
        .environmentObject(router)
    }
}

// MARK: - 路由分发
//
// 一个 switch 把 route 映射到页面。已建好的页面直接接上；还没建的走
// UmbraPlaceholderPage —— 它是一个**真实承接页**，有返回、有说明，
// 不是弹个 toast 了事（自查清单：「每个『点了会怎样』的入口都有真实承接页」）。
struct UmbraRouteView: View {
    let route: UmbraRoute

    var body: some View {
        switch route {

        // ── Tab 根页（第 3–5 步逐个替换成真实实现）
        case .chatContacts:
            UmbraChatContactsView()
        case .chatThread:
            placeholder("对话", "下指令、问答卡、任务进度卡、按住说话", step: 3)

        case .remList:
            placeholder("提醒", "按日期分组、左滑完成/删除、下拉向服务端补拉", step: 4)
        case .remDetail:
            placeholder("提醒详情", "标题、时间、重复、备注、关联任务", step: 4)
        case .remEdit:
            placeholder("新建提醒", "标题、时间、重复、备注", step: 4)

        case .taskList:
            placeholder("任务", "历史 / 计划两段 + 状态筛选", step: 4)
        case .taskDetail:
            placeholder("任务详情", "进度、步骤时间线、过程截图、产出文件", step: 4)

        case .inspList:
            placeholder("灵感", "标签筛选 + 卡片流", step: 4)
        case .inspDetail:
            placeholder("灵感详情", "原文 / 秘书整理 / 标签 / 发到聊天", step: 4)
        case .inspEdit:
            placeholder("记一条灵感", "正文 + 标签（重复标签要拦住）", step: 4)

        case .meHome:
            placeholder("我", "分组入口：保险箱、常用语、设备与能力…", step: 4)
        case .mePhrases:
            placeholder("常用语", "列表 + 两步新建", step: 4)
        case .meDevices:
            placeholder("设备与能力", "设备行（在线/离线 + 最后在线）", step: 4)
        case .deviceDetail:
            placeholder("设备详情", "只读：系统、版本、能力、授权", step: 4)
        case .meCaps:
            placeholder("能力", "只读 provider / skill 清单", step: 4)
        case .meWorkspace:
            placeholder("工作区", "只读目录 + 复制路径", step: 4)
        case .meProfile:
            placeholder("用户画像", "Markdown 编辑 / 重置为空白模板", step: 4)
        case .setConn:
            placeholder("连接", "服务端地址、访问 Token、保存并重连", step: 4)
        case .setNotify:
            placeholder("通知", "系统权限、分类开关、免打扰时段", step: 4)
        case .setGeneral:
            placeholder("通用", "外观、语言", step: 4)
        case .setAbout:
            placeholder("关于", "版本、协议、日志", step: 4)

        // ── 保险箱子树（第 5 步）
        case .vaultHome:
            placeholder("密码保险箱", "上锁态 / 解锁态、身份库、搜索、安全体检", step: 5)
        case .vaultCreate:
            placeholder("创建保险箱", "设主密码 + 强度校验", step: 5)
        case .vaultKey:
            placeholder("Secret Key 备份", "展示 / 复制 / 存文件", step: 5)
        case .vaultRecover:
            placeholder("用 Secret Key 恢复", "格式错误走错误三段式", step: 5)
        case .vaultRecord:
            placeholder("记录详情", "字段行、两步验证码、附件", step: 5)
        case .vaultEdit:
            placeholder("编辑记录", "控件卡片堆叠 + 添加控件", step: 5)
        case .vaultGen:
            placeholder("密码生成器", "长度滑块、字符集、强度条", step: 5)
        case .vaultCheck:
            placeholder("安全体检", "分数环 + 重复/弱/未开两步验证", step: 5)
        case .vaultGroups:
            placeholder("分组管理", "新建 / 改名 / 删除", step: 5)
        case .vaultProfiles:
            placeholder("身份库管理", "新建 / 改名 / 删除", step: 5)
        case .vaultTrash:
            placeholder("回收站", "恢复 / 彻底删除", step: 5)
        case .vaultImport:
            placeholder("导入结果", "汇总 + 去电脑上处理", step: 5)
        case .vaultSettings:
            placeholder("保险箱设置", "自动锁定、切后台遮盖、Face ID", step: 5)
        case .vaultPwd:
            placeholder("修改主密码", "旧密码 → 新密码 → 重新生成 Secret Key", step: 5)

        // ── 系统形态演示（第 6 步）
        case .lockScreen:
            placeholder("锁屏通知", "深色玻璃卡 + 去确认 / 稍后", step: 6)
        case .vaultAutofill:
            placeholder("系统密码填充面板", "底部半屏、锁定态先 Face ID", step: 6)
        case .vaultMask:
            placeholder("后台遮盖", "页面底 + 52px 橙色字标 U", step: 6)
        }
    }

    private func placeholder(_ title: String, _ what: String, step: Int) -> some View {
        UmbraPlaceholderPage(title: title, what: what, step: step)
    }
}

// MARK: - 未建成页面的承接页
//
// 刻意做成一个**能看懂、能退出**的页面，而不是空白或 toast：
// 骨架阶段最容易留下的坑就是「点进去什么都没有，也退不出来」。
struct UmbraPlaceholderPage: View {
    let title: String
    let what: String
    let step: Int
    @EnvironmentObject private var router: UmbraRouter

    var body: some View {
        UmbraPage(navBar: {
            if router.canGoBack {
                UmbraNavBar(backLabel: "返回", title: title, onBack: { router.back() })
            } else {
                UmbraNavBar(title: title)
            }
        }, content: {
            VStack(alignment: .leading, spacing: UmbraMetric.sp4) {
                UmbraCard {
                    VStack(alignment: .leading, spacing: UmbraMetric.sp2) {
                        UmbraSectionLabel(text: "这一页还没建")
                        Text(what)
                            .font(UmbraFont.body)
                            .foregroundColor(UmbraColor.text)
                            .lineSpacing(UmbraFont.bodyLineSpacing)
                        Text("导航骨架已通，页面内容在第 \(step) 步实现。")
                            .font(UmbraFont.rowSub)
                            .foregroundColor(UmbraColor.muted)
                    }
                }
                .padding(.horizontal, UmbraMetric.pagePadX)

                // 骨架自检：这几个入口用来验证栈、浮层、toast 真的通了。
                UmbraGroupCard {
                    UmbraListRow(title: "试一次底部选择器", showsChevron: true) {
                        router.present(UmbraSheet(
                            title: "选一个", subtitle: "验证多层选择器与返回箭头",
                            items: [
                                UmbraSheetItem(label: "第一项", checked: true, action: {}),
                                UmbraSheetItem(label: "进到下一层", note: "多层", action: {
                                    router.present(UmbraSheet(title: "第二层", items: [
                                        UmbraSheetItem(label: "回上一层试试")
                                    ]))
                                }),
                                UmbraSheetItem(label: "删除这一项", destructive: true, action: {
                                    router.showToast("已删除", undo: {})
                                })
                            ]))
                    }
                    UmbraRowDivider()
                    UmbraListRow(title: "试一次确认弹窗", showsChevron: true) {
                        router.confirm(UmbraAlert(
                            title: "删除这条记录？",
                            body: "删除后进回收站，30 天内还能恢复。",
                            confirmLabel: "删除",
                            confirmDestructive: true,
                            onConfirm: { router.showToast("已移到回收站") }))
                    }
                    UmbraRowDivider()
                    UmbraListRow(title: "试一次 toast", showsChevron: true) {
                        router.showToast("已复制，60 秒后自动清剪贴板")
                    }
                }
                .padding(.horizontal, UmbraMetric.pagePadX)
            }
            .padding(.top, UmbraMetric.sp5)
        })
    }
}
