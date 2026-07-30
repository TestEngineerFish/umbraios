# iOS 密码填充（AutoFill Credential Provider）接入步骤

代码已经写好了：`AutoFillExtension/CredentialProviderViewController.swift`。
剩下的是**建 target 与签名**这一步——这一步必须在 Xcode 里做，原因写在最后。

预计 10 分钟，其中 5 分钟在等 Apple 的证书页面。

---

## 1. 在 Xcode 里建 target

1. 打开 `UmbraiOS.xcodeproj`
2. 菜单 **File → New → Target…**
3. 选 **iOS → Application Extension → AutoFill Credential Provider Extension**，点 Next
4. 填：
   - **Product Name**：`AutoFillExtension`
   - **Team**：和主 App 同一个（`7M4S44CE7D`）
   - **Language**：Swift
   - **Embed in Application**：`UmbraiOS`
5. 点 Finish。弹「Activate scheme?」时选 **Cancel**（保持在主 App 的 scheme 上）

向导会自动生成 `AutoFillExtension/` 目录、`Info.plist`、`MainInterface.storyboard`
和一个 `CredentialProviderViewController.swift`，并且把 Bundle ID 设成
`xyz.tingyusha.umbra.ios.AutoFillExtension`、把「Embed App Extensions」阶段加进主 App。
**这些都不用改。**

## 2. 换掉生成的控制器

用仓库里的 `AutoFillExtension/CredentialProviderViewController.swift`
**整个覆盖**向导生成的同名文件。类名一样（`CredentialProviderViewController`），
所以 storyboard 不用动。

## 3. 勾上要共享的三个文件

在 Xcode 里分别选中下面三个文件，右侧 **File Inspector → Target Membership**，
把 `AutoFillExtension` 也勾上（主 App 那个保持勾着）：

| 文件 | 为什么要 |
| --- | --- |
| `UmbraiOS/Views/VaultFeature.swift` | 加密内核 + 数据模型 + `VaultStore` |
| `UmbraiOS/Network/NetworkConfig.swift` | 服务端地址与访问 Token |
| `UmbraiOS/DesignSystem/UmbraTokens.swift` | 颜色 / 字号 / 间距 |

**只勾这三个。** 扩展的内存上限很紧（约 120 MB），能少带就少带。
别把整个设计系统或 `ChatViewModel` 之类的勾进去。

## 4. 在手机上打开

装好之后：**设置 → 通用 → 自动填充与密码 → 打开「Umbra」**。
之后在别的 App 或 Safari 的密码框上，键盘上方就会出现 Umbra 的填充入口。

---

## 已知取舍（不是 bug）

**第一次用要在填充面板里再输一次 Secret Key。**
扩展和主 App 的默认 Keychain 访问组不一样，读不到主 App 存的那份。输一次之后
存进扩展自己的 Keychain，以后只要主密码。

要做成共享得给两个 target 都加同一个 Keychain Sharing 组——那会让主 App
**已经存好的** Secret Key 读不到，用户反而要重输一次。所以这一版不做。

**每次填充都要输主密码。**
主密码不保存、不上传，这条规则在扩展里同样成立。设计稿画的是「Face ID 通过即可」，
那需要把主密码存起来，和上面那条规则冲突。想要那个体验的话，得先接受
「主密码存在 Keychain 里、用生物识别保护」——这是个产品决定，不是技术问题。

**没有做 Credential Identity Store。**
`ASCredentialIdentityStore` 能让系统在键盘上方直接列出匹配的账号（不用先点
「用 Umbra 填充」）。它要求把**账号名和网址**（不含密码）注册给系统，
等于把一部分元数据交给系统索引。要不要做是个隐私取舍，等你定。

---

## 为什么这一步不由我代劳

建 target 要往 `project.pbxproj` 里写一整套东西：native target、build phases、
两份 XCBuildConfiguration、embed 阶段、product 引用。我没有 Xcode 可以验证，
写错的话**项目会直接打不开**——那比编译报错严重得多，会挡住所有后续工作。
而 Xcode 的向导两分钟就能正确生成这一套，而且签名那部分本来也要你在
开发者账号里点一下。让工具做它擅长的事更划算。
