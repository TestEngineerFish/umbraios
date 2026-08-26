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
    /// 周期规则（二期）。跟主数据一起拉，但**不参与整页成败** ——
    /// 统计页的周期入口卡缺了顶多不显示，不该把整页打成错误态。
    @Published var recurRules: [MoneyRecurDTO] = []
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
        // 四个请求并发发出去。趋势一次拉 12 个月，近 6 月在统计页里切片。
        async let c = HTTPService.shared.fetchMoneyCats(includeDisabled: true)
        async let e = HTTPService.shared.fetchMoneyEntries(ym: m)
        async let s = HTTPService.shared.fetchMoneyStats(ym: m, trendMonths: 12)
        async let r = HTTPService.shared.fetchMoneyRecur()
        let (rc, re, rs, rr) = await (c, e, s, r)
        guard let rc, let re, let rs else {
            // 静默刷新失败时不动手上的数据 —— 下拉一次失败就把整页打成错误态，
            // 比「保持旧数据 + 什么都不说」更打扰（提醒列表的同一条经验）。
            if !silent || phase != .ready { phase = .error }
            return
        }
        cats = rc
        entries = re.items
        stats = rs
        // 周期规则不在成败守门里：拉挂了保持旧值，入口卡照旧能进列表页重试。
        if let rr { recurRules = rr }
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
            deleted: false,
            // 手动记/改一笔不带附件：nil 在上行时被整个省掉（encodeIfPresent），
            // 服务端不会动这笔已有的附件 —— 附件只走截图记账与附件接口那两条路。
            atts: nil
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

    /// 新增分类（第二批）。成功返回新分类的 slug（调用方常要立刻选中它）。
    func createCat(name: String, direction: String) async -> String? {
        guard let c = await HTTPService.shared.createMoneyCat(name: name, direction: direction)
        else { return nil }
        await reload(silent: true)
        return c.slug
    }

    /// 子类增 / 改名 / 删。都只影响以后记账（历史流水存的是中文字符串，不动）。
    func addSub(cat: String, label: String) async -> Bool {
        guard await HTTPService.shared.addMoneySub(cat: cat, label: label) else { return false }
        await reload(silent: true)
        return true
    }

    func renameSub(cat: String, old: String, new: String) async -> Bool {
        guard await HTTPService.shared.renameMoneySub(cat: cat, old: old, new: new) else { return false }
        await reload(silent: true)
        return true
    }

    func deleteSub(cat: String, label: String) async -> Bool {
        guard await HTTPService.shared.deleteMoneySub(cat: cat, label: label) else { return false }
        await reload(silent: true)
        return true
    }

    /// 摘一张附件（原图摘不掉，服务端也会拒）。
    func deleteAtt(entryId: String, fileId: String) async -> Bool {
        guard await HTTPService.shared.deleteMoneyAtt(entryId: entryId, fileId: fileId)
        else { return false }
        await reload(silent: true)
        return true
    }

    // MARK: 周期记账（二期）

    /// 单独刷新规则列表（进 money.recur 页时）。整页成败不看它。
    func reloadRecur() async {
        if let rr = await HTTPService.shared.fetchMoneyRecur() { recurRules = rr }
    }

    /// 建/改一条规则。改动**只影响以后的**（服务端重算下一次，已生成流水不动）。
    func saveRecur(id: String?, body: [String: Any]) async -> Bool {
        let rid = id ?? UUID().uuidString.lowercased()
        guard await HTTPService.shared.putMoneyRecur(id: rid, body: body) != nil else { return false }
        await reloadRecur()
        return true
    }

    /// 停止 / 重新开始。恢复不补停用期间的账（服务端语义，稿的开关文案就是这么说的）。
    func pauseRecur(id: String, paused: Bool) async -> Bool {
        guard await HTTPService.shared.pauseMoneyRecur(id: id, paused: paused) else { return false }
        await reloadRecur()
        return true
    }

    /// 删规则不删已生成的流水（稿：那些是真花过的钱）。
    func deleteRecur(id: String) async -> Bool {
        guard await HTTPService.shared.deleteMoneyRecur(id: id) else { return false }
        await reloadRecur()
        return true
    }

    /// 流水行上的「周期」徽章要跳的规则。规则可能已删（删规则不删流水）——
    /// 返回 nil 时调用方给一句人话，别装作能跳。
    func recurRule(_ id: String) -> MoneyRecurDTO? {
        recurRules.first { $0.id == id }
    }
}
