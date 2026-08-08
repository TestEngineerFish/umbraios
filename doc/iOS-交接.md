# iOS 端交接文档

最后更新：2026-08-06

**这一份就是 iOS 端的全部交接内容。** 换协作会话 / 换人接手，读这一份即可；
后续有变更也只更新这一份，不要再拆新文档。

---

## 一、当前状态：v2 全部完成，已实机跑通

- **架构**：min iOS 17；系统 TabView + 每 Tab 独立 NavigationStack（path 存 `Router.paths`，
  再点当前 Tab 回根）；弹窗 / 选择器 / toast / 左滑 / 滚轮全用系统件；一期自绘导航层已删净。
- **五个 Tab + 保险箱**全部按 v2 设计稿重排完成。其中：
  - 常用语：List 左滑编辑/删除 + 独立编辑页；
  - 提醒详情重设计：滑动完成（`UmbraSlideToComplete`，82% 吸附 + 420ms 停顿）、
    稍后提醒用 `Menu(primaryAction:)`（点=10 分钟，长按换时间）。
- **系统集成全部上线**：灵动岛 / 锁屏 Live Activity、小号任务 + 中号提醒（4 行）小组件、
  `umbra://` 深链、AutoFill 密码填充扩展（含 Face ID 解锁、分类筛选）。

---

## 二、协作契约（每轮都按这个来）

1. 先把要改的文件同步进工作副本再改；跨端拷贝有缓存，**用之前先 md5 核对**。
2. **改完必须跑检查器**：`./doc/tools/check-all.sh`（仓库任意位置执行都行，自动找齐全部 .swift）。
   ⚠️ 单独跑某个脚本时**必须带全量文件参数** —— 不带参数是空跑，会假装通过（踩过）。
3. 回写到仓库后**两端 md5 校验**，确认写对了地方。
4. 给 commit message：**一个仓库只给一条**、短（标题 + 几条要点）、可直接复制，不写成报告。
5. **协作方绝对不许执行 `git add` / `commit` / `push`** —— 由我自己在终端提交。
   只读查看用 `git --no-optional-locks`（否则会留下 index.lock）。
6. 代码风格：每个方法 / 类上方中文注释写**为什么**；服务端给不出的数据整块不画（不编假 UI）；
   有历史包袱大胆删、不做兼容；一次只给一条终端命令。

---

## 三、工程结构要点

- `UmbraiOS.xcodeproj` 是 **objectVersion 70 同步文件夹**：源码目录下增删 `.swift`
  **不用改 pbxproj**（三个 target 都一样）。
- pbxproj / Info.plist 的改动用脚本直接改，别手写整份文件。
- 三个 target：`UmbraiOS`（主 App）、`UmbraWidgetsExtension`、`AutoFillExtension`。
- 源码位置：主 App `UmbraiOS/`、Widget `UmbraWidgets/`、AutoFill `AutoFillExtension/`（后两个在仓库根）。
- 静态检查脚本：`doc/tools/`（README 里写了各查什么、白名单怎么加）。

### 共享文件的 Target Membership

| 文件 | 勾给哪些 target |
| --- | --- |
| `UmbraiOS/Utils/WidgetShared.swift` | 主 App + Widget |
| `UmbraiOS/Features/Vault/VaultCore.swift` | 主 App + AutoFill |
| `UmbraiOS/Features/Vault/VaultSharing.swift` | 主 App + AutoFill |
| `UmbraiOS/Features/Vault/VaultBiometrics.swift` | 主 App + AutoFill |
| `UmbraiOS/Networking/NetworkConfig.swift` | 主 App + AutoFill |
| `UmbraiOS/DesignSystem/UmbraTokens.swift` | 主 App + AutoFill |

### 能力配置（Signing & Capabilities）

| 能力 | 值 | 加在哪 |
| --- | --- | --- |
| App Groups | `group.xyz.tingyusha.umbra.ios` | 主 App + Widget + AutoFill（三个都要） |
| Keychain Sharing | `xyz.tingyusha.umbra.ios.shared` | 主 App + AutoFill |
| AutoFill Credential Provider | — | 主 App + AutoFill（**两个都要**，少一个系统就不收录） |

建 target 的完整步骤见 `doc/Widget与AutoFill-接入步骤.md`。

---

## 四、踩过的坑（别再踩）

**AutoFill 相关**

