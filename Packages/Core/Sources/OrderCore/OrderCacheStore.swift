import CryptoKit
import Foundation

/// 一份缓存的列表第一页（默认视图）与它的成功获取时刻。
public struct CachedOrderList: Equatable, Sendable {
    public let data: OrderListData
    public let fetchedAt: Int64
}

/// 一份缓存的订单详情与它的成功获取时刻。
public struct CachedOrderDetail: Equatable, Sendable {
    public let detail: OrderDetail
    public let fetchedAt: Int64
}

/// 「待清理」状态的持久化，放在缓存目录之外（APP-08 共性第 28 条）：缓存目录局部故障时目录内的标记可能和缓存一起写不进、删不掉，重启后
/// 同账号的归属一致就会读回旧订单。`set` / `clear` 返回是否确认写入；`isSet` 读不出按已设置。
public protocol OrderPendingClearFlag: AnyObject {
    func isSet() -> Bool
    func set() -> Bool
    func clear() -> Bool
}

/// 缺省的待清理标记：缓存根目录旁边的一个文件（与缓存目录同级、不在其中），写后读回确认。
public final class OrderSiblingPendingFlag: OrderPendingClearFlag {
    private let url: URL

    public init(root: URL) {
        url = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".pending_clear")
    }

    public func isSet() -> Bool {
        do {
            return try read()
        } catch {
            return true
        }
    }

    public func set() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("1".utf8).write(to: url, options: .atomic)
            return (try? read()) == true
        } catch {
            return false
        }
    }

    public func clear() -> Bool {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return (try? read()) == false
        } catch {
            return false
        }
    }

    private func read() throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        _ = try Data(contentsOf: url)
        return true
    }
}

/// 订单本机数据的持久清理单元（APP-08 共性第 28、40 条，iOS RC-03 / RC-04）：恢复记录删不掉、旧记录没确认写盘时登记待清理（缓存目录
/// 之外的标记，跨重启），启动核验与恢复之前先完成。
@MainActor
public protocol OrderCleanupUnit: AnyObject {
    var isPendingClear: Bool { get }
    /// 登记待清理（落到缓存目录之外并确认写入）；返回是否确认写入。
    @discardableResult
    func markPendingClear() -> Bool
    /// 完成待清理（全部删除并确认）；返回是否已没有待清理。
    func completePendingClear() -> Bool
}

/// 断网缓存的落盘（TECH-20，G10；策略见 `OrderStaleCache`）：Application Support 下的 `orders/`（不备份：isExcludedFromBackup），按账号分目录
/// （目录名是账号的哈希，不落明文账号），原子写；列表只存每个 scope 的第一页，详情最多 30 条按最近使用淘汰。
/// - 删除要确认落盘成功：任何一个文件删不掉、目录在却枚举失败（区分「目录不存在」，共性第 20 条）都保留「待清理」状态（内存 + 缓存目录之外的
///   标记，共性第 28 条）并报失败；清理完成之前不读回、不写入；启动、读、写之前都先核验并完成清理；
/// - 读取失败或记录损坏一律当作「没有缓存」（并删掉坏文件）；
/// - 所有方法同步执行（文件很小），只在主线程用。
@MainActor
public final class OrderCacheStore: OrderCleanupUnit {
    public static let directoryName = "orders"
    static let ownerFile = "owner"
    static let detailsFile = "details.json"
    static let marker = "pending_clear"
    static let unreadableOwner = "<unreadable>"

    public let root: URL
    private let flag: OrderPendingClearFlag
    /// 列目录（测试替换：模拟目录在、却枚举失败）。
    var lister: (URL) -> [URL]?
    /// 订单 Tab 根恢复记录的落盘删除（可能含完整订单号搜索词与锚点订单；共性第 36、40 条）：与缓存同属一个清理单元，在「待清理」状态下
    /// 一起删、`removeItem` 确认成功才清缓存目录之外的待清理标记。测试替换以模拟删除失败。
    var pageStateEraser: (@MainActor () -> Bool)?
    /// 订单 Tab 根恢复记录的落盘文件（与缓存根目录同级；OrderPageRestorer 读写它，清理单元删除并确认，共性第 40 条）。
    public let pageState: OrderPageStateFile
    private var pendingClear = false

