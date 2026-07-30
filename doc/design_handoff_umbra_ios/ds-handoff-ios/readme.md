# iOS 增补 · 待合入 Umbra 设计系统

来源：本项目的 `Umbra iOS.dc.html` 一期原型 + `设计规范增补-iOS.md`。
这个目录按设计系统项目的结构组织，可以整体拷进去：

| 这里 | 放到设计系统项目的 |
| --- | --- |
| `tokens/ios.css` | `tokens/ios.css`，并在 `styles.css` 末尾加一行 `@import "tokens/ios.css";` |
| `guidelines/ios-*.html` | `guidelines/`（13 张卡，带 `@dsCard` 标记，直接出现在设计系统首页） |

`styles.css` 与 `tokens/*.css`（除 `ios.css`）是从设计系统拷来的副本，只为让这些卡片能单独在浏览器里打开对照——**不要**拷回去覆盖原文件。

每张卡片在引入 `tokens/ios.css` 之后有一行 `document.documentElement.dataset.platform='ios'`，否则 iOS 覆盖层不激活、样例会退回桌面取值。合入设计系统时保留这一行。

## 卡片清单

- `ios-overrides` —— iOS 取值覆盖对照表（正文 15px、卡片圆角 14px、行高 44px 起…）
- 12 个新组件：StatusBarChip、SegmentedControl、SwipeActionRow、QuestionCard、TaskProgressCard、VoiceHoldOverlay、FieldRow、StrengthMeter、TotpRow、ScoreRing、NotificationPreview、MaskScreen

## iOS 特有规则（建议写进 voice / 规范总览）

- 敏感值显示 8 秒后自动重新遮盖；复制后 60 秒清剪贴板，并在反馈文案里写明。
- 破坏性操作不占详情页底部：收进右上菜单 / 长按菜单 / 左滑；实心红只出现在确认弹窗的最终动作。
- 不用下拉刷新表示本地数据；提醒列表的下拉刷新是「向服务端补拉」，语义不同，保留。
- 录音、倒计时、进度这类「看起来在动」的东西必须真的有 tick，不允许只在渲染时算一次。
- 每个演示态、每个承接页都要有出口：返回箭头、关闭、或可再点一次退出的开关。