- **扩展不出现在系统「自动填充与密码」列表**：主犯是**主 App target 也必须加
  AutoFill Credential Provider 能力**（只给扩展加，会出现「pluginkit 已发现扩展、
  但设置不收录，且 ASSettingsHelper 报 AuthorizationError Code=2」）。
  另三个真隐患：Info.plist 要有 `ASCredentialProviderExtensionCapabilities → ProvidesPasswords`
  （iOS 18+ 要求）；扩展设 `ENABLE_DEBUG_DYLIB = NO`；扩展 `MARKETING_VERSION` 与主 App 对齐。
  诊断法宝：Mac 控制台连手机，过滤 `authenticationservices` 看 discovery 日志。
- **建 target 时向导会把仓库里写好的 `CredentialProviderViewController.swift` 覆盖成空模板** ——
  界面出现「Return Example Password」按钮就是这个，重新覆盖回去即可。
- **查带 `.biometryCurrentSet` 保护的 Keychain 条目属性会额外弹一次生物识别** →
  迁移判断一律用标记位（`UmbraKeychainShare.migrated`），不去查条目。
- **单独编进扩展会暴露隐式依赖**：`NetworkConfig` 少了 `import Combine`
  （主 App 里靠别的文件传递性带进来，扩展里就露馅）。
- **扩展里 `UIHostingController` 用 `frame = view.bounds` 会上下留白**
  （面板高度是装载之后才定的）→ 用 Auto Layout 约束贴四边。

**SwiftUI 相关**

- **`LongPressGesture` 序列里 `.first(true)` 是「按下」不是「长按成立」**，
  开录必须写在 `.second`（否则点一下就进语音）。
- **手势直接压在 `TextField` 上会吃掉「点一下弹键盘」** → 用条件透明层（无焦点无内容时才盖）。
- **导航栏标题 / 返回钮的配色是配置时解析的静态值**，改 trait 不会重刷 →
  外观切换时给 TabView 换 `.id` 整棵重建（各 Tab 的栈按 `router.paths` 原地恢复，不丢位置）。
- **`.defaultScrollAnchor(.bottom)` 与 `LazyVStack` 相撞**：首帧按估算行高锚底会滚过头，
  进聊天室看不到历史 → 已回退，改用焦点变化时双向 `scrollToEnd`。
- **iOS 17 List 的键盘 inset 会残留**（页面短一截）→ 列表页加
  `.ignoresSafeArea(.keyboard, edges: .bottom)`（保险箱 / 任务 / 灵感 / 常用语）。
- **检查器全绿 ≠ 能编译**：类型推导类错误只有 Xcode 能发现
  （踩过：三元表达式里 Double 字面量撞 CGFloat，报 `Ambiguous use of operator '-'`）。

---

## 五、数据流与安全边界

- **三处同源同 tick**：任务快照 / 灵动岛实况 / 小组件全出自
  `TasksViewModel.loadJobs → UmbraWidgetBridge.syncTasks`；
  提醒快照在 `ReminderStore` 的 init / persist / reload。不允许各算各的。
- **保险箱记录**只存服务端密文 + 本机密文缓存，明文只在内存里；
  填充时是「扩展 → 系统 → 目标 App 输入框」，系统只做传递，不落盘。
- **写进 Keychain 的只有两样**：Secret Key，以及**仅当开了 Face ID 时**的主密码。
  两条都是 `WhenUnlockedThisDeviceOnly`（不进 iCloud、不进备份）；
  主密码那条还带 `.biometryCurrentSet`（面容一变立刻作废）。
- **没有实现 `ASCredentialIdentityStore`**（它会把账号名 / 网址交给系统索引）——
  这是隐私取舍，待定。

---

## 六、下一步待办

1. `[UmbraWidget]` 调试日志（`WidgetBridge.swift` 里两处 print）—— 确认稳定后摘掉。
2. 灵动岛实测（需要服务端跑一个真任务）；实况**后台**持续更新需服务端支持
   ActivityKit 推送（现在只跟随 App 内轮询，任务页开着才动）。
3. AutoFill 面板体验优化：分类维度、最近使用排序等。
4. 产品改名（候选「以墨 / Yimo」，Umbra 有商标冲突）—— 暂缓。
5. 聊天头像换图（相册 / 拍照 / 恢复默认）、引用回复、删单条消息 —— 等服务端接口。
