import SwiftUI
import CryptoKit
import CommonCrypto
import Security
import Combine

// MARK: - 密码保险箱（iOS）
// 零知识端到端加密：与 PC 端同一套派生（PBKDF2-SHA256 600k → HKDF ∥ SecretKey → AUK；AES-256-GCM）。
// iOS 作为同步客户端：解锁时用主密码+Secret Key 派生密钥，从服务器拉取密文快照解密展示；改动后加密回推。

// MARK: 加密内核（务必与 UmbraPC/electron/core/vault/crypto.ts 一致）
enum VaultCrypto {
    static let pbkdf2Iter: UInt32 = 600_000
    private static let b32 = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func pbkdf2(_ password: String, _ salt: Data) -> Data {
        var out = Data(count: 32)
        let pw = Array(password.utf8)
        let saltBytes = [UInt8](salt)
        _ = out.withUnsafeMutableBytes { outPtr in
            saltBytes.withUnsafeBufferPointer { saltPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, pw.count,
                                     saltPtr.baseAddress, saltBytes.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), pbkdf2Iter,
                                     outPtr.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return out
    }

    static func base32Decode(_ s: String) -> Data {
        var bits = 0, value = 0
        var out = [UInt8]()
        for ch in s.uppercased() {
            guard let idx = b32.firstIndex(of: ch) else { continue }
            value = (value << 5) | idx; bits += 5
            if bits >= 8 { out.append(UInt8((value >> (bits - 8)) & 0xff)); bits -= 8 }
        }
        return Data(out)
    }

    static func decodeSecretKey(_ sk: String) -> Data {
        let clean = sk.uppercased().filter { ($0 >= "A" && $0 <= "Z") || ($0 >= "2" && $0 <= "7") }
        let body = clean.hasPrefix("U1") ? String(clean.dropFirst(2)) : clean
        return Data(base32Decode(body).prefix(16))
    }

    static func hkdf(ikm: Data, salt: Data, info: String, len: Int = 32) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                                         salt: salt, info: Data(info.utf8), outputByteCount: len)
        return key.withUnsafeBytes { Data($0) }
    }

    static func deriveAUK(password: String, secretKey: String, salt: Data, kdf: String = "pbkdf2") -> Data {
        let pwKey = pbkdf2(password, salt) // iOS 只支持 pbkdf2；PC 旧 scrypt 会自动迁移到 pbkdf2 后再同步
        let sk = decodeSecretKey(secretKey)
        return hkdf(ikm: pwKey + sk, salt: salt, info: "umbra-vault-auk-v1")
    }

    static func authHash(auk: Data, salt: Data) -> String { hkdf(ikm: auk, salt: salt, info: "umbra-vault-auth-v1").hexString }
    static func verifierOf(_ authHashHex: String) -> String { Data(SHA256.hash(data: authHashHex.hexData)).hexString }

    // AES-256-GCM 字符串块："v1:ivB64:tagB64:ctB64"
    static func aesDecrypt(key: Data, blob: String) -> Data? {
        let parts = blob.split(separator: ":", maxSplits: 3).map(String.init)
        guard parts.count == 4, parts[0] == "v1",
              let iv = Data(base64Encoded: parts[1]), let tag = Data(base64Encoded: parts[2]), let ct = Data(base64Encoded: parts[3]),
              let box = try? AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: iv), ciphertext: ct, tag: tag),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else { return nil }
        return plain
    }
    // 返回 String? 而不是 String。原来是 `try!` —— AES.GCM.seal 在密钥长度不对或数据过大时会抛，
    // 而这里护着的是用户的整个保险箱：真抛了应该是「这次没存上，告诉他」，
    // 不是把整个 App 崩掉（崩之前那次修改也没保存，两头落空）。
    static func aesEncrypt(key: Data, plaintext: Data) -> String? {
        guard let sealed = try? AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce()) else { return nil }
        let iv = sealed.nonce.withUnsafeBytes { Data($0) }
        return "v1:\(iv.base64EncodedString()):\(sealed.tag.base64EncodedString()):\(sealed.ciphertext.base64EncodedString())"
    }

    static func generatePassword(length: Int = 20) -> String {
        let all = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_=+")
        return String((0..<length).map { _ in all[Int.random(in: 0..<all.count)] })
    }
}

