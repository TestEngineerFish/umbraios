import SwiftUI
import CryptoKit
import CommonCrypto
import Security

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
    static func aesEncrypt(key: Data, plaintext: Data) -> String {
        let sealed = try! AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce())
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
enum VaultKeychain {
    static let account = "umbra.vault.secretKey"
    static func save(_ value: String) {
        let data = Data(value.utf8)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func load() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func clear() { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account] as CFDictionary) }
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

    private var auk: Data?
    private var record: VRecord?
    private var snapshot: VSnapshot?
    private var syncRev = 0
    private var vaultKeys: [String: Data] = [:]

    private var base: String { NetworkConfig.shared.serverUrl }
    private var token: String { NetworkConfig.shared.token }

    // 拉取云端记录（未解锁也可拉，用于取 salt/verifier）。失败时给出可区分的原因。
    func pullRecord() async {
        guard !base.isEmpty, let url = URL(string: "\(base)/vault/sync?have_rev=-1") else { error = "未配置服务器地址（在「我的」页填写）"; return }
        if token.isEmpty { error = "未配置访问令牌（在「我的」页填与电脑相同的令牌）"; return }
        var req = URLRequest(url: url); req.setValue(token, forHTTPHeaderField: "X-Umbra-Token")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { error = "访问令牌不正确（请与电脑端一致）"; return }
            if code == 404 { error = "服务器未部署同步接口（请更新并重启服务端）"; return }
            if code != 200 { error = "服务器返回 \(code)"; return }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { error = "服务器响应异常"; return }
            recordExists = (obj["exists"] as? Bool) ?? false
            syncRev = (obj["rev"] as? Int) ?? 0
            if let blobStr = obj["blob"] as? String, let rd = try? JSONDecoder().decode(VRecord.self, from: Data(blobStr.utf8)) {
                record = rd; error = ""
            } else if recordExists { error = "云端数据解析失败（版本不一致？）" }
        } catch let e { error = "连不上服务器：\(e.localizedDescription)" }
    }

    func unlock(password: String, secretKey: String) async {
        loading = true; error = ""
        defer { loading = false }
        if record == nil { await pullRecord() }
        guard let rec = record else {
            if error.isEmpty { error = "云端还没有数据，请先在电脑端「立即同步」一次" } // 否则保留 pullRecord 给出的具体原因（令牌/网络/404）
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

    func lock() { unlocked = false; auk = nil; snapshot = nil; vaultKeys.removeAll(); items = []; types = [] }

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
    func deleteItem(_ id: String) async {
        guard var snap = snapshot, var d = snap.data[curVaultId] else { return }
        if let i = d.items.firstIndex(where: { $0.id == id }) {   // 打墓碑而非移除，让删除跨端传播
            var it = d.items[i]; it.deleted = true; it.blocks = []; it.attachments = []; it.tags = []
            it.updatedAt = Date().timeIntervalSince1970 * 1000; it.revision += 1; d.items[i] = it
        }
        snap.data[curVaultId] = d; snapshot = snap; loadCurrent()
        await push()
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
        guard let payload = try? JSONEncoder().encode(snap) else { return }
        let enc = VaultCrypto.aesEncrypt(key: a, plaintext: payload)
        let recordStr = "{\"v\":1,\"kdf\":\"\(rec.kdf ?? "pbkdf2")\",\"salt\":\"\(rec.salt)\",\"verifier\":\"\(rec.verifier)\",\"enc\":\"\(enc)\"}"
        for attempt in 0..<3 {
            guard let url = URL(string: "\(base)/vault/sync") else { return }
            var req = URLRequest(url: url); req.httpMethod = "PUT"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Umbra-Token") }
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["blob": recordStr, "baseRev": syncRev, "deviceId": NetworkConfig.shared.clientId, "force": attempt == 2])
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if (obj["ok"] as? Bool) == true { syncRev = (obj["rev"] as? Int) ?? syncRev; return }
            if (obj["conflict"] as? Bool) == true { await pullMerge() } else { return }
        }
    }
}