    /// - Parameter legacyPageStateDefaults: 旧版本把恢复记录放在这里的 UserDefaults（只删不读）；nil = 不管旧记录。
    public init(root: URL, flag: OrderPendingClearFlag? = nil, legacyPageStateDefaults: UserDefaults? = nil) {
        self.root = root
        self.flag = flag ?? OrderSiblingPendingFlag(root: root)
        lister = { url in
            try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        }
        let pageState = OrderPageStateFile.beside(root: root, legacyDefaults: legacyPageStateDefaults)
        self.pageState = pageState
        pageStateEraser = { pageState.erase() }
    }

    /// 生产位置：Application Support/com.couli.app/orders。
    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.couli.app", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    // MARK: - 列表

    public func readList(account: String?, scope: String) -> CachedOrderList? {
        guard let dir = accountDir(account) else { return nil }
        let file = dir.appendingPathComponent(listFile(scope))
        guard let object = read(file) else { return nil }
        guard let data = OrderJSON.listData(object["data"]), let at = JSONPick.int64(object["fetched_at"]) else {
            discard(file)
            return nil
        }
        var page = data
        page.nextCursor = nil
        return CachedOrderList(data: page, fetchedAt: at)
    }

    /// 写 scope 的列表缓存（调用方保证是默认视图的第一页）。
    public func writeList(account: String?, scope: String, data: OrderListData, fetchedAt: Int64) {
        guard let dir = ownedDir(account) else { return }
        write(dir.appendingPathComponent(listFile(scope)), ["fetched_at": fetchedAt, "data": OrderJSON.encode(data)])
    }

    // MARK: - 详情

    public func readDetail(account: String?, orderId: String) -> CachedOrderDetail? {
        guard let dir = accountDir(account) else { return nil }
        let entries = details(dir)
        guard let entry = entries.first(where: { ($0["order_id"] as? String) == orderId }),
              let object = entry["detail"] as? [String: Any], let detail = OrderJSON.detail(object),
              let at = JSONPick.int64(entry["fetched_at"])
        else { return nil }
        return CachedOrderDetail(detail: detail, fetchedAt: at)
    }

    /// 写一条详情；超过 30 条按最近使用淘汰（这条排到最新）。
    public func writeDetail(account: String?, detail: OrderDetail, fetchedAt: Int64) {
        guard let dir = ownedDir(account) else { return }
        let id = detail.summary.orderId
        var entries = details(dir).filter { ($0["order_id"] as? String) != id }
        entries.append(["order_id": id, "fetched_at": fetchedAt, "detail": OrderJSON.encode(detail)])
        write(
            dir.appendingPathComponent(Self.detailsFile),
            ["entries": Array(entries.suffix(OrderStaleCache.detailLimit))]
        )
    }

    // MARK: - 归属与清理

    /// 当前会话的账号（nil = 没有会话）与缓存的归属不一致（登出、换账号、会话失效）：全部删除。启动时也调一次。
    public func reconcileOwner(account: String?) {
        guard cleaned() else { return }
        let ownerURL = root.appendingPathComponent(Self.ownerFile)
        let owner: String?
        do {
            owner = FileManager.default.fileExists(atPath: ownerURL.path)
                ? try String(contentsOf: ownerURL, encoding: .utf8) : nil
        } catch {
            // 归属记录读不出（I/O 故障）不能当成「没有归属」：按不一致全部删除（共性第 20 条）
            owner = Self.unreadableOwner
        }
        let current = account.map(Self.hash)
        if let owner, owner != current {
            try? clearAll()
        }
    }