extension Data { var hexString: String { map { String(format: "%02x", $0) }.joined() } }
extension String {
    var hexData: Data {
        var d = Data(); var i = startIndex
        while i < endIndex, let j = index(i, offsetBy: 2, limitedBy: endIndex) {
            if let b = UInt8(self[i..<j], radix: 16) { d.append(b) }
            i = j
        }
        return d
    }
}

// MARK: 数据模型（对齐 PC 快照结构）
struct VJSON: Codable { // 任意 JSON 值（控件 data 用）
    enum V { case s(String), n(Double), b(Bool), o([String: VJSON]), a([VJSON]), null }
    var v: V
    init(_ v: V) { self.v = v }
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { v = .null }
        else if let x = try? c.decode(Bool.self) { v = .b(x) }
        else if let x = try? c.decode(Double.self) { v = .n(x) }
        else if let x = try? c.decode(String.self) { v = .s(x) }
        else if let x = try? c.decode([String: VJSON].self) { v = .o(x) }
        else if let x = try? c.decode([VJSON].self) { v = .a(x) }
        else { v = .null }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch v {
        case .s(let x): try c.encode(x); case .n(let x): try c.encode(x); case .b(let x): try c.encode(x)
        case .o(let x): try c.encode(x); case .a(let x): try c.encode(x); case .null: try c.encodeNil()
        }
    }
    var string: String { if case .s(let x) = v { return x }; if case .n(let x) = v { return x == x.rounded() ? String(Int(x)) : String(x) }; return "" }
    var bool: Bool { if case .b(let x) = v { return x }; return false }
    var strings: [String] { if case .a(let arr) = v { return arr.map { $0.string } }; return [] }
}

struct VBlock: Codable, Identifiable { var id: String; var type: String; var label: String?; var data: [String: VJSON] }
struct VType: Codable, Identifiable { var id: String; var name: String; var icon: String; var order: Double }
struct VAtt: Codable, Identifiable { var id: String; var name: String; var mime: String; var size: Double; var addedAt: Double }
struct VItem: Codable, Identifiable {
    var id: String; var typeId: String; var title: String; var icon: String?
    var favorite: Bool?; var tags: [String]?; var blocks: [VBlock]; var attachments: [VAtt]
    var createdAt: Double; var updatedAt: Double; var revision: Double
    var deleted: Bool?   // 删除墓碑：参与同步、界面过滤
}
struct VVaultInfo: Codable, Identifiable { var id: String; var name: String; var owner: String; var icon: String; var order: Double; var keyWrapped: String }
struct VData: Codable { var types: [VType]; var items: [VItem]; var attachments: [String: String] }
struct VSnapshot: Codable { var v: Int; var vaults: [VVaultInfo]; var data: [String: VData] }
struct VRecord: Codable { var v: Int; var kdf: String?; var salt: String; var verifier: String; var enc: String }

// MARK: Keychain（存 Secret Key，免每次输入）
//
// 条目落**共享访问组**（见 VaultSharing.swift），主 App 存一次，填充扩展直接能用 ——
// 否则在填充面板里还要把 Secret Key 再输一遍（用户实测点名）。
// 读取一律不指定访问组：不指定时系统搜遍本 App 能访问的所有组，
// 老版本存在私有组里的条目照样读得到，读到之后顺手搬进共享组。
enum VaultKeychain {
    static let account = "umbra.vault.secretKey"
    static func save(_ value: String) {
        let data = Data(value.utf8)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(UmbraKeychainShare.stamp(add) as CFDictionary, nil)
        UmbraKeychainShare.markMigrated(account)
    }
    static func load() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let value = String(data: d, encoding: .utf8) else { return nil }
        // 老条目搬进共享组（拿得到明文，重存一次就行）。搬没搬过看标记，不查条目属性。
        if !UmbraKeychainShare.migrated(account) { save(value) }
        return value
    }
    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account] as CFDictionary)
        UmbraKeychainShare.clearMigrated(account)
    }
}

