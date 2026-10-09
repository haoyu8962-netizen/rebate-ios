import Foundation

/// 一次 `/v1/config` 拉取的结果（fetcher 回调给 ConfigStore）。
public struct ConfigReply: Sendable, Equatable {
    public static let ok = "ok"
    public static let notModified = "not_modified"
    public static let failure = "failure"

    /// ok / not_modified / failure。
    public let kindRaw: String
    /// ok 时的 data（JSON 对象文本）。
    public let bodyJson: String?
    /// 响应头 ETag（原样，不拆引号或 W/ 前缀）。
    public let etag: String?

    public init(kindRaw: String, bodyJson: String?, etag: String?) {
        self.kindRaw = kindRaw
        self.bodyJson = bodyJson
        self.etag = etag
    }
}

/// 配置存储（03 §4.3）：启动先读 LKG 文件，再后台拉 `/v1/config`；拉取失败继续用 LKG；没有 LKG 用包内默认配置。
///
/// - 冷启动：同步读 LKG 文件（最近一次成功的响应），立即可读；随后发起后台拉取（不带 If-None-Match）。
/// - 回前台：带 If-None-Match（当前配置或 LKG 的 ETag，原样）拉取；304 时内容与来源都不变。
/// - 成功响应：先写 LKG 文件，再成为当前配置（写文件失败时当前配置照常生效，只是下次启动读不到这份 LKG）。
/// - 取值：`value(key:)`、`searchStatus(platform:)` 按「当前 → LKG → 包内」逐项回落；`linkPatterns` 按「当前 → 上一次成功的
///   完整版本 → 包内」。上一次成功的 link_patterns 随 LKG 文件保存（新响应没带链接表时不丢）。
/// - 同一时刻只有一个拉取在途（在途时回前台不再发）。切换环境（`clearForEnvironmentSwitch`）删 LKG 文件、丢掉当前配置，
///   在途拉取的结果到达后丢弃。「清除缓存」不清 LKG（03 §4.3）：LKG 文件放在 Application Support，不在缓存目录。
/// - 可观察：`observe` 登记的回调在快照或来源变化时调用。
///
/// 不是线程安全的：生产代码只在主线程使用（App 的 AppConfig 是 @MainActor，fetcher 回到主线程回调）。
/// TODO(N-21): 无缓存却收到 304、无 ETag 的后续请求、ETag 是否跨进程持久化、并发响应乱序未规定（rule-gaps 第 3 条）：
/// 这里 ETag 随 LKG 保存，回前台只发当前配置或 LKG 的 ETag，304 一律不改内容；同一时刻只有一个在途请求。
public final class ConfigStore {
    public static let sourceCurrent = "current"
    public static let sourceLKG = "lkg"
    public static let sourceBundled = "bundled"

    private let readFile: () throws -> String?
    private let writeFile: (String?) throws -> Void
    private let fetcher: (String?, @escaping (ConfigReply) -> Void) -> Void
    private let clock: () -> Int64
    private let bundled: ConfigDocument?

    private var current: Layer?
    private var lkg: Layer?
    /// 上一次成功的完整 link_patterns（随 LKG 文件保存）。
    private var lastGoodPatterns: [String: Any]?
    /// 在途拉取的编号；没有为 nil。同一时刻只有一个在途拉取。
    private var inFlight: UInt64?
    /// 已发出的拉取的最大编号（单调递增，切换环境不归零）。
    private var sequence: UInt64 = 0
    /// 最近一次被服务端确认的拉取编号（200 取得新配置，或有效的 304 重新确认当前配置）；还没有为 0（APP-06a 共性 10）。
    private var appliedId: UInt64 = 0
    /// `requestFresh` 时有拉取在途：在途的这次结算后再发一次（在途的那次是此刻之前发出的，结果不能当作更新的配置）。
    private var pendingFresh = false
    /// 切换环境时 +1：之前发出的拉取结果丢弃。
    private var generation: UInt64 = 0
    private var observers: [UUID: (ConfigStore) -> Void] = [:]

    private struct Layer {
        let document: ConfigDocument
        let etag: String?
    }

    public init(
        readFile: @escaping () throws -> String?,
        writeFile: @escaping (String?) throws -> Void,
        fetcher: @escaping (String?, @escaping (ConfigReply) -> Void) -> Void,
        clock: @escaping () -> Int64,
        bundled: String
    ) {
        self.readFile = readFile
        self.writeFile = writeFile
        self.fetcher = fetcher
        self.clock = clock
        self.bundled = ConfigDocument.parse(bundled)
    }

    // MARK: - 读

    /// current / lkg / bundled。
    public var sourceRaw: String {
        if current != nil {
            return Self.sourceCurrent
        }
        return lkg != nil ? Self.sourceLKG : Self.sourceBundled
    }