// MARK: 视图
struct VaultRootView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var store = VaultStore()
    var body: some View {
        Group {
            if store.unlocked { VaultListView().environmentObject(store) }
            else { VaultLockView().environmentObject(store) }
        }
        .task { await store.pullRecord() }
    }
}

struct VaultLockView: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var appState: AppState
    @State private var password = ""
    @State private var secretKey = ""
    @State private var pulse = false
    private var c: UmbraColors { UmbraColors(isDark: appState.isDarkMode) }
    var body: some View {
        ZStack {
            c.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                Text("🔐").font(.system(size: 42))
                    .frame(width: 88, height: 88).background(c.orangeSoft).clipShape(RoundedRectangle(cornerRadius: 26))
                    .scaleEffect(pulse ? 1.03 : 1).animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true), value: pulse)
                Text("保险箱已锁定").font(.system(size: 24, weight: .bold)).foregroundColor(c.text).padding(.top, 26)
                Text("输入主密码解锁本地加密数据\n主密码不保存、不上传").font(.system(size: 13.5)).foregroundColor(c.muted).multilineTextAlignment(.center).padding(.top, 9)
                SecureField("主密码", text: $password)
                    .textContentType(.password).multilineTextAlignment(.center)
                    .padding(15).background(c.card).clipShape(RoundedRectangle(cornerRadius: 14)).padding(.top, 28)
                if !store.hasSecretKey {
                    TextField("Secret Key（U1-…）", text: $secretKey)
                        .autocorrectionDisabled().textInputAutocapitalization(.characters).font(.system(.body, design: .monospaced))
                        .padding(15).background(c.card).clipShape(RoundedRectangle(cornerRadius: 14)).padding(.top, 10)
                }
                if !store.error.isEmpty { Text(store.error).font(.system(size: 12.5)).foregroundColor(c.danger).padding(.top, 8) }
                Button { Task { await store.unlock(password: password, secretKey: secretKey) } } label: {
                    Text(store.loading ? "解锁中…" : "解锁").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(15).background(c.orange).clipShape(RoundedRectangle(cornerRadius: 14))
                }.padding(.top, 12).disabled(store.loading)
                Spacer()
                HStack(spacing: 7) { Text("🔒").foregroundColor(c.success); Text("AES-256-GCM 本地加密 · 云端只存密文") }
                    .font(.system(size: 11.5)).foregroundColor(c.muted).padding(.bottom, 30)
            }.padding(.horizontal, 34)
        }
        .onAppear { pulse = true }
    }
}

