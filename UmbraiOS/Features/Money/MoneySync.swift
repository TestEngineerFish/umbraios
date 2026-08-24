// 记账的服务端线格式(DTO) + 金额算式 + 展示工具。**一条界面代码都没有** ——
// 跟 ReminderSync 同一个道理：纯数据单独放，金额解析是最容易出错的一段，
// 单独放便于一眼看完、也便于以后补测试。
//
// 字段名刻意用 snake_case 直接对齐服务端 JSON（拍板 D2：服务端定一份正本，
// 两端照它落表和序列化，省掉一层 CodingKeys，改字段时少一处能漏）。
// direction / src 本来就是英文枚举值直存直取，这里**没有**中英映射层 ——
// 提醒那边的 ReminderWire 是因为界面模型存了中文；记账的本地模型就是 DTO 本身。
import SwiftUI
import UIKit

// MARK: - 线格式（对齐服务端 /money/* 的 JSON）

/// 一个分类。slug 是稳定标识**永不变**（流水里存的是它），name 可改。
struct MoneyCatDTO: Codable, Identifiable, Hashable {
    let slug: String
    let name: String
    let direction: String        // expense / income
    let slot: Int                // 0 = 无色槽（图表里中性灰），1–7 彩色
    let seq: Int
    let enabled: Bool
    let locked: Bool             // other / other_in：兜底分类，不可停用
    var id: String { slug }
}

/// 一笔流水。金额一律**整数分**，展示时才 /100。
struct MoneyEntryDTO: Codable, Identifiable, Hashable {
    let id: String               // 客户端生成（离线要能先记后同步）
    let cents: Int
    let direction: String        // expense / income
    let cat: String              // 分类 slug
    let sub: String              // 二级，中文字符串不是 slug，可空
    let merchant: String         // 商家/备注（拍板 D1：一个字段）
    let at_ms: Int64
    let tz_offset_min: Int
    let ym: String               // 服务端按 at_ms + tz_offset_min 算的本地月
    let src: String              // manual / shot / import / chat / recur
    let rule_id: String
    let batch_id: String
    let order_no: String
    let updated_at_ms: Int64
    let deleted: Bool
}

/// GET /money/entries 的合计（服务端按**整个筛选结果**算，不是按页）。
struct MoneyTotalsDTO: Codable, Hashable {
    let count: Int
    let expense: Int
    let income: Int
}

struct MoneyEntriesDTO: Codable {
    let items: [MoneyEntryDTO]
    let totals: MoneyTotalsDTO
}

/// PUT /money/entries/{id} 的响应。written=false 表示库里那份更新、这次没写进去，
/// 界面要用回传的 entry 对齐（服务端逐条 last-write-wins，同提醒那套）。
struct MoneyPutDTO: Codable {
    let entry: MoneyEntryDTO
    let written: Bool
}

struct MoneyCatStatDTO: Codable, Hashable {
    let cat: String
    let cents: Int
    let count: Int
}

struct MoneyTrendDTO: Codable, Hashable {
    let ym: String
    let cents: Int
}

/// GET /money/stats 的响应。`prev_expense` 为 **nil** 表示「上月没有记录，无法对比」，
/// 跟「上月花了 0」是两回事 —— 界面别画箭头，更别算出个「少 100%」。
struct MoneyStatsDTO: Codable {
    let ym: String
    let expense: Int
    let income: Int
    let balance: Int
    let by_cat: [MoneyCatStatDTO]        // 只含支出，金额降序
    let prev_ym: String
    let prev_expense: Int?
    let trend: [MoneyTrendDTO]           // 老→新，含当月
}

// MARK: - 金额展示

enum MoneyFmt {
    private static let nf: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    /// 整数分 → "¥1,800.00"。全项目金额展示只走这一个口。
    static func yuan(_ cents: Int) -> String {
        "¥" + (nf.string(from: NSNumber(value: Double(cents) / 100.0)) ?? "0.00")
    }

    /// 带方向符号："-¥38.00" / "+¥320.00"。
    static func signed(_ cents: Int, income: Bool) -> String {
        (income ? "+" : "-") + yuan(cents)
    }

    /// 本地时区的 YYYY-MM（月份是本地时间概念，服务端按 tz_offset_min 分桶）。
    static func ymNow() -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", c.year ?? 2026, c.month ?? 1)
    }

    /// "2026-08" → "2026 年 8 月"。
    static func ymLabel(_ ym: String) -> String {
        let y = ym.prefix(4)
        let m = Int(ym.suffix(2)) ?? 0
        return "\(y) 年 \(m) 月"
    }

    /// "2026-08" → "8月"（趋势柱下的短标签）。
    static func monthShort(_ ym: String) -> String {
        "\(Int(ym.suffix(2)) ?? 0)月"
    }

    /// 客户端时区偏移分钟（东八区 = +480），写 tz_offset_min 用。
    static var tzOffsetMin: Int { TimeZone.current.secondsFromGMT() / 60 }
}