    /// 当前生效的配置 data（JSON 对象文本）。
    public var snapshotJson: String {
        (current?.document ?? lkg?.document ?? bundled)?.json ?? "{}"
    }

    /// 键（"a.b" 路径）按当前 → LKG → 包内回落后的值（JSON 文本）。
    public func value(key: String) -> String? {
        for layer in layers {
            if let value = layer?.value(at: key) {
                return ConfigDocument.encode(value)
            }
        }
        return nil
    }

    /// 某个平台的搜索 Tab 状态（逐个平台回落；见 `ConfigResolver.searchStatus`）。
    public func searchStatus(platform: String) -> String? {
        ConfigResolver.searchStatus(layers: layers, platformKey: platform)
    }

    /// 某个平台的购买状态 `features.platform_status.<platform>`（契约 PlatformPurchaseStatus：on / maintenance /
    /// not_launched；APP-06a R2-01）：与搜索开关同样逐个平台回落（当前 → LKG → 包内），取第一层带该平台字符串取值的。
    /// 三层都没有时为 nil，由调用方决定（TODO(N-27)）。
    public func platformStatus(platform: String) -> String? {
        for layer in layers {
            if let value = layer?.value(at: "features.platform_status") as? [String: Any],
               let status = value[platform] as? String {
                return status
            }
        }
        return nil
    }

    /// link_patterns（当前 → 上一次成功 → 包内）。
    public var linkPatternsJson: String? {
        let previous = lastGoodPatterns.map { ConfigDocument(object: ["link_patterns": $0]) }
        return ConfigResolver.linkPatterns(layers: [current?.document, previous, bundled])
            .flatMap { ConfigDocument.encode($0) }
    }

    private var layers: [ConfigDocument?] {
        [current?.document, lkg?.document, bundled]
    }

    /// 搜索 Tab 用的三层原始取值（APP-06a `SearchTabs.resolve` 的输入）：`current` / `lkg` / `bundled` 各为该层
    /// `features.search_status` 的原样对象（未知取值保留，由 SearchTabs 按 off 处理、不回落）；某层没有该对象时不放。
    public func searchStatusLayers() -> [String: Any] {
        var out: [String: Any] = [:]
        let named: [(String, ConfigDocument?)] = [
            (Self.sourceCurrent, current?.document), (Self.sourceLKG, lkg?.document), (Self.sourceBundled, bundled),
        ]
        for (name, layer) in named {
            if let object = layer?.value(at: "features.search_status") as? [String: Any] {
                out[name] = object
            }
        }
        return out
    }

    /// 最近一次被服务端确认的那份配置（当前配置，没有当前配置时为 LKG）里的 `features.search_status` 原样对象；
    /// 没有为 nil。search_disabled 之后只按它里面「明确为 on」恢复平台（APP-06a 共性 8）。
    public var confirmedSearchStatus: [String: Any]? {
        (current?.document ?? lkg?.document)?.value(at: "features.search_status") as? [String: Any]
    }

    /// 已发出的拉取的最大编号（单调递增）。编号大于它的拉取一定在此刻之后才发出。
    public var issuedFetchId: UInt64 {
        sequence
    }

    /// 最近一次被服务端确认（200 或有效的 304）的拉取编号；还没有为 0。
    public var appliedFetchId: UInt64 {
        appliedId
    }

    // MARK: - 生命周期

    /// 冷启动：同步读 LKG，再发起后台拉取。
    public func onColdStart() {
        loadLKG()
        notify()
        fetch(ifNoneMatch: nil)
    }

    /// 回前台：带 ETag 拉取（在途时不再发）。
    public func onForeground() {
        fetch(ifNoneMatch: current?.etag ?? lkg?.etag)
    }

    /// 要一份「此刻之后才发出」的配置（APP-06a 共性 2、8：50304 search_disabled 刷新配置）：没有在途拉取就立即拉取
    /// （带 ETag）；有在途拉取时，它结算（成功或失败）后再发一次。
    public func requestFresh() {
        guard inFlight == nil else {
            pendingFresh = true
            return
        }
        fetch(ifNoneMatch: current?.etag ?? lkg?.etag)
    }

    /// 切换环境：删 LKG 文件，丢掉当前配置与 LKG（回到包内默认），在途拉取的结果丢弃。删除失败抛错（清理器据此阻断）。
    public func clearForEnvironmentSwitch() throws {
        generation &+= 1
        inFlight = nil
        pendingFresh = false
        appliedId = 0
        current = nil
        lkg = nil
        lastGoodPatterns = nil
        notify()
        try writeFile(nil)
    }

    /// 快照或来源变化时回调（主线程）。返回的令牌释放时注销。
    public func observe(_ handler: @escaping (ConfigStore) -> Void) -> ConfigObservation {
        let id = UUID()
        observers[id] = handler
        return ConfigObservation { [weak self] in
            self?.observers[id] = nil
        }
    }

