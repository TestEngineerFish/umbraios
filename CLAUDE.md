# UmbraiOS 工程约定

SwiftUI，最低支持 iOS 16，Swift 语言版本 5.0。界面按
`doc/design_handoff_umbra_ios/` 里的设计交接包实现。

## 目录结构

```
UmbraiOS/
├── App/            @main 入口与根视图
├── DesignSystem/   跨功能复用的视觉基元：token、图标、控件、导航栏、浮层
├── Navigation/     自绘导航栈（Router / AppShell）与通知深链
├── Features/       按功能分组，每个功能的 View 和它的 ViewModel 放一起
│   ├── Chat/  Task/  Inspiration/  Reminder/  Me/  Vault/
├── Networking/     HTTP、WebSocket、连接配置
├── Models/         跨功能的数据模型
├── Utils/          语言切换、字符串目录
└── Resources/      Info.plist、Assets.xcassets、.xcstrings
```

新增文件时**先问它属于哪个功能**，属于某个功能就进 `Features/<功能>/`。
只有真的被两个以上功能用到的才进 `DesignSystem/` 或 `Utils/`。
`Utils/` 是垃圾抽屉，往里放东西前先确认没有更合适的去处。

## 命名

**类型名**：只有 `DesignSystem/` 里可复用的视觉基元带 `Umbra` 前缀，业务类型一律不带。

前缀不是为了模仿 Objective-C 时代的做法 —— Swift 有模块级命名空间，本来不需要。
留着是因为**去掉就会和 SwiftUI 撞名**：`UmbraColor`、`UmbraFont`、`UmbraButton`、
`UmbraAlert`、`UmbraShadow`、`UmbraTab` 去掉前缀之后分别会遮住 `SwiftUI.Color`、
`Font`、`Button`、`Alert`、`Shadow`、`Tab`，遮住 `Color` 是全项目连锁崩。
所以这条线画在「会不会撞 SwiftUI」上，不是画在「好不好看」上。

业务类型 —— `VaultStore`、`ChatViewModel`、`PhraseStore`、`ReminderStore`、
`LocateCard` —— **不加前缀**。它们不会跟框架撞名，加了只是噪音。

**文件名**：`DesignSystem/` 里的文件跟着类型带前缀（`UmbraTokens.swift`）；
其它目录下的文件不带（`Features/Vault/VaultViews.swift`，不是 `UmbraVaultViews.swift`）。
目录已经说明了归属，文件名再重复一遍是冗余。

## 注释

每个方法、类、模块级变量、配置项上面都要有中文注释，说明它**为什么这么写**，
不是复述它做了什么。踩过的坑写进注释里 —— 下一个人（包括三个月后的你）
会因为看不到坑而把它重新踩一遍。

## 页面骨架

所有页面（根页、推入页都算）一律用 `UmbraScreen` 当容器 —— 它管四件事：可滚动
内容、底部动作条、页面底色、键盘收起（点空白 + 下拉都能收）。不要自己另起
ScrollView + background 的组合，安全区的坑它都已经踩平了。

三条铁律，每条都是真事故换来的：

1. **推入页天然没有 tab bar，任何页面禁止调 `.toolbar(…, for: .tabBar)`**：
   导航栈挂在 TabView **外面**（AppShell 里 NavigationStack 包着 TabView），
   推入页盖住整个 TabView，布局里根本没有 bar 的安全区。不要把栈搬回
   TabView 里面再靠 toolbar API 藏 bar —— 那个 API 的三种挂法（只挂栈外 /
   内外都挂 / 只挂 destination）在真机上全失败过：首个推入层按「有 bar」布局、
   bar 藏掉后 inset 不回收，二级页底部缺一条 tab bar 高的死带而三级页正常
   （连着三轮验收中招后才改成现在的结构）。
2. **任何页面不许挂 `ToolbarItemGroup(placement: .keyboard)`**：键盘附件条撞上
   隐藏的 tab bar，会把整条导航栈的底部避让 inset 卡死 —— 键盘收了，同栈
   所有页面底部还空着一块键盘高度的黑，kill App 才恢复（统计页、回收站的
   截图实锤）。要给键盘补按钮，把按钮画进页面内容里（参照记一笔的运算符芯片）。
3. **收键盘不自己造轮子**：UmbraScreen 自带「点空白收」和「往下拖收」，页面里
   别再放「完成」按钮、别自己拿 @FocusState 拼收起逻辑（真需要主动收，调
   `UmbraKeyboard.dismiss()`）。

## 工程文件

`UmbraiOS.xcodeproj/project.pbxproj` 已经转成 **Xcode 16 的同步文件夹**
（objectVersion 70，PBXFileSystemSynchronizedRootGroup）：源码目录里的 .swift
自动入编，**新增 / 删除 / 挪目录都不用再碰 pbxproj** —— 原来「一个文件改四处」
的约定随之作废（2026-08-24 记账一期起生效，五个新文件零登记直接入编）。

唯一还要手改的地方：**跨 target 共享的文件**。Widgets / AutoFill 用到主 target
的文件（如 `Utils/WidgetShared.swift`、`DesignSystem/UmbraTokens.swift`）列在
PBXFileSystemSynchronizedBuildFileExceptionSet 里 —— 给扩展 target 新增共享文件时，
要把它加进对应 target 的那个 exception set；只给主 App 用的文件什么都不用做。

## 提交

改完给出一份可直接提交的中文 commit 总结，**一个仓库一条**，覆盖当前所有未提交的
改动；不按功能拆成好几条。由人自己执行 `git add` / `commit` / `push`。
