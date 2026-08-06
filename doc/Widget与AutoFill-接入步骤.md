# Widget（灵动岛/锁屏实况/小组件）与 AutoFill · 接入步骤

代码已全部写好并放进仓库，剩下的是**只能在 Xcode 里做**的建 target / 配能力步骤。
按顺序走完即可编译运行。预计 15–20 分钟。

## 已就位的代码（不用再写）

| 位置 | 内容 | 归属 target |
| --- | --- | --- |
| `UmbraiOS/Utils/WidgetShared.swift` | App Group 常量、任务/提醒快照模型、Live Activity 属性 | **主 App + UmbraWidgets 双勾** |
| `UmbraiOS/Utils/WidgetBridge.swift` | 快照写入 + 小组件重载 + Live Activity 启停控制 | 仅主 App |
| `UmbraWidgets/`（4 个文件） | WidgetBundle 入口、任务实况（灵动岛+锁屏）、小号任务、中号提醒 | 仅 UmbraWidgets |
| `AutoFillExtension/CredentialProviderViewController.swift` | 密码填充扩展全套界面与逻辑 | 仅 UmbraAutoFill |
| 主 App 已接好 | 任务轮询/提醒变动自动写快照；`umbra://` 深链进对应页；Info.plist 已加 `NSSupportsLiveActivities` 与 URL scheme | — |

数据口径（三处同源同 tick）：灵动岛、锁屏实况、小组件读的都是主 App 同一份快照 /
同一个 Activity 状态；服务端没给步骤数就不显示百分比，快照超 10 分钟显示「更新于」。

---

## 一、建 UmbraWidgets target

1. Xcode：File → New → Target… → iOS → **Widget Extension**
   - Product Name：`UmbraWidgets`（必须同名，Bundle ID 会生成 `xyz.tingyusha.umbra.ios.UmbraWidgets`）
   - **勾上 "Include Live Activity"**；不勾 Configuration App Intent
   - Activate scheme 弹窗选 Activate
2. 删掉向导生成的整个 `UmbraWidgets` 模板组里的 .swift 文件（Bundle/Widget/LiveActivity 模板），
   保留 target 本身与它的 Info.plist / Assets
3. 把仓库根目录已有的 `UmbraWidgets/` 文件夹拖进项目导航器：
   - 选 **Reference files in place**（Xcode 16 会建同步文件夹）
   - Target Membership 只勾 **UmbraWidgets**
4. 选中 `UmbraiOS/Utils/WidgetShared.swift` → 右侧 File Inspector → Target Membership
   **补勾 UmbraWidgets**（主 App 的勾保持）
5. UmbraWidgets target → General：Minimum Deployments 设 **iOS 17.0**（和主 App 一致）

## 二、配 App Group（两个 target 都要）

1. 主 App target → Signing & Capabilities → + Capability → **App Groups**
   → 新建 `group.xyz.tingyusha.umbra.ios`
2. UmbraWidgets target 同样加 App Groups，**勾同一个组**
3. 这个 ID 必须和 `WidgetShared.swift` 里的 `UmbraShared.appGroup` 一字不差；
   要改 ID 只改那一处常量即可

## 三、验证

- 跑主 App → 打开任务页（轮询会写快照并启动实况）→ 有 running 任务时灵动岛出现
  橙色进度弧 + 百分比，长按展开见任务名/事件/40px 进度环；锁屏见深色实况卡
- 任务完成/失败：实况推一帧绿勾/红叉收尾态，4 秒后消失
- 主屏加小组件：小号「任务」（无任务时显示今天完成数）、中号「提醒 · 今天」
- 点小组件/灵动岛 → 深链直达任务详情 / 任务列表 / 提醒列表
- 已知边界：实况进度目前**跟随 App 内轮询**（任务页开着才会持续动）。
  退后台持续更新要等服务端支持 ActivityKit 推送（push token 上报接口），见「后续」

## 四、建 UmbraAutoFill target

1. File → New → Target… → iOS → **AutoFill Credential Provider Extension**
   - Product Name：`UmbraAutoFill`
2. 用仓库里 `AutoFillExtension/CredentialProviderViewController.swift` 的内容
   **整个覆盖**向导生成的同名文件（类名一致，storyboard 与 Info.plist 不用动）
3. 给该 target 补勾三个主 App 文件（File Inspector → Target Membership）：
   - `UmbraiOS/Features/Vault/VaultCore.swift`
   - `UmbraiOS/Networking/NetworkConfig.swift`
   - `UmbraiOS/DesignSystem/UmbraTokens.swift`
   编译再报缺哪个类型，就把报错指向的那一个文件补勾，不要整包勾（扩展内存上限 ~120MB）
4. Minimum Deployments 同样设 iOS 17.0
5. 真机验证：设置 → 密码 → 密码选项 → 自动填充来源勾选 Umbra；
   到任意登录页点密码框 → 键盘上方出现「Umbra」→ 输主密码（本机第一次还要 Secret Key）→ 选记录填充
6. 设计上的两条硬约束（代码里已如此实现，别“优化”掉）：
   - 扩展每次都要输主密码 —— 主密码不保存不上传，扩展里同样成立
   - 扩展与主 App 不共享 Keychain，第一次用要重输一次 Secret Key（做共享要两边加同一
     Keychain Sharing 组，会让主 App 已存的 Key 失效，这版不做这个取舍）

## 五、后续（这版刻意没做的）

- **实况的后台持续更新**：需要服务端加 ActivityKit 推送（App 上报 push token、任务事件时推 APNs）
- 中号提醒小组件的**交互勾选**（AppIntent 按钮）：小组件不做写操作是本版规范，放开需评审
- 小组件配置（选任务/选分组）：等有第二个真实需求再上 AppIntentConfiguration
