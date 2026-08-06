# iOS 静态检查脚本（无编译器时的替身）

和 Claude 协作改 iOS 代码时，助手手上**没有 Swift 编译器** —— 拼错一个 token 名、
引用一个还没建的类型、括号少一个，这些错误只能等你在 Xcode 里编译才发现。
这三个脚本就是为了把这类错误挡在交付之前。它们不能替代编译，但能挡掉过去踩过的大多数坑。

## 用法

```bash
./doc/tools/check-all.sh
```

在仓库任意位置执行都行。它会找齐三个 target 下的全部 `.swift`（跳过 `_to_delete/`），
依次跑三个检查器，最后给一行总结。

单独跑某一个（**必须带文件参数**，见下面的注意事项）：

```bash
python3 doc/tools/check.py $(find UmbraiOS UmbraWidgets AutoFillExtension -name '*.swift')
```

## 三个脚本各查什么

| 脚本 | 查什么 | 挡住过的错 |
| --- | --- | --- |
| `check.py` | 括号/引号配平、Swift 关键字误用、代码区混入中文全角标点、token 之外的硬编码颜色 | 少一个 `}`、`case x where` 被误判、页面里写死 `#E8590C` |
| `check2.py` | `UmbraColor.x` / `UmbraMetric.x` / `UmbraFont.x` / `UmbraIconPath.x` 是不是真的在 token 层里有定义 | 拼错 token 名（这类错占改动量的大头） |
| `check3.py` | 代码里出现的 `Umbra*` 类型名是不是真的声明过 | 引用了「以为已经做了」的组件；删组件时漏掉的残留引用 |

## 注意事项（都是踩过的）

1. **不带文件参数 = 空跑**。三个脚本都是 `for f in sys.argv[1:]`，不给文件就什么都不查，
   却照样打印「全部通过」。所以一律用 `check-all.sh`，别手敲。
2. **硬编码颜色白名单**：`UmbraTokens.swift` / `UmbraColors.swift` / `WidgetTheme.swift`
   是定义色值的地方，允许写 hex。新增同类文件要往 `check.py` 的白名单里加。
3. `check2.py` 找 token 定义的顺序：环境变量 `UMBRA_DESIGN_SYSTEM` →
   脚本旁的 `src/DesignSystem` → 逐级向上找 `UmbraiOS/DesignSystem`。
   目录结构大改后如果它报「取不到成员表」，就是这一步没找着。
4. 这些检查**不做类型推导、不查方法签名**。`Ambiguous use of operator '-'`
   这类还是只有编译器能发现 —— 检查器全绿不等于能编译过。