// MARK: Store（同步客户端 + 内存明文）
@MainActor
final class VaultStore: ObservableObject {
    @Published var unlocked = false
    @Published var vaults: [VVaultInfo] = []
    @Published var curVaultId: String = ""
    @Published var types: [VType] = []
    @Published var items: [VItem] = []
    @Published var loading = false
    @Published var error: String = ""
    @Published var hasSecretKey = VaultKeychain.load() != nil
    @Published var recordExists = false
    /// 这次用的是本机缓存（拉不到服务端）。界面要如实说出来。
    @Published var offline = false
    /// 有本地改动还没推上去。离线改了东西时置起来，下次同步成功清掉。
    @Published var pendingPush = false
    /// 回收站里有几条。**锁着时也有值**（读的是本机缓存里那个明文数字），
    /// 解锁后每次进出回收站重算。设置页那一行和回收站页的锁定态都用它。
    @Published var trashCount = 0

    private var auk: Data?
    private var record: VRecord?
    private var snapshot: VSnapshot?
    private var syncRev = 0
    private var vaultKeys: [String: Data] = [:]

    private var base: String { NetworkConfig.shared.serverUrl }
    private var token: String { NetworkConfig.shared.token }

    // MARK: 本机缓存（离线可用）
    //
    // 缓存的是**密文** —— 和服务端存的是同一份 blob，没有 AUK 谁也读不懂。
    // 没有它的话，飞机上、地铁里、服务端挂了的时候保险箱就是一块砖：
    // 密码管理器最该顶用的时刻恰恰是网络不通的时刻。
    // 文件用 completeFileProtection：设备锁屏后连这份密文都读不到。
    // trashCount 是**明文**的：锁着时没有 AUK，数不出回收站里有几条，
    // 而界面上要显示「N 项 · 解锁后可查看」。这个数字只在这台设备的本机文件里，
    // **不上传** —— 推送的 body 只有 {blob, baseRev, deviceId, force}，blob 是整份密文。
    // 代价是拿到这台设备文件的人能读到「回收站里有几条」，没有标题、没有类型，就一个数。
    // 可选类型：老缓存文件里没有这个字段，解码时要能容忍。
    private struct VCache: Codable { var blob: String; var rev: Int; var trashCount: Int? }

