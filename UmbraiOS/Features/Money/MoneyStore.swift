// 记账的数据源。挂在 UmbraShell 上全局一份 —— 统计 / 流水 / 记一笔 / 分类管理
// 是独立路由，各建各的 store 会各拉各的数据（同 tasks / vault 的理由）。
//
// 一期是**在线优先**：三个请求任何一个挂了整页算 error（分类挂了流水全是 slug
// 裸奔，统计挂了首页是空的，缺一块的页面比整页重试更糊弄人）。
// 稿里「本地已排队，联网后自动重试」说的离线队列一期没有 —— 那需要先拍板
// 整体同步模型（05-记账全量 E15），先不为一个功能单独造一套。
//
// 月份固定当月（拍板 D3：接口从第一天就吃 month，界面一期只做本月）。
import Foundation

@MainActor
final class MoneyStore: ObservableObject {

    enum Phase { case idle, loading, error, ready }

    @Published var phase: Phase = .idle
    @Published var cats: [MoneyCatDTO] = []
    @Published var entries: [MoneyEntryDTO] = []
    @Published var stats: MoneyStatsDTO?
    /// 当前看的月（= 当月）。每次 load 重算 —— 页面跨零点开着不关，第二天要进新的月。
    @Published var ym: String = MoneyFmt.ymNow()

    /// 流水页的筛选。放 store 而不是页面里：统计页点某个分类要**带着筛选**跳过去，
    /// 两个路由页共享状态的最短路径就是它们本来就共享的这个对象。
    @Published var listDir: String = "all"          // all / expense / income
    @Published var listCat: String? = nil           // nil = 全部分类

    // MARK: 拉取

    /// 首次进页面用：没拉过才拉，拉过就用手上的（切 Tab 回来不闪 loading）。
    func loadIfNeeded() {
        guard phase == .idle || phase == .error else { return }
        Task { await reload() }
    }

    /// 全量重拉。silent = 下拉刷新 / 写操作后的静默刷新，不把页面打回骨架。
    func reload(silent: Bool = false) async {
        let m = MoneyFmt.ymNow()
        ym = m
        if !silent { phase = .loading }
        // 三个请求并发发出去。趋势一次拉 12 个月，近 6 月在统计页里切片。
        async let c = HTTPService.shared.fetchMoneyCats(includeDisabled: true)
        async let e = HTTPService.shared.fetchMoneyEntries(ym: m)
        async let s = HTTPService.shared.fetchMoneyStats(ym: m, trendMonths: 12)
        let (rc, re, rs) = await (c, e, s)
        guard let rc, let re, let rs else {
            // 静默刷新失败时不动手上的数据 —— 下拉一次失败就把整页打成错误态，
            // 比「保持旧数据 + 什么都不说」更打扰（提醒列表的同一条经验）。
            if !silent || phase != .ready { phase = .error }
            return
        }
        cats = rc
        entries = re.items
        stats = rs
        phase = .ready
    }

    // MARK: 查询（slug → 展示属性）

    /// 分类接口含停用的（分类管理页要能开回来）；选择器另走 enabledCats。
    func enabledCats(_ direction: String) -> [MoneyCatDTO] {
        cats.filter { $0.direction == direction && $0.enabled }
    }

    /// 历史流水可能指向停用/未知分类（停用不影响历史数据），
    /// 查不到时名字回退成 slug 本身，别让那行流水消失。
    func catName(_ slug: String) -> String {
        cats.first { $0.slug == slug }?.name ?? slug
    }

    func catSlot(_ slug: String) -> Int {
        cats.first { $0.slug == slug }?.slot ?? 0
    }

    /// 「最近用过」：本月流水里同方向、按时间新→旧去重后的前三个分类。
    /// 最近用过（批次 003 定稿）：按方向从流水新→旧去重取 3 个；该方向还没记过
    /// 就用分类表前几个兜底；**该方向分类总数 ≤ 3 时返回空** —— 那时「最近用过」
    /// 和下面的分类网格完全重复（收入侧默认只有工资、报销等寥寥几个），
    /// 调用方按空数组整行不显示。
    func recentCats(_ direction: String) -> [String] {
        let cats = enabledCats(direction)
        guard cats.count > 3 else { return [] }
        var out: [String] = []
        let valid = Set(cats.map { $0.slug })
        for e in entries where e.direction == direction {
            guard valid.contains(e.cat), !out.contains(e.cat) else { continue }
            out.append(e.cat)
            if out.count >= 3 { break }
        }
        for c in cats where out.count < 3 {
            if !out.contains(c.slug) { out.append(c.slug) }
        }
        return out
    }

    // MARK: 写操作（都走服务端，成功后静默重拉对齐）

    /// 记一笔 / 改一笔。id 为 nil 时新建（客户端生成 uuid）。成功回 true。
    func save(id: String?, cents: Int, direction: String, cat: String, sub: String,
              merchant: String, atMs: Int64, src: String?,
              ruleId: String, batchId: String, orderNo: String) async -> Bool {
        let dto = MoneyEntryDTO(
            id: id ?? UUID().uuidString.lowercased(),
            cents: cents,
            direction: direction,
            cat: cat,
            sub: sub,
            merchant: merchant,
            at_ms: atMs,
            tz_offset_min: MoneyFmt.tzOffsetMin,
            ym: "",                       // 服务端按 at_ms + tz_offset_min 自己算，这里占位
            src: src ?? "manual",
            rule_id: ruleId,
            batch_id: batchId,
            order_no: orderNo,
            updated_at_ms: Date.umbraNowMs,
            deleted: false
        )
        guard await HTTPService.shared.putMoneyEntry(dto) != nil else { return false }
        await reload(silent: true)
        return true
    }

    /// 删一笔 = 移进回收站（30 天内可在 我 → 回收站 恢复）。成功回 true。
    func delete(id: String) async -> Bool {
        guard await HTTPService.shared.deleteMoneyEntries([id]) else { return false }
        await reload(silent: true)
        return true
    }

    /// 改分类（改名 / 停用启用）。slug 不可改 —— 它是流水指过来的稳定标识。
    func updateCat(slug: String, name: String? = nil, enabled: Bool? = nil) async -> Bool {
        guard await HTTPService.shared.updateMoneyCat(slug: slug, name: name, enabled: enabled) != nil
        else { return false }
        await reload(silent: true)
        return true
    }
}
