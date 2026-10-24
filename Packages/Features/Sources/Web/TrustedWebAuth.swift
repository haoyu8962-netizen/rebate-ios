import BridgeHost
import Foundation
import WebKit

/// 可信容器切号清理的五类 Web 数据（F-X-25 B 口径）。各类各自清、各自确认完成，不能相互代清。
public enum TrustedWebDataKind: Hashable, Sendable, CaseIterable {
    case cookies, localStorage, sessionStorage, indexedDB, httpCache
}

/// 可信容器专用的网站数据存储（F-X-25 I6；评审 r2 S0-R2-01 起每次切号换新）：与系统默认 store（`WKWebsiteDataStore.default()`）、
/// 第三方页容器（ExternalWebController 每次新建的 `nonPersistent()`）都不是同一个实例，切号清理只作用于可信 store。
/// - iOS 17 起：按标识的持久化独立存储 `WKWebsiteDataStore(forIdentifier:)`。**每次切号清理事务换一个新标识**，当前标识持久记录在
///   `couli-trusted-web/trusted-web-stores.json`；换下的旧标识记入同一文件的「待删」列表，用 `remove(forIdentifier:)` 删除，删不掉
///   （仍在使用）的留在列表里，下次事务成功后与冷启动时重试；冷启动另外清掉一切非当前标识的残留 store。
/// - iOS 16（最低部署版本，没有按标识的存储）：每次切号新建一个 `nonPersistent()`（各自独立的临时会话），旧实例随最后一个
///   WebView 释放而消失。iOS 16 分支无实跑证据，内测包前补（F-IOS-38，D10-283）。
@MainActor
public enum TrustedWebDataStore {
    /// F-X-25 r1 之前用过的固定标识（只作为残留清理对象）。
    static let legacyIdentifier = UUID(uuidString: "6B1E3C2A-6F0D-4F52-9C1E-5A2D7C9B8E41")

    private static var currentStore: WKWebsiteDataStore?
    private static var coldStartClaimed = false

    /// 本进程第一个生产协调器取得冷启动核对（归属比对、残留 store 清理）；之后的返回 false。
    static func claimColdStart() -> Bool {
        defer { coldStartClaimed = true }
        return !coldStartClaimed
    }

    /// 生产当前的可信 store（首次取用时按持久记录的当前标识打开；没有记录就新建并记下）。
    public static var current: WKWebsiteDataStore {
        if let currentStore {
            return currentStore
        }
        let registry = TrustedWebStoreRegistry(file: TrustedWebStoreRegistry.file(nextTo: pendingFile))
        var record = registry.load()
        let store: WKWebsiteDataStore
        if #available(iOS 17.0, *), let id = record.current {
            store = WKWebsiteDataStore(forIdentifier: id)
        } else {
            store = makeFresh()
            if let legacyIdentifier {
                record.retired.insert(legacyIdentifier)
            }
            record.current = identifier(of: store)
            try? registry.save(record)
        }
        currentStore = store
        return store
    }

    /// 新建一个空的可信 store（iOS 17+ 新标识，iOS 16 新的临时会话）。
    public static func makeFresh() -> WKWebsiteDataStore {
        if #available(iOS 17.0, *) {
            return WKWebsiteDataStore(forIdentifier: UUID())
        }
        return WKWebsiteDataStore.nonPersistent()
    }

    /// 生产协调器换 store 后更新（设置页「清缓存」等取 `current`）。
    static func adopt(_ store: WKWebsiteDataStore) {
        currentStore = store
    }

    static func identifier(of store: WKWebsiteDataStore) -> UUID? {
        if #available(iOS 17.0, *) {
            return store.identifier
        }
        return nil
    }

    /// 启动对账阶段的明确清除写不进标记（首次解锁前后台启动等）时的内存记录，由随后创建的协调器接手（评审 r1 S2-02）。
    private static var unpersistedEarlyClear = false

    static func noteUnpersistedEarlyClear() {
        unpersistedEarlyClear = true
    }

    static func takeUnpersistedEarlyClear() -> Bool {
        defer { unpersistedEarlyClear = false }
        return unpersistedEarlyClear
    }

    /// 持久化的「Web 数据待清理」标记文件（Application Support 下，切换环境 / 撤回同意的清理器都不删它）。
    public static var pendingFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("couli-trusted-web", isDirectory: true)
            .appendingPathComponent("pending-clear.json")
    }
}