struct VaultListView: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var appState: AppState
    @State private var search = ""
    @State private var cat = "all"
    @State private var showAdd = false
    private var c: UmbraColors { UmbraColors(isDark: appState.isDarkMode) }

    private var visible: [VItem] {
        store.items.filter { it in
            (cat == "all" || (cat == "fav" ? (it.favorite ?? false) : it.typeId == cat)) &&
            (search.isEmpty || searchText(it).localizedCaseInsensitiveContains(search))
        }
    }
    private func searchText(_ it: VItem) -> String {
        var s = [it.title] + (it.tags ?? [])
        for b in it.blocks { if let l = b.label { s.append(l) }
            if b.type == "account" { s.append(b.data["username"]?.string ?? ""); s.append(b.data["url"]?.string ?? "") }
            if b.type == "text" || b.type == "field" { s.append(b.data["value"]?.string ?? "") } }
        return s.joined(separator: " ")
    }
    private func typeName(_ id: String) -> String { store.types.first { $0.id == id }?.name ?? "未分类" }
    private func typeIcon(_ id: String) -> String { store.types.first { $0.id == id }?.icon ?? "📄" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // 搜索
                    HStack(spacing: 8) { Text("🔍").foregroundColor(c.muted)
                        TextField("搜索名称/账号/网址", text: $search).foregroundColor(c.text) }
                        .padding(9).background(c.chip).clipShape(RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16).padding(.top, 8)
                    // 类型 chips
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("all", "🗂️", "全部", store.items.count)
                            chip("fav", "⭐", "收藏", store.items.filter { $0.favorite ?? false }.count)
                            ForEach(store.types) { t in chip(t.id, t.icon, t.name, store.items.filter { $0.typeId == t.id }.count) }
                        }.padding(.horizontal, 16)
                    }.padding(.top, 10)
                    // 记录
                    VStack(spacing: 0) {
                        if visible.isEmpty {
                            VStack(spacing: 6) { Text("🗒️").font(.system(size: 30)).opacity(0.4); Text("没有匹配的记录").foregroundColor(c.muted) }.padding(44)
                        } else {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { idx, it in
                                NavigationLink { VaultDetailView(itemId: it.id).environmentObject(store) } label: { row(it) }
                                    .buttonStyle(.plain)
                                if idx < visible.count - 1 { Divider().padding(.leading, 62) }
                            }
                        }
                    }.background(c.card).clipShape(RoundedRectangle(cornerRadius: 18)).padding(.horizontal, 16).padding(.top, 10)
                    HStack(spacing: 6) { Text("🔒").foregroundColor(c.success); Text("\(store.items.count) 条记录 · 已 AES-256-GCM 加密") }
                        .font(.system(size: 11.5)).foregroundColor(c.muted).padding(.vertical, 20)
                }
            }
            .background(c.bg.ignoresSafeArea())
            .navigationTitle("保险箱")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu { ForEach(store.vaults) { v in Button("\(v.icon) \(v.name)") { store.switchVault(v.id) } } }
                        label: { Label(store.vaults.first { $0.id == store.curVaultId }?.name ?? "个人保险箱", systemImage: "person.crop.circle").font(.system(size: 13)) }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { Task { await store.syncNow() } } label: { Image(systemName: store.loading ? "arrow.triangle.2.circlepath" : "icloud.and.arrow.up") }
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                    Button { store.lock() } label: { Image(systemName: "lock.fill") }
                }
            }
            .sheet(isPresented: $showAdd) { VaultAddSheet(typeId: cat.hasPrefix("all") || cat == "fav" ? (store.types.first?.id ?? "") : cat).environmentObject(store) }
        }
    }

    private func chip(_ id: String, _ icon: String, _ name: String, _ n: Int) -> some View {
        let on = cat == id
        return HStack(spacing: 5) { Text(icon); Text(name); if n > 0 { Text("\(n)").opacity(0.7) } }
            .font(.system(size: 13, weight: on ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(on ? c.orangeSoft : c.chip).foregroundColor(on ? c.orange : c.text)
            .clipShape(Capsule()).onTapGesture { cat = id }
    }
    private func row(_ it: VItem) -> some View {
        let acc = it.blocks.first { $0.type == "account" }
        return HStack(spacing: 12) {
            Text(it.icon ?? typeIcon(it.typeId)).font(.system(size: 18)).frame(width: 36, height: 36).background(c.orangeSoft).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text(it.title).font(.system(size: 16, weight: .semibold)).foregroundColor(c.text).lineLimit(1)
                Text(acc?.data["username"]?.string ?? typeName(it.typeId)).font(.system(size: 13)).foregroundColor(c.muted).lineLimit(1)
            }
            Spacer()
            if it.favorite ?? false { Text("⭐").foregroundColor(c.orange).font(.system(size: 13)) }
            Image(systemName: "chevron.right").foregroundColor(c.muted).opacity(0.5).font(.system(size: 13))
        }.padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
    }
}

struct VaultDetailView: View {
    let itemId: String
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VItem?
    @State private var editing = false
    @State private var reveal: Set<String> = []
    private var c: UmbraColors { UmbraColors(isDark: appState.isDarkMode) }
    private var item: VItem? { draft ?? store.items.first { $0.id == itemId } }