// MARK: - 金额算式（记一笔的金额框支持直接敲 258/3）
//
// 手写递归下降，只认 + - * / 和括号。没用 NSExpression：它对畸形输入抛的是
// ObjC 异常，Swift 的 try/catch 接不住，一个没配对的括号能把 App 带崩。
// 规则与 PC 端 money.ts 的 amountToCents 完全一致（两端算出不一样的数才是大事故）：
// 归一化 → 字符白名单 → 求值 → 闸门（>0 且 ≤ ¥9,999,999.99）。
enum MoneyAmount {

    /// 全角数字/符号、中文标点、¥ 前缀、首尾等号 → 标准算式。
    static func normalize(_ input: String) -> String {
        var s = ""
        for ch in input {
            switch ch {
            case "０"..."９":
                let v = ch.unicodeScalars.first!.value - 0xFF10
                s.append(Character(UnicodeScalar(0x30 + v)!))
            case "×", "ｘ", "Ｘ": s.append("*")
            case "÷": s.append("/")
            case "＋": s.append("+")
            case "－", "−", "–", "—": s.append("-")
            case "．": s.append(".")
            case "（": s.append("(")
            case "）": s.append(")")
            case "，", ",", "¥", "￥", "元", " ", "\u{3000}": break   // 千分位、货币符号、空格直接拿掉
            default: s.append(ch)
            }
        }
        while s.hasPrefix("=") { s.removeFirst() }
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    /// 有没有运算符（决定要不要显示「= ¥86.00」的预览行）。
    static func isExpr(_ input: String) -> Bool {
        let s = normalize(input)
        return s.dropFirst().contains(where: { "+-*/".contains($0) }) || "*/".contains(s.first ?? " ")
    }

    /// 算式/数字 → **整数分**。算不出、≤0、超过 ¥9,999,999.99 都回 nil ——
    /// 一笔上千万的「记账」几乎必然是敲错了，静默收下比当场拒绝更害人。
    static func cents(_ input: String) -> Int? {
        let s = normalize(input)
        guard !s.isEmpty, s.contains(where: { $0.isNumber }) else { return nil }
        // 白名单：归一化后只该剩数字和四则符号，出现别的只能是误触或粘贴错了。
        guard s.allSatisfy({ "0123456789+-*/().".contains($0) }) else { return nil }
        var p = Parser(Array(s))
        guard let v = p.expr(), p.atEnd, v.isFinite, v > 0 else { return nil }
        let c = Int((v * 100).rounded())
        guard c > 0, c <= 999_999_999 else { return nil }
        return c
    }

    /// 递归下降四则运算。写成 struct 带下标游标，不用全局状态。
    private struct Parser {
        let chars: [Character]
        var i = 0
        init(_ c: [Character]) { chars = c }
        var atEnd: Bool { i >= chars.count }

        /// expr := term (('+'|'-') term)*
        mutating func expr() -> Double? {
            guard var v = term() else { return nil }
            while i < chars.count, chars[i] == "+" || chars[i] == "-" {
                let op = chars[i]; i += 1
                guard let r = term() else { return nil }
                v = op == "+" ? v + r : v - r
            }
            return v
        }

        /// term := factor (('*'|'/') factor)*
        mutating func term() -> Double? {
            guard var v = factor() else { return nil }
            while i < chars.count, chars[i] == "*" || chars[i] == "/" {
                let op = chars[i]; i += 1
                guard let r = factor() else { return nil }
                if op == "/" {
                    guard r != 0 else { return nil }   // 除零当场算「算不出」，别放 Infinity 过闸
                    v /= r
                } else {
                    v *= r
                }
            }
            return v
        }

        /// factor := number | '(' expr ')'。不支持一元负号 —— 金额必须是正的，
        /// 负数在闸门那里也过不去，提前拒绝还能少一类奇怪算式。
        mutating func factor() -> Double? {
            guard i < chars.count else { return nil }
            if chars[i] == "(" {
                i += 1
                guard let v = expr(), i < chars.count, chars[i] == ")" else { return nil }
                i += 1
                return v
            }
            var num = ""
            var dots = 0
            while i < chars.count, chars[i].isNumber || chars[i] == "." {
                if chars[i] == "." { dots += 1; if dots > 1 { return nil } }
                num.append(chars[i]); i += 1
            }
            return num.isEmpty ? nil : Double(num)
        }
    }
}

// MARK: - 分类图标 / 色槽颜色 / 来源徽章 / 二级预设（客户端资源）

/// 分类的**图标不存服务端**（schema 注释明写：两端的图标是各自的本地资源，
/// 服务端只管 slug / 显示名 / 色槽）。形状取自设计稿的 CATS 表。
///
/// ⚠️ 路径必须是**绝对坐标 M/L/C/Z 方言** —— UmbraSVGPath 只认这四个命令，
/// 稿里的原始路径带圆弧（a）和相对命令（h/v/l），直接抄过来会整套画错
/// （验收第一轮就是这么炸的）。下面的值是用 svgelements 把稿的路径
/// approximate_arcs_with_cubics 之后导出的，改图标请走同样的转换，别手写。
enum MoneyCatArt {
    private static let icons: [String: String] = [
        "housing": "M4,11L12,4L20,11L20,19C20,19.18 19.95,19.35 19.87,19.5C19.78,19.65 19.65,19.78 19.5,19.87C19.35,19.95 19.18,20 19,20L5,20C4.82,20 4.65,19.95 4.5,19.87C4.35,19.78 4.22,19.65 4.13,19.5C4.05,19.35 4,19.18 4,19Z",
        "food": "M6,3L6,11C6,11.63 6.2,12.25 6.57,12.76C6.95,13.28 7.47,13.66 8.07,13.85C8.68,14.05 9.32,14.05 9.93,13.85C10.53,13.66 11.05,13.28 11.43,12.76C11.8,12.25 12,11.63 12,11L12,3M9,11L9,21M16,3C14.5,5 14,7 14,9C14,9.35 14.09,9.7 14.27,10C14.44,10.3 14.7,10.56 15,10.73C15.3,10.91 15.65,11 16,11L17,11L17,3Z",
        "shopping": "M5,8L19,8L17.8,20L6.2,20ZM9,8L9,6C9,5.37 9.2,4.75 9.57,4.24C9.95,3.72 10.47,3.34 11.07,3.15C11.68,2.95 12.32,2.95 12.93,3.15C13.53,3.34 14.05,3.72 14.43,4.24C14.8,4.75 15,5.37 15,6L15,8",
        "transport": "M5,16L5,9L6.6,5.6L17.4,5.6L19,9L19,16M5,16L19,16M7.5,13L7.51,13M16.5,13L16.51,13M7,16L7,18M17,16L17,18",
        "fun": "M4,8L20,8L20,18L4,18ZM9,4L15,4M12,12L12.01,12",
        "daily": "M6,8L18,8L17,20L7,20ZM9,8L9,5L15,5L15,8",
        "medical": "M12,7L12,17M7,12L17,12M5,5L19,5L19,19L5,19Z",
        "study": "M4,6C4,5.65 4.09,5.3 4.27,5C4.44,4.7 4.7,4.44 5,4.27C5.3,4.09 5.65,4 6,4L11,4L11,20L6,20C5.65,20 5.3,19.91 5,19.73C4.7,19.56 4.44,19.3 4.27,19C4.09,18.7 4,18.35 4,18ZM20,6C20,5.65 19.91,5.3 19.73,5C19.56,4.7 19.3,4.44 19,4.27C18.7,4.09 18.35,4 18,4L13,4L13,20L18,20C18.35,20 18.7,19.91 19,19.73C19.3,19.56 19.56,19.3 19.73,19C19.91,18.7 20,18.35 20,18Z",
        "social": "M4,9L20,9L20,20L4,20ZM4,9L6,5L18,5L20,9M12,9L12,20",
        "other": "M6,12L6.01,12M12,12L12.01,12M18,12L18.01,12",
        "salary": "M4,7L20,7L20,17L4,17ZM4,11L20,11M9,14L11,14",
        "bonus": "M12,3L14.5,8.5L20,11L14.5,13.5L12,19L9.5,13.5L4,11L9.5,8.5Z",
        "parttime": "M4,8L20,8L20,19L4,19ZM9,8L9,5L15,5L15,8",
        "invest": "M4,18L9,12L13,15L19,7M4,20L20,20",
        "reimburse": "M6,3L18,3L18,21L15,19L12,21L9,19L6,21ZM9,8L15,8M9,12L15,12",
        "other_in": "M6,12L6.01,12M12,12L12.01,12M18,12L18.01,12",
    ]