/// 可信容器切号的系统依赖（F-X-25）。生产取 `production()`；测试只替换数据存储、标记文件、清理端口与新 WebView 的观察钩子，
/// 订阅、判定、持久标记、清理调度、投递与重载都走产品代码。
@MainActor
public struct TrustedWebAuthDependencies {
    public let dataStore: WKWebsiteDataStore
    public let pendingFile: URL
    /// 每一类清理的超时（秒）。超时按失败处理，不等不响应取消的系统回调；迟到的完成不会让已失败的事务恢复。
    public var cleanupTimeout: TimeInterval = 15
    /// 清一类数据：true 只代表这一类真实完成且已确认；false、抛错、超时都是整体失败。
    public var clear: @MainActor (TrustedWebDataKind, WKWebsiteDataStore, [WKWebView]) async throws -> Bool = {
        try await TrustedWebDataCleaner.clear(kind: $0, in: $1, documents: $2)
    }

    /// 每个可信 WKWebView 在生产导航代理与桥安装之后、任何加载之前调用（含切号重建的新 WebView）。生产为空。
    public var configureWebView: @MainActor (WKWebView) -> Void = { _ in }
    /// 切号时新建的空可信 store（评审 r2 S0-R2-01）。默认 iOS 17+ 新标识、iOS 16 新临时会话。
    public var makeStore: @MainActor () -> WKWebsiteDataStore = { TrustedWebDataStore.makeFresh() }
    /// 删除换下的旧 store（按标识）。nil = 不删（测试默认：测试自己的 store 由测试收尾删）；生产为 `remove(forIdentifier:)`。
    public var removeStore: (@MainActor (UUID) async throws -> Void)?
    /// 生产：换 store 时同步 `TrustedWebDataStore.current`，冷启动清掉一切非当前标识的残留 store。
    var isProduction = false

    public init(dataStore: WKWebsiteDataStore, pendingFile: URL) {
        self.dataStore = dataStore
        self.pendingFile = pendingFile
    }

    public static func production() -> TrustedWebAuthDependencies {
        var deps = TrustedWebAuthDependencies(
            dataStore: TrustedWebDataStore.current, pendingFile: TrustedWebDataStore.pendingFile
        )
        deps.isProduction = true
        deps.removeStore = { id in
            if #available(iOS 17.0, *) {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
            }
        }
        return deps
    }

    /// 还没有协调器时（启动对账阶段的明确清除）只登记持久待清理标记（归属未知）；已有标记时保留原归属。协调器创建时先补清。
    @discardableResult
    public func markPendingClear() -> Bool {
        let store = TrustedWebPendingStore(file: pendingFile)
        guard store.load() == .none else { return true }
        do {
            try store.save(owner: nil)
            return true
        } catch {
            TrustedWebDataStore.noteUnpersistedEarlyClear()
            return false
        }
    }
}

/// 可信存储的真实清理（F-X-25 I2）：每类先 `removeData` 并等系统完成回调，再读回确认已空——Cookie 读
/// `httpCookieStore.allCookies()`，其余读 `dataRecords(ofTypes:)`；读回仍有数据返回 false（整体失败、保持隔离）。
/// 只作用于传入的可信 store，不调用任何波及 default / 外部容器的全局接口（I6）。
///
/// sessionStorage：`WKWebsiteDataTypeSessionStorage` 在数据存储接口里，按上面同样清并确认；另外切号恢复时可信容器整个换新的
/// WKWebView（新的浏览上下文 = 新的 sessionStorage 命名空间、空的前进后退列表与页面缓存，见 TrustedWebController
/// `authRetireDocument`），所以旧标签页内存里的 sessionStorage 不可能被新文档或历史后退读到。
@MainActor
public enum TrustedWebDataCleaner {
    public static func clear(
        kind: TrustedWebDataKind,
        in store: WKWebsiteDataStore,
        documents _: [WKWebView]
    ) async throws -> Bool {
        await store.removeData(ofTypes: removalTypes(kind), modifiedSince: .distantPast)
        switch kind {
        case .cookies:
            let remaining = await store.httpCookieStore.allCookies()
            return remaining.isEmpty
        default:
            let records = await store.dataRecords(ofTypes: confirmationTypes(kind))
            return records.isEmpty
        }
    }