    private var cacheURL: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("umbra-vault-cache.json")
    }

    private func writeCache(blob: String, rev: Int) {
        guard let url = cacheURL,
              let data = try? JSONEncoder().encode(VCache(blob: blob, rev: rev, trashCount: trashCount)) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private func readCache() -> VCache? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VCache.self, from: data)
    }

    private func clearCache() {
        if let url = cacheURL { try? FileManager.default.removeItem(at: url) }
    }

    // 拉取云端记录（未解锁也可拉，用于取 salt/verifier）。失败时给出可区分的原因。
    /// 网络拉不到时回落到本机缓存 —— 有缓存就当作拉到了，只是标成离线。
    private func fallBackToCache(_ netError: String) {
        guard let c = readCache(),
              let rd = try? JSONDecoder().decode(VRecord.self, from: Data(c.blob.utf8)) else {
            error = netError          // 连缓存都没有，才是真的用不了
            offline = true
            return
        }
        record = rd
        syncRev = c.rev
        trashCount = c.trashCount ?? 0
        recordExists = true
        offline = true
        error = ""                    // 有缓存就能解锁，别拿网络问题挡着用户
    }

    func pullRecord() async {
        guard !base.isEmpty, let url = URL(string: "\(base)/vault/sync?have_rev=-1") else { error = "未配置服务器地址（在「我的」页填写）"; return }
        // 这里**不再**因为 token 为空就直接拒绝。服务端只有在自己配了 ASSIST_TOKEN 时才校验，
        // 客户端提前拦一道的结果是：服务端根本没设 token 的部署，iOS 也永远解不开保险箱，
        // 而且报的是「未配置访问令牌」——用户按提示去填，填什么都没用。
        // 现在照发不误，让服务端的 401 来说话。
        var req = URLRequest(url: url)
        if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Umbra-Token") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                // 区分「没填」和「填错了」——两种情况下一步要做的事不一样。
                error = token.isEmpty
                    ? "服务端要访问令牌，但这台手机上还没填。去「我 › 连接 › 访问 Token」填上服务端的 ASSIST_TOKEN。"
                    : "访问令牌不正确，要和服务端的 ASSIST_TOKEN 一模一样（在「我 › 连接」里改）。"
                return
            }
            if code == 404 { fallBackToCache("服务器未部署同步接口（请更新并重启服务端）"); return }
            if code != 200 { fallBackToCache("服务器返回 \(code)"); return }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { fallBackToCache("服务器响应异常"); return }
            recordExists = (obj["exists"] as? Bool) ?? false
            syncRev = (obj["rev"] as? Int) ?? 0
            if let blobStr = obj["blob"] as? String, let rd = try? JSONDecoder().decode(VRecord.self, from: Data(blobStr.utf8)) {
                record = rd; error = ""; offline = false
                writeCache(blob: blobStr, rev: syncRev)   // 拉到就落一份，下次断网还能开
            } else if recordExists {
                fallBackToCache("云端数据解析失败（版本不一致？）")
            }
        } catch let e {
            // 断网 / 超时 / DNS 挂了 —— 这正是缓存该顶上的时候。
            fallBackToCache("连不上服务器：\(e.localizedDescription)")
        }
    }

    func unlock(password: String, secretKey: String) async {
        loading = true; error = ""
        defer { loading = false }
        if record == nil { await pullRecord() }
        guard let rec = record else {
            // 保留 pullRecord 给出的具体原因（令牌 / 网络 / 404）；都没有才说这句。
            if error.isEmpty { error = "云端还没有数据，请先在电脑端「立即同步」一次" }
            return
        }
        let salt = Data(base64Encoded: rec.salt) ?? Data()
        let sk = secretKey.isEmpty ? (VaultKeychain.load() ?? "") : secretKey
        if sk.isEmpty { error = "首次在本机解锁需输入 Secret Key（电脑端 Emergency Kit）"; return }
        let a = VaultCrypto.deriveAUK(password: password, secretKey: sk, salt: salt, kdf: rec.kdf ?? "pbkdf2")
        if VaultCrypto.verifierOf(VaultCrypto.authHash(auk: a, salt: salt)) != rec.verifier { error = "主密码或 Secret Key 不正确"; return }
        guard let plain = VaultCrypto.aesDecrypt(key: a, blob: rec.enc),
              let snap = try? JSONDecoder().decode(VSnapshot.self, from: plain) else { error = "解密失败"; return }
        auk = a
        VaultKeychain.save(sk); hasSecretKey = true
        applySnapshot(snap)
        unlocked = true
        // 回收站的到期清理借解锁这一刻做（锁着时没有密钥，什么都干不了）。
        // **不 await**：清理是杂务，让它拖慢解锁不值当 ——
        // 因为一次清理没跑成而解不开保险箱，那是本末倒置。
        Task { await self.sweepExpiredTrash() }
    }

    /// 只校验主密码对不对，**不解密、不改状态**。开启 Face ID 时要先验一次主密码，
    /// 用 unlock() 会把整个快照解一遍还会翻状态，副作用太大。
    /// 走的是和 unlock 同一条派生 + verifier 比对，纯本地、不联网。
    func verifyPassword(_ password: String) -> Bool {
        guard let rec = record else { return false }
        guard let sk = VaultKeychain.load(), !sk.isEmpty else { return false }
        let salt = Data(base64Encoded: rec.salt) ?? Data()
        let a = VaultCrypto.deriveAUK(password: password, secretKey: sk, salt: salt, kdf: rec.kdf ?? "pbkdf2")
        return VaultCrypto.verifierOf(VaultCrypto.authHash(auk: a, salt: salt)) == rec.verifier
    }

    private func applySnapshot(_ snap: VSnapshot) {
        snapshot = snap
        vaults = snap.vaults.sorted { $0.order < $1.order }
        vaultKeys.removeAll()
        if let a = auk { for v in snap.vaults { vaultKeys[v.id] = VaultCrypto.aesDecrypt(key: a, blob: v.keyWrapped) } }
        if curVaultId.isEmpty || !vaults.contains(where: { $0.id == curVaultId }) { curVaultId = vaults.first?.id ?? "" }
        loadCurrent()
    }
    private func loadCurrent() {
        let d = snapshot?.data[curVaultId]
        types = (d?.types ?? []).sorted { $0.order < $1.order }
        items = (d?.items ?? []).filter { !($0.deleted ?? false) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func switchVault(_ id: String) { curVaultId = id; loadCurrent() }

    /// 上锁只清内存里的明文与密钥。**缓存不清** —— 它是密文，留着下次离线还能开；
    /// 真要清掉是「忘掉这台设备」那一档的事（forgetLocalData）。
    func lock() { unlocked = false; auk = nil; snapshot = nil; vaultKeys.removeAll(); items = []; types = [] }

    /// 彻底忘掉这台设备上的本地痕迹：密文缓存 + Keychain 里的 Secret Key。
    func forgetLocalData() {
        lock()
        clearCache()
        VaultKeychain.clear()
        hasSecretKey = false
        record = nil
        recordExists = false
        syncRev = 0
        offline = false
        pendingPush = false
        trashCount = 0   // 缓存文件已经删了，这个数字再留着就是在说假话
    }

    func imageData(_ attId: String) -> Data? {
        guard let b64 = snapshot?.data[curVaultId]?.attachments[attId] else { return nil }
        return Data(base64Encoded: b64)
    }
    func attName(_ attId: String) -> String { items.flatMap { $0.attachments }.first { $0.id == attId }?.name ?? "文件" }

    // 保存改动到内存快照并推送。
    func saveItem(_ item: VItem) async {
        guard var snap = snapshot, var d = snap.data[curVaultId] else { return }
        if let i = d.items.firstIndex(where: { $0.id == item.id }) {
            var it = item; it.updatedAt = Date().timeIntervalSince1970 * 1000; it.revision += 1; d.items[i] = it
        } else {
            var it = item; it.createdAt = Date().timeIntervalSince1970 * 1000; it.updatedAt = it.createdAt; it.revision = 1; d.items.append(it)
        }
        snap.data[curVaultId] = d; snapshot = snap; loadCurrent()
        await push()
    }
    // MARK: - 删除的三态（回收站，2026-08-23）
    //
    //   正常        deleted 未置位
    //   在回收站    deleted = true，**内容还在**（blocks / attachments 原封不动）
    //   已彻底删除  deleted = true，内容与标题全擦掉，附件字节也从快照里移除
    //
    // **一个新字段都没加**，用的还是同步协议里早就有的 deleted。这是刻意的：
    // VItem 是普通 Codable 结构体，解码时会丢掉不认识的字段、编码时也不会再吐出来。
    // 只要有一端还是旧版本，新加一个 `trashed` 就会在下一次同步里被抹平 ——
    // 那条已删除的记录会在所有设备上原地复活。复用 deleted 则天然兼容。
    //
    // ⚠️ 这套语义**必须和电脑端一字不差**（UmbraPC/electron/core/vault/trash.ts）。
    // 两端对「这条算不算还能恢复」判得不一样，同步时就会各自当真、互相覆盖。

    /// 回收站保留期。跟电脑端、跟服务端那套（提醒的墓碑）取同一个 30 天。
    static let trashKeepMs: Double = 30 * 24 * 3600 * 1000

    /// 一条记录是不是「在回收站里、还能恢复」。
    ///
    /// 判据是**内容还在不在**，不需要额外的标记位。顺带把两种情况都排除对了：
    /// - 本端彻底删除过的 → 内容空 → 不是
    /// - **旧版本客户端删的**（它会当场清空 blocks/attachments，只留标题）→ 也不是。
    ///   那种记录确实恢复不出任何东西，列进回收站给个「恢复」按钮，
    ///   点完只会得到一条空壳，比根本不显示更糟。
    static func isTrashed(_ it: VItem) -> Bool {
        guard it.deleted == true else { return false }
        return !it.blocks.isEmpty || !it.attachments.isEmpty
    }

    /// 还剩几天。向上取整（删完当天显示 30 而不是 29），过期未清的回 0
    /// —— 界面上「还剩 -3 天」是在把实现细节漏给用户看。
    static func leftDays(deletedAtMs: Double, now: Double = Date().timeIntervalSince1970 * 1000) -> Int {
        let left = deletedAtMs + trashKeepMs - now
        return left <= 0 ? 0 : Int(ceil(left / 86_400_000))
    }

    /// 删除 = **移进回收站**：只置标志、抬 revision，内容与附件一个都不动。
    func deleteItem(_ id: String) async {
        guard var snap = snapshot, var d = snap.data[curVaultId] else { return }
        if let i = d.items.firstIndex(where: { $0.id == id }), d.items[i].deleted != true {
            var it = d.items[i]
            it.deleted = true
            it.updatedAt = Date().timeIntervalSince1970 * 1000   // 同时是「删除时刻」，倒计时按它算
            it.revision += 1
            d.items[i] = it
        }
        snap.data[curVaultId] = d; snapshot = snap; loadCurrent()
        refreshTrashCount()
        await push()
    }

    // MARK: - 回收站

    /// 回收站里的一条（**跨所有身份库**）。from 是类型名，对应稿上「登录 · 3 天前删除」。
    struct TrashRow: Identifiable {
        var id: String { "\(vaultId):\(itemId)" }
        let vaultId: String
        let itemId: String
        let title: String
        let from: String
        let deletedAtMs: Double
        let leftDays: Int
    }

    /// 回收站列表，最近删的在前。只在解锁态有内容（锁着时 snapshot 是 nil）。
    func trashRows() -> [TrashRow] {
        guard let snap = snapshot else { return [] }
        let now = Date().timeIntervalSince1970 * 1000
        var out: [TrashRow] = []
        for (vid, d) in snap.data {
            var typeName: [String: String] = [:]
            for t in d.types { typeName[t.id] = t.name }
            for it in d.items where Self.isTrashed(it) {
                out.append(TrashRow(
                    vaultId: vid, itemId: it.id,
                    title: it.title.isEmpty ? "（无标题）" : it.title,
                    from: typeName[it.typeId] ?? "记录",
                    deletedAtMs: it.updatedAt,
                    leftDays: Self.leftDays(deletedAtMs: it.updatedAt, now: now)))
            }
        }
        return out.sorted { $0.deletedAtMs > $1.deletedAtMs }
    }

    /// 从回收站恢复。
    ///
    /// 抬 revision 是关键：云端那份的 revision 停在「已删除」那一版，
    /// 不抬的话下一次合并会按「revision 高者胜」把删除态又拉回来 ——
    /// 用户看到的是「恢复了，过一会儿又没了」。
    func restoreTrash(vaultId: String, itemId: String) async {
        guard var snap = snapshot, var d = snap.data[vaultId],
              let i = d.items.firstIndex(where: { $0.id == itemId }),
              Self.isTrashed(d.items[i]) else { return }
        var it = d.items[i]
        it.deleted = false
        it.updatedAt = Date().timeIntervalSince1970 * 1000
        it.revision += 1
        d.items[i] = it
        snap.data[vaultId] = d; snapshot = snap; loadCurrent()
        refreshTrashCount()
        await push()
    }

    /// 彻底删除：擦干净内容，但**保留这一行**（墓碑还得跨端传播「这条没了」）。
    ///
    /// 比原来的删除多做两件事：
    /// 1. 擦掉 title —— 原来只清 blocks/attachments/tags，于是「旧公司 VPN」这个标题
    ///    会永远躺在加密快照里跟着同步。内容确实没了，但「你曾经有一个叫它的东西」留下来了。
    /// 2. **把附件字节从 d.attachments 里删掉** —— 原来只清了 it.attachments 这份清单，
    ///    真正的 base64 一直留在快照里，谁也引用不到、却永远跟着每次同步来回传。
    func purgeTrash(vaultId: String, itemId: String) async {
        guard var snap = snapshot, var d = snap.data[vaultId],
              let i = d.items.firstIndex(where: { $0.id == itemId }),
              Self.isTrashed(d.items[i]) else { return }
        purgeInPlace(&d, at: i)
        snap.data[vaultId] = d; snapshot = snap; loadCurrent()
        refreshTrashCount()
        await push()
    }

    /// 到期清理：超过保留期的自动彻底删除。**解锁时跑一次。**
    ///
    /// 为什么挂在解锁上而不是定时器：锁着时没有密钥，连有几条都数不出来，
    /// 定时器醒了也什么都干不了。而保险箱一定是解锁之后才用，
    /// 这个时机既够勤，又保证有活干。
    @discardableResult
    func sweepExpiredTrash() async -> Int {
        guard var snap = snapshot else { return 0 }
        let now = Date().timeIntervalSince1970 * 1000
        var n = 0
        // 不能写成 `for (vid, var d) in ...` —— Swift 3 起 for-in 的模式里就不许用 var 了，
        // 得在循环体里另取一份可变副本。
        for (vid, orig) in snap.data {
            var d = orig
            var changed = false
            for i in d.items.indices where Self.isTrashed(d.items[i]) {
                guard now - d.items[i].updatedAt >= Self.trashKeepMs else { continue }
                purgeInPlace(&d, at: i); changed = true; n += 1
            }
            if changed { snap.data[vid] = d }
        }
        guard n > 0 else { refreshTrashCount(); return 0 }
        snapshot = snap; loadCurrent()
        refreshTrashCount()
        await push()
        return n
    }

    /// 就地擦干净一条（内容 + 标题 + 附件字节），保留墓碑行。
    private func purgeInPlace(_ d: inout VData, at i: Int) {
        var it = d.items[i]
        for a in it.attachments { d.attachments.removeValue(forKey: a.id) }
        it.title = ""; it.icon = nil; it.blocks = []; it.attachments = []; it.tags = []
        it.deleted = true
        it.updatedAt = Date().timeIntervalSince1970 * 1000
        it.revision += 1
        d.items[i] = it
    }

    /// 重算回收站条数并落到本机缓存（锁着时要显示它）。
    private func refreshTrashCount() {
        let n = trashRows().count
        guard n != trashCount else { return }   // 没变就别写盘
        trashCount = n
        if let rec = record, let blob = try? JSONEncoder().encode(rec),
           let s = String(data: blob, encoding: .utf8) {
            writeCache(blob: s, rev: syncRev)
        }
    }
    func toggleFav(_ id: String) async {
        guard let it = items.first(where: { $0.id == id }) else { return }
        var n = it; n.favorite = !(it.favorite ?? false); await saveItem(n)
    }
    func moveItem(_ id: String, to typeId: String) async {
        guard let it = items.first(where: { $0.id == id }) else { return }
        var n = it; n.typeId = typeId; await saveItem(n)
    }

    // 同步：先拉合并，再推。
    func syncNow() async {
        loading = true; defer { loading = false }
        await pullMerge()
        await push()
    }
    private func pullMerge() async {
        guard let a = auk, let cur = snapshot else { return }
        guard let url = URL(string: "\(base)/vault/sync?have_rev=\(syncRev)") else { return }
        var req = URLRequest(url: url); if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Umbra-Token") }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let rev = (obj["rev"] as? Int) ?? 0
        guard rev != syncRev, let blobStr = obj["blob"] as? String,
              let rd = try? JSONDecoder().decode(VRecord.self, from: Data(blobStr.utf8)),
              rd.verifier == record?.verifier,
              let plain = VaultCrypto.aesDecrypt(key: a, blob: rd.enc),
              let remote = try? JSONDecoder().decode(VSnapshot.self, from: plain) else { return }
        var merged = cur
        // 库：按 id 合并
        for rv in remote.vaults where !merged.vaults.contains(where: { $0.id == rv.id }) {
            merged.vaults.append(rv); vaultKeys[rv.id] = VaultCrypto.aesDecrypt(key: a, blob: rv.keyWrapped)
        }
        for (vid, rdata) in remote.data {
            var ld = merged.data[vid] ?? VData(types: [], items: [], attachments: [:])
            for t in rdata.types where !ld.types.contains(where: { $0.id == t.id }) { ld.types.append(t) }
            var byId = Dictionary(uniqueKeysWithValues: ld.items.map { ($0.id, $0) })
            for rit in rdata.items {
                if let c = byId[rit.id] { if rit.revision > c.revision || (rit.revision == c.revision && rit.updatedAt > c.updatedAt) { byId[rit.id] = rit } }
                else { byId[rit.id] = rit }
            }
            ld.items = Array(byId.values)
            for (aid, b) in rdata.attachments where ld.attachments[aid] == nil { ld.attachments[aid] = b }
            merged.data[vid] = ld
        }
        snapshot = merged; record = rd; syncRev = rev; applySnapshot(merged)
    }
    private func push() async {
        guard let a = auk, let snap = snapshot, let rec = record else { return }
        guard let payload = try? JSONEncoder().encode(snap) else { error = "本地数据序列化失败，这次没有同步上去"; return }
        guard let enc = VaultCrypto.aesEncrypt(key: a, plaintext: payload) else {
            error = "加密失败，这次没有同步上去（本地改动还在）"
            return
        }
        let recordStr = "{\"v\":1,\"kdf\":\"\(rec.kdf ?? "pbkdf2")\",\"salt\":\"\(rec.salt)\",\"verifier\":\"\(rec.verifier)\",\"enc\":\"\(enc)\"}"
        // **先落本机缓存再推**。顺序反过来的话，离线时改的东西一关 App 就没了 ——
        // 快照只在内存里，服务端又没收到。
        writeCache(blob: recordStr, rev: syncRev)
        for attempt in 0..<3 {
            guard let url = URL(string: "\(base)/vault/sync") else { return }
            var req = URLRequest(url: url); req.httpMethod = "PUT"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Umbra-Token") }
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["blob": recordStr, "baseRev": syncRev, "deviceId": NetworkConfig.shared.clientId, "force": attempt == 2])
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // 推不上去（多半是断网）：改动已经在本机缓存里了，标一下等下次同步。
                offline = true
                pendingPush = true
                return
            }
            if (obj["ok"] as? Bool) == true {
                syncRev = (obj["rev"] as? Int) ?? syncRev
                writeCache(blob: recordStr, rev: syncRev)
                offline = false
                pendingPush = false
                return
            }
            if (obj["conflict"] as? Bool) == true { await pullMerge() } else { return }
        }
    }
}

// 旧的保险箱界面（VaultRootView / VaultLockView / VaultListView / VaultDetailView /
// VaultAddSheet）已经删掉 —— 第 5 步按设计交接包重建的那套在 UmbraVaultViews.swift 与
// UmbraVaultToolViews.swift 里，两套界面共用同一个 VaultStore，长期并存必然分叉。
// 这个文件从此只管**加密内核、数据模型、Keychain 与同步**，不含任何 View。