    /// 未知 slug 兜底到「其他」的三个点 —— 历史流水可能指向停用/未知的分类，
    /// 那行流水不能因此消失或崩掉。
    static func icon(_ slug: String) -> String {
        icons[slug] ?? icons["other"]!
    }

    /// 色槽 1–7 → 彩色，0 与一切非法值 → 中性灰。
    /// 色值与 PC 端 index.css 的 --c1…--c8 完全一致（浅/深各一套）——
    /// 同一个分类在两端图表里必须是同一个颜色，这是「一套产品」的底线之一。
    static func slotColor(_ slot: Int) -> Color {
        let pair: (light: String, dark: String)
        switch slot {
        case 1: pair = ("2A78D6", "3987E5")
        case 2: pair = ("1BAF7A", "199E70")
        case 3: pair = ("EDA100", "C98500")
        case 4: pair = ("E87BA4", "D55181")
        case 5: pair = ("008300", "3FA93F")
        case 6: pair = ("4A3AA7", "9085E9")
        case 7: pair = ("8A5A44", "B58163")
        default: pair = ("9A9992", "6E675E")   // --c8 中性灰
        }
        // 同 UmbraColor.dynColor 的构造方式（那个是 private，不为一个复用点把它掀开）。
        let l = UIColor(Color(hex: pair.light)), d = UIColor(Color(hex: pair.dark))
        return Color(UIColor { $0.userInterfaceStyle == .dark ? d : l })
    }
}

/// 来源徽章：label + 图标 path。manual 不出徽章（手记是默认态，标出来是噪音）。
/// 路径同样是转换后的 M/L/C/Z 绝对方言（见上面 MoneyCatArt 的说明）。
enum MoneySrc {
    static func badge(_ src: String) -> (label: String, icon: String)? {
        switch src {
        case "shot": return ("截图", "M4,7L20,7L20,19L4,19ZM9,7L10.5,5L13.5,5L15,7M12,16C12.63,16 13.25,15.8 13.76,15.43C14.28,15.05 14.66,14.53 14.85,13.93C15.05,13.32 15.05,12.68 14.85,12.07C14.66,11.47 14.28,10.95 13.76,10.57C13.25,10.2 12.63,10 12,10C11.37,10 10.75,10.2 10.24,10.57C9.72,10.95 9.34,11.47 9.15,12.07C8.95,12.68 8.95,13.32 9.15,13.93C9.34,14.53 9.72,15.05 10.24,15.43C10.75,15.8 11.37,16 12,16")
        case "import": return ("导入", "M12,4L12,15M7,11L12,16L17,11M5,20L19,20")
        case "chat": return ("秘书", "M21,11.5C20.99,12.9 20.64,14.29 19.96,15.52C19.28,16.75 18.31,17.79 17.12,18.54C15.94,19.3 14.58,19.75 13.18,19.84C11.78,19.94 10.38,19.69 9.1,19.1L4,20L5,15.4C4.29,13.89 4.05,12.21 4.3,10.57C4.56,8.92 5.29,7.39 6.41,6.16C7.54,4.94 9,4.07 10.62,3.68C12.23,3.28 13.93,3.38 15.49,3.95C17.06,4.52 18.41,5.54 19.39,6.89C20.37,8.23 20.93,9.84 21,11.5Z")
        case "recur": return ("周期", "M20,11C20.02,9.41 19.56,7.84 18.68,6.51C17.8,5.18 16.55,4.14 15.07,3.53C13.6,2.91 11.98,2.76 10.42,3.07C8.85,3.39 7.42,4.16 6.3,5.3L3,8M3,4L3,8L7,8M4,13C3.98,14.59 4.44,16.16 5.32,17.49C6.2,18.82 7.45,19.86 8.93,20.47C10.4,21.09 12.02,21.24 13.58,20.93C15.15,20.61 16.58,19.84 17.7,18.7L21,16M21,20L21,16L17,16")
        default: return nil
        }
    }
}

/// 二级分类预设（稿 SUBS 表原样）。二级存的是**中文字符串不是 slug**（服务端 §3.1），
/// 所以这是「输入建议」不是枚举 —— 流水里出现表外的二级也完全合法。
/// 稿里的「新增子类 / 子类改名」需要服务端存这张表，一期服务端没有，先用预设。
enum MoneySubs {
    private static let table: [String: [String]] = [
        "food": ["早餐", "午餐", "晚餐", "外卖", "咖啡奶茶", "请客"],
        "transport": ["打车", "公交地铁", "加油", "停车", "火车高铁", "机票"],
        "shopping": ["服饰", "数码", "家居", "美妆"],
        "housing": ["房租房贷", "水电燃气", "物业", "宽带"],
        "daily": ["生活用品", "母婴", "宠物"],
        "fun": ["订阅会员", "游戏", "观影演出", "旅行"],
        "medical": ["门诊", "药品", "体检", "保险"],
        "study": ["书籍", "课程", "软件工具"],
        "social": ["红包", "礼物", "请客送礼"],
        "salary": ["月薪", "年终"],
        "reimburse": ["差旅", "办公"],
    ]

    static func of(_ slug: String) -> [String] {
        table[slug] ?? []
    }
}
