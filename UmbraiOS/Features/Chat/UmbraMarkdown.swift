// 聊天里的 Markdown 渲染。
//
// 为什么要自己拆块：SwiftUI 的 `AttributedString(markdown:)` **只认行内语法**
//（**粗体**、`代码`、[链接]、*斜体*），块级的标题、列表、代码块一律原样吐出来 ——
// 秘书的回复里恰恰全是「**开发步骤**：」「1. 需求分析」这种，不处理的话满屏都是
// 星号和井号（用户点名）。所以这里做一层很薄的块级拆分，行内仍然交给系统。
//
// 刻意**不引第三方 Markdown 库**：聊天里出现的语法就这么几种，
// 为它拖一个几千行的依赖（还要跟着 SwiftUI 版本升级）不划算。
// 真出现渲染不了的语法，宁可原样显示文本 —— 也比整条消息渲染失败强。
import SwiftUI

// MARK: - 块模型

/// 一段 Markdown 拆出来的块。顺序即渲染顺序。
enum UmbraMarkdownBlock: Identifiable {
    case paragraph(String)
    /// level: 1~6；正文里一般只会出现 1~3。
    case heading(level: Int, text: String)
    /// marker 是行首要画的东西：无序为「•」，有序为「1.」这样的序号。
    case listItem(marker: String, text: String, indent: Int)
    case code(String)
    case quote(String)
    case rule

    var id: String {
        switch self {
        case .paragraph(let t): return "p:\(t.hashValue)"
        case .heading(let l, let t): return "h\(l):\(t.hashValue)"
        case .listItem(let m, let t, let i): return "li:\(i):\(m):\(t.hashValue)"
        case .code(let t): return "code:\(t.hashValue)"
        case .quote(let t): return "q:\(t.hashValue)"
        case .rule: return "hr"
        }
    }
}

// MARK: - 解析

enum UmbraMarkdown {
    /// 把整段文本拆成块。**纯函数**，不碰 UI —— 这样解析规则能单独看、单独改。
    static func parse(_ raw: String) -> [UmbraMarkdownBlock] {
        var out: [UmbraMarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false

        // 攒着的普通行合成一个段落。段内换行保留（秘书经常在一段里手动折行）。
        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            if !text.isEmpty { out.append(.paragraph(text)) }
        }

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // ``` 围栏代码块：进入之后原样收字，直到下一个围栏。
            if trimmed.hasPrefix("```") {
                if inCode {
                    out.append(.code(code.joined(separator: "\n")))
                    code.removeAll()
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode { code.append(line); continue }

            if trimmed.isEmpty { flushParagraph(); continue }

            // 分隔线
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                out.append(.rule)
                continue
            }

            // 标题：# ~ ######
            if let h = heading(trimmed) {
                flushParagraph()
                out.append(h)
                continue
            }

            // 列表项（有序 / 无序）。缩进按行首空格数折算，两格一级。
            if let item = listItem(line) {
                flushParagraph()
                out.append(item)
                continue
            }

            // 引用
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                out.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }

            paragraph.append(line)
        }

        // 收尾：没闭合的围栏也要把攒下的内容吐出来，不能吞掉用户的文字。
        if inCode && !code.isEmpty { out.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        return out
    }

    private static func heading(_ trimmed: String) -> UmbraMarkdownBlock? {
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = String(trimmed.dropFirst(level))
        // 「#标签」不是标题：# 后面必须有空格才算。
        guard rest.hasPrefix(" ") else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> UmbraMarkdownBlock? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }.count
        let indent = min(leading / 2, 3)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
            return .listItem(marker: "•", text: String(trimmed.dropFirst(2)), indent: indent)
        }
        // 有序：「1. 」「12) 」
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty {
            let rest = trimmed.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .listItem(marker: "\(digits).", text: String(rest.dropFirst(2)), indent: indent)
            }
        }
        return nil
    }

    /// 行内语法交给系统。解析不了就原样返回纯文本 ——
    /// 宁可显示带星号的原文，也不能让整条消息变成空白。
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: text, options: options) { return a }
        return AttributedString(text)
    }
}

// MARK: - 视图

/// 聊天气泡里的 Markdown 正文。字号/行高沿用气泡的正文规格，标题只做相对加大。
struct UmbraMarkdownText: View {
    let raw: String
    /// 正文字号。标题在此基础上按层级加大，代码块按此缩一号。
    var size: CGFloat = 15.5

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(UmbraMarkdown.parse(raw)) { block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: UmbraMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let t):
            Text(UmbraMarkdown.inline(t))
                .font(UmbraFont.sans(size, .w400))
                .lineSpacing(size * 0.55)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let level, let t):
            // h1/h2/h3 之后不再加大 —— 聊天气泡里再大就喧宾夺主了。
            Text(UmbraMarkdown.inline(t))
                .font(UmbraFont.sans(size + max(0, CGFloat(4 - level)) * 1.5, .w560))
                .lineSpacing(size * 0.4)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .listItem(let marker, let t, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(UmbraFont.sans(size, .w400))
                    .foregroundColor(UmbraColor.muted)
                    // 定宽：序号长短不一时正文起点仍然对齐（1. 和 10. 不能错位）。
                    .frame(minWidth: 16, alignment: .trailing)
                Text(UmbraMarkdown.inline(t))
                    .font(UmbraFont.sans(size, .w400))
                    .lineSpacing(size * 0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent) * 14)

        case .code(let t):
            Text(t)
                .font(UmbraFont.mono(size - 1.5, .w400))
                .lineSpacing(size * 0.4)
                .textSelection(.enabled)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UmbraColor.chip))

        case .quote(let t):
            HStack(spacing: 8) {
                Rectangle().fill(UmbraColor.border).frame(width: 2)
                Text(UmbraMarkdown.inline(t))
                    .font(UmbraFont.sans(size, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineSpacing(size * 0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Rectangle().fill(UmbraColor.borderSoft).frame(height: UmbraMetric.borderW)
        }
    }
}