    /// 每类要删的系统数据类型。HTTP 缓存一项同时删 Service Worker、WebSQL 等其余可持久的站点数据（都属于旧身份的缓存性数据）。
    static func removalTypes(_ kind: TrustedWebDataKind) -> Set<String> {
        switch kind {
        case .cookies: [WKWebsiteDataTypeCookies]
        case .localStorage: [WKWebsiteDataTypeLocalStorage]
        case .sessionStorage: [WKWebsiteDataTypeSessionStorage]
        case .indexedDB: [WKWebsiteDataTypeIndexedDBDatabases]
        case .httpCache: cacheTypes
        }
    }

    /// 读回确认的类型（评审 r1 S2-07）：sessionStorage、MemoryCache 是否出现在 `dataRecords` 里由 WebKit 决定，对它们的读回可能
    /// 形同虚设；MemoryCache、WebSQL、FileSystem 不在确认集合里。它们靠真实设备用例兜底（E01 / E02 / E03），sessionStorage 另有
    /// 「恢复时换新 WKWebView」的纵深防护。
    static func confirmationTypes(_ kind: TrustedWebDataKind) -> Set<String> {
        switch kind {
        case .httpCache:
            [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache,
             WKWebsiteDataTypeServiceWorkerRegistrations]
        default:
            removalTypes(kind)
        }
    }

    static let cacheTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
        WKWebsiteDataTypeOfflineWebApplicationCache, WKWebsiteDataTypeServiceWorkerRegistrations,
        WKWebsiteDataTypeWebSQLDatabases, WKWebsiteDataTypeFileSystem,
    ]
}

/// 持久化的「Web 数据待清理」记录（F-X-25 I3）：判定账号变化 / 登出时先写，成功清理后才删。内容是旧身份（数据归属），
/// 读不出或损坏也算「有待清理、归属未知」，不能当作没有。
struct TrustedWebPendingStore {
    enum Load: Equatable {
        case none
        case pending(owner: WebSessionIdentity?)
    }

    private struct Record: Codable {
        var version = 1
        var known: Bool
        var account: String?
        var loginEpoch: String?
    }

    let file: URL

    func load() -> Load {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .none
        }
        guard let data = try? Data(contentsOf: file),
              let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1
        else { return .pending(owner: nil) }
        guard record.known else {
            return .pending(owner: nil)
        }
        return .pending(owner: WebSessionIdentity(known: true, account: record.account, loginEpoch: record.loginEpoch))
    }

    func save(owner: WebSessionIdentity?) throws {
        let record = Record(
            known: owner?.known ?? false, account: owner?.account, loginEpoch: owner?.loginEpoch
        )
        let data = try JSONEncoder().encode(record)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }
}

/// 可信 store 标识的持久记录（评审 r2 S0-R2-01）：当前标识与换下待删的旧标识。
struct TrustedWebStoreRegistry {
    struct Record: Codable, Equatable {
        var current: UUID?
        var retired: Set<UUID> = []
    }

    let file: URL

    static func file(nextTo pendingFile: URL) -> URL {
        pendingFile.deletingLastPathComponent().appendingPathComponent("trusted-web-stores.json")
    }

    func load() -> Record {
        guard let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return Record() }
        return record
    }

    func save(_ record: Record) throws {
        let data = try JSONEncoder().encode(record)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