    /// 全部删除（撤回同意、切换环境、登出、换账号）：任何一个文件删不掉都保留待清理并抛错（调用方保持待完成、之后重试）。
    public func clearAll() throws {
        pendingClear = true
        // 先把待清理状态落到缓存目录之外并确认写入；写不进时仍尽力删除，删不掉照常报失败
        if !flag.set() {
            OrderLog.warn("orders: cache pending flag not persisted")
        }
        // 恢复记录先删（不依赖缓存目录在不在、能不能枚举）；删不掉照常删缓存，最后报失败、保留待清理（期间禁止恢复）
        let pageStateErased = pageStateEraser?() ?? true
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        // 根目录根本不存在：没有任何缓存（不是枚举失败）
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            try finishClear(pageStateErased: pageStateErased)
            return
        }
        let markerURL = root.appendingPathComponent(Self.marker)
        if isDirectory.boolValue {
            try? Data("1".utf8).write(to: markerURL, options: .atomic)
        }
        // 目录在、却枚举失败（权限、I/O 故障）不能当成空目录：保留待清理并报失败（共性第 20 条）
        guard isDirectory.boolValue, let children = lister(root) else {
            throw OrderCacheError.incomplete("order cache directory not listable")
        }
        for child in children where child.lastPathComponent != Self.marker {
            try? manager.removeItem(at: child)
        }
        guard let remaining = lister(root) else { throw OrderCacheError.incomplete("order cache not listable") }
        if remaining.contains(where: { $0.lastPathComponent != Self.marker }) {
            throw OrderCacheError.incomplete("order cache not fully deleted")
        }
        if manager.fileExists(atPath: markerURL.path) {
            do {
                try manager.removeItem(at: markerURL)
            } catch {
                throw OrderCacheError.incomplete("order cache marker not deleted")
            }
        }
        try finishClear(pageStateErased: pageStateErased)
    }

    /// 确认全部删除之后：先清缓存目录之外的待清理状态（确认写入），再清内存状态。恢复记录没删掉时保留待清理并报失败。
    private func finishClear(pageStateErased: Bool) throws {
        guard pageStateErased else { throw OrderCacheError.incomplete("order page state not erased") }
        guard flag.clear() else { throw OrderCacheError.incomplete("order cache pending flag not cleared") }
        pendingClear = false
    }

    /// 登记待清理（恢复记录删不掉、旧记录没确认写盘；共性第 28 条）：内存 + 缓存目录之外的标记。返回标记是否确认写入。
    @discardableResult
    public func markPendingClear() -> Bool {
        pendingClear = true
        return flag.set()
    }

    /// 完成待清理：没有待清理直接返回 true；否则全部删除并确认。
    public func completePendingClear() -> Bool {
        cleaned()
    }

    /// 启动时的旧记录迁移清理（iOS RC-03）：旧版本 UserDefaults 里还有恢复记录（只判断在不在、不读内容）→ 先登记持久待清理，再执行清理
    /// 单元（删旧记录并同步写盘确认、删恢复文件与缓存）；没确认的保留待清理，下次启动 / 恢复前重试。
    public func migrateLegacyPageState() {
        guard pageState.hasLegacy else { return }
        markPendingClear()
        try? clearAll()
    }

    /// 是否仍有没完成的清理（测试与外壳核对）。
    public var isPendingClear: Bool {
        pendingClear || flag.isSet() || FileManager.default
            .fileExists(atPath: root.appendingPathComponent(Self.marker).path)
    }

    /// 待清理期间先重试清理；清不掉返回 false（不读、不写）。
    private func cleaned() -> Bool {
        guard isPendingClear else { return true }
        return (try? clearAll()) != nil
    }

    private func accountDir(_ account: String?) -> URL? {
        guard let account, !account.isEmpty, cleaned() else { return nil }
        return root.appendingPathComponent(Self.hash(account), isDirectory: true)
    }

    /// 写入前确保归属：别的账号的缓存先全部删掉（删不掉就不写）。
    private func ownedDir(_ account: String?) -> URL? {
        reconcileOwner(account: account)
        guard let account, let dir = accountDir(account) else { return nil }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            excludeFromBackup(root)
            try Data(Self.hash(account).utf8).write(to: root.appendingPathComponent(Self.ownerFile), options: .atomic)
            return dir
        } catch {
            OrderLog.warn("orders: cache owner not written")
            return nil
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    private func details(_ dir: URL) -> [[String: Any]] {
        read(dir.appendingPathComponent(Self.detailsFile))?["entries"] as? [[String: Any]] ?? []
    }

    /// 读一个文件：没有为 nil；读不出或损坏删掉它并按没有缓存。
    private func read(_ file: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let data = try? Data(contentsOf: file),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            discard(file)
            return nil
        }
        return object
    }

    private func write(_ file: URL, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        do {
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            OrderLog.warn("orders: cache write failed")
        }
    }

    private func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    private func listFile(_ scope: String) -> String {
        "list_\(OrderQuery.normalizeScope(scope)).json"
    }

    /// 账号 → 目录名（SHA-256 前 16 位十六进制；不落明文账号）。
    public nonisolated static func hash(_ account: String) -> String {
        SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

public enum OrderCacheError: Error, Equatable {
    case incomplete(String)
}