    // MARK: - 内部

    private func loadLKG() {
        guard let text = try? readFile(), let file = LKGFile.decode(text) else {
            lkg = nil
            lastGoodPatterns = nil
            return
        }
        lkg = Layer(document: file.document, etag: file.etag)
        lastGoodPatterns = file.lastGoodPatterns ?? file.document.value(at: "link_patterns")
            .flatMap(ConfigResolver.completePatterns)
    }

    private func fetch(ifNoneMatch: String?) {
        guard inFlight == nil else {
            return
        }
        sequence &+= 1
        let id = sequence
        inFlight = id
        let sent = generation
        fetcher(ifNoneMatch) { [weak self] reply in
            self?.receive(reply, id: id, generation: sent, sentEtag: ifNoneMatch)
        }
    }

    private func receive(_ reply: ConfigReply, id: UInt64, generation sent: UInt64, sentEtag: String?) {
        guard sent == generation, inFlight == id else {
            return
        }
        inFlight = nil
        apply(reply, id: id, sentEtag: sentEtag)
        if pendingFresh {
            pendingFresh = false
            fetch(ifNoneMatch: current?.etag ?? lkg?.etag)
        }
    }

    private func apply(_ reply: ConfigReply, id: UInt64, sentEtag: String?) {
        if reply.kindRaw == ConfigReply.notModified {
            confirm(id, sentEtag: sentEtag)
            return
        }
        guard reply.kindRaw == ConfigReply.ok,
              let document = ConfigDocument.parse(reply.bodyJson)
        else {
            // 失败、内容不是 JSON 对象：内容与来源都不变。
            return
        }
        let patterns = document.value(at: "link_patterns").flatMap(ConfigResolver.completePatterns)
            ?? lastGoodPatterns
        let file = LKGFile(document: document, etag: reply.etag, savedAt: clock(), lastGoodPatterns: patterns)
        // 先写 LKG 文件（下次启动可读），再让新配置生效。写失败不影响本次使用。
        try? writeFile(file.encode())
        lkg = current ?? lkg
        current = Layer(document: document, etag: reply.etag)
        lastGoodPatterns = patterns
        appliedId = id
        notify()
    }

    /// 有效的 304（APP-06a 共性 10）：带 ETag 发出、且本进程有对应的那份配置（当前配置或 LKG）时，服务端重新确认了它：
    /// 记下确认编号并通知订阅者（search_disabled 分界之后的确认据此恢复明确为 on 的平台）；内容、LKG、ETag、来源都不变。
    /// 没带 ETag、或没有可确认的配置时的 304 不改任何东西（TODO(N-21) rule-gaps 第 3 条）。同一时刻只有一个在途拉取、
    /// 切换环境作废在途结果，所以结算时被确认的仍是发出时那一份。
    private func confirm(_ id: UInt64, sentEtag: String?) {
        guard sentEtag != nil, current != nil || lkg != nil else {
            return
        }
        appliedId = id
        notify()
    }

    private func notify() {
        for handler in observers.values {
            handler(self)
        }
    }
}

/// `ConfigStore.observe` 的令牌：释放或 `cancel()` 时注销。
public final class ConfigObservation {
    private var cancelAction: (() -> Void)?

    init(_ cancel: @escaping () -> Void) {
        cancelAction = cancel
    }

    public func cancel() {
        cancelAction?()
        cancelAction = nil
    }

    deinit {
        cancelAction?()
    }
}

/// LKG 文件：最近一次成功的 data、它的 ETag、保存时刻与上一次成功的完整 link_patterns。不含任何凭据（CSB-05、CSB-06）。
struct LKGFile {
    static let version = 1

    let document: ConfigDocument
    let etag: String?
    let savedAt: Int64
    let lastGoodPatterns: [String: Any]?

    func encode() -> String? {
        var object: [String: Any] = ["v": Self.version, "data": document.object, "saved_at": savedAt]
        if let etag {
            object["etag"] = etag
        }
        if let lastGoodPatterns {
            object["link_patterns_last_good"] = lastGoodPatterns
        }
        return ConfigDocument.encode(object)
    }

    static func decode(_ text: String?) -> LKGFile? {
        guard let root = ConfigDocument.parse(text),
              root.object["v"] as? Int == version,
              let data = root.object["data"] as? [String: Any]
        else {
            return nil
        }
        return LKGFile(
            document: ConfigDocument(object: data),
            etag: root.object["etag"] as? String,
            savedAt: (root.object["saved_at"] as? NSNumber)?.int64Value ?? 0,
            lastGoodPatterns: root.object["link_patterns_last_good"].flatMap(ConfigResolver.completePatterns)
        )
    }
}