    var body: some View {
        ScrollView {
            if let it = item {
                VStack(spacing: 0) {
                    Text(it.icon ?? "🔐").font(.system(size: 32)).frame(width: 66, height: 66).background(c.orangeSoft).clipShape(RoundedRectangle(cornerRadius: 18))
                    Text(it.title).font(.system(size: 22, weight: .bold)).foregroundColor(c.text).padding(.top, 12)
                    HStack(spacing: 8) {
                        let t = store.types.first { $0.id == it.typeId }
                        Text("\(t?.icon ?? "📄") \(t?.name ?? "未分类")").font(.system(size: 12)).foregroundColor(c.muted)
                            .padding(.horizontal, 11).padding(.vertical, 4).background(c.chip).clipShape(RoundedRectangle(cornerRadius: 9))
                        Button { Task { await store.toggleFav(it.id) } } label: { Text(it.favorite ?? false ? "⭐" : "☆") }
                            .padding(.horizontal, 10).padding(.vertical, 4).background(c.chip).clipShape(RoundedRectangle(cornerRadius: 9))
                    }.padding(.top, 9)

                    ForEach(Array(it.blocks.enumerated()), id: \.element.id) { idx, b in
                        blockCard(b, idx: idx)
                    }.padding(.top, 8)

                    HStack(spacing: 6) { Text("🔒").foregroundColor(c.success); Text("已 AES-256-GCM 加密 · 密码/密文不进搜索") }
                        .font(.system(size: 11.5)).foregroundColor(c.muted).padding(.vertical, 18)
                    if editing {
                        Button(role: .destructive) { Task { await store.deleteItem(it.id); dismiss() } } label: { Text("🗑 删除记录") }.padding(.bottom, 30)
                    }
                }.padding(.horizontal, 16).padding(.top, 12)
            }
        }
        .background(c.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(editing ? "保存" : "编辑") {
                    if editing { if let d = draft { Task { await store.saveItem(d) } }; draft = nil; editing = false }
                    else { draft = store.items.first { $0.id == itemId }; editing = true }
                }.fontWeight(editing ? .semibold : .regular)
            }
        }
    }

    private func binding(_ blockId: String, _ key: String) -> Binding<String> {
        Binding(get: { draft?.blocks.first { $0.id == blockId }?.data[key]?.string ?? "" },
                set: { nv in guard var d = draft, let bi = d.blocks.firstIndex(where: { $0.id == blockId }) else { return }
                    d.blocks[bi].data[key] = VJSON(.s(nv)); draft = d })
    }

    @ViewBuilder private func blockCard(_ b: VBlock, idx: Int) -> some View {
        let tag = ["account": "账号", "secret": "密文", "text": "文本", "field": "字段", "images": "图片", "files": "文件"][b.type] ?? b.type
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tag).font(.system(size: 11, weight: .semibold)).foregroundColor(c.orange).padding(.horizontal, 9).padding(.vertical, 2).background(c.orangeSoft).clipShape(RoundedRectangle(cornerRadius: 7))
                Text(b.label ?? "").font(.system(size: 13.5)).foregroundColor(c.muted)
                Spacer()
            }.padding(.horizontal, 15).padding(.vertical, 11).overlay(Divider(), alignment: .bottom)
            VStack(alignment: .leading, spacing: 14) {
                switch b.type {
                case "account":
                    field("用户名", b.data["username"]?.string ?? "", blockId: b.id, key: "username", mono: true)
                    passField("密码", b.id, key: "password", value: b.data["password"]?.string ?? "")
                    field("网址", b.data["url"]?.string ?? "", blockId: b.id, key: "url", mono: false)
                    if b.data["otp"]?.bool ?? false { Text("🔐 已启用两步验证 (2FA)").font(.system(size: 12)).foregroundColor(c.success).padding(.horizontal, 10).padding(.vertical, 5).background(c.success.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8)) }
                case "secret": passField(nil, b.id, key: "value", value: b.data["value"]?.string ?? "")
                case "text":
                    if editing { TextField("", text: binding(b.id, "value"), axis: .vertical).lineLimit(3...8).padding(11).background(c.chip).clipShape(RoundedRectangle(cornerRadius: 11)) }
                    else { Text(b.data["value"]?.string ?? "").font(.system(size: 13.5)).foregroundColor(c.text) }
                case "field": field(nil, b.data["value"]?.string ?? "", blockId: b.id, key: "value", mono: true)
                case "images":
                    let atts = b.data["atts"]?.strings ?? []
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 10) { ForEach(atts, id: \.self) { aid in
                        if let d = store.imageData(aid), let ui = UIImage(data: d) { Image(uiImage: ui).resizable().scaledToFill().frame(width: 120, height: 80).clipped().clipShape(RoundedRectangle(cornerRadius: 10)) }
                        else { RoundedRectangle(cornerRadius: 10).fill(c.chip).frame(width: 120, height: 80).overlay(Text("🖼️")) }
                    } } }
                case "files":
                    let atts = b.data["atts"]?.strings ?? []
                    ForEach(atts, id: \.self) { aid in HStack { Text("📄"); Text(store.attName(aid)).font(.system(size: 13)); Spacer() }.padding(10).background(c.chip).clipShape(RoundedRectangle(cornerRadius: 10)) }
                default: EmptyView()
                }
            }.padding(15)
        }.background(c.card).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.bottom, 13)
    }

    @ViewBuilder private func field(_ label: String?, _ value: String, blockId: String, key: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let l = label { Text(l).font(.system(size: 11.5)).foregroundColor(c.muted) }
            if editing { TextField("", text: binding(blockId, key)).font(mono ? .system(.body, design: .monospaced) : .body).padding(11).background(c.chip).clipShape(RoundedRectangle(cornerRadius: 11)) }
            else if !value.isEmpty { HStack { Text(value).font(mono ? .system(size: 15, design: .monospaced) : .system(size: 14.5)).foregroundColor(mono ? c.text : c.orangeText).lineLimit(1); Spacer()
                Button { UIPasteboard.general.string = value } label: { Text("📋") } } }
        }
    }
    @ViewBuilder private func passField(_ label: String?, _ blockId: String, key: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let l = label { Text(l).font(.system(size: 11.5)).foregroundColor(c.muted) }
            if editing {
                HStack { TextField("", text: binding(blockId, key)).font(.system(.body, design: .monospaced))
                    Button { guard var d = draft, let bi = d.blocks.firstIndex(where: { $0.id == blockId }) else { return }; d.blocks[bi].data[key] = VJSON(.s(VaultCrypto.generatePassword())); draft = d } label: { Text("🎲") } }
                    .padding(11).background(c.chip).clipShape(RoundedRectangle(cornerRadius: 11))
            } else {
                HStack { Text(reveal.contains(blockId+key) ? value : String(repeating: "•", count: min(12, max(6, value.count)))).font(.system(size: 15, design: .monospaced))
                    Spacer()
                    Button { if reveal.contains(blockId+key) { reveal.remove(blockId+key) } else { reveal.insert(blockId+key) } } label: { Text(reveal.contains(blockId+key) ? "🙈" : "👁") }
                    Button { UIPasteboard.general.string = value } label: { Text("📋") } }
            }
        }
    }
}

struct VaultAddSheet: View {
    let typeId: String
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var username = ""
    @State private var password = ""
    @State private var url = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("记录") { TextField("名称", text: $title) }
                Section("账号") {
                    TextField("用户名", text: $username).autocorrectionDisabled().textInputAutocapitalization(.never)
                    HStack { SecureField("密码", text: $password); Button("🎲") { password = VaultCrypto.generatePassword() } }
                    TextField("网址", text: $url).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("新记录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    let blk = VBlock(id: "b" + String(UUID().uuidString.prefix(8)), type: "account", label: "登录信息",
                                     data: ["username": VJSON(.s(username)), "password": VJSON(.s(password)), "url": VJSON(.s(url)), "otp": VJSON(.b(false))])
                    let it = VItem(id: "i" + String(UUID().uuidString.prefix(8)), typeId: typeId, title: title.isEmpty ? username : title, icon: "🔐",
                                   favorite: false, tags: [], blocks: [blk], attachments: [], createdAt: 0, updatedAt: 0, revision: 0)
                    Task { await store.saveItem(it); dismiss() }
                }.disabled(title.isEmpty && username.isEmpty) }
            }
        }
    }
}
