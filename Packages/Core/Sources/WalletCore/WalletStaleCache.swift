import CryptoKit
import Foundation
import OrderCore

/// 一份缓存的钱包摘要与它的成功获取时刻。
public struct CachedWalletSummary: Equatable, Sendable {
    public let summary: WalletSummary
    public let fetchedAt: Int64
}

/// 钱包断网显示上次数据（TECH-20，G22）：只缓存钱包摘要（GET /v1/wallet/summary 最近一次成功响应），Withdraw、rules、提现记录、收款账号
/// 一律不缓存。登出、换账号、会话失效、撤回同意、切换环境时删除；进后台、刷新成功不删（刷新成功是更新缓存）。只有传输层失败才用缓存。
public enum WalletStaleCache {
    public static let summaryKind = "summary"
    /// 清缓存的事件（三端同名）。
    public static let clearEvents: Set<String> = [
        "logout",
        "account_switch",
        "session_invalid",
        "consent_revoked",
        "env_switch",
    ]

    public static func isCacheable(kind: String) -> Bool {
        kind == summaryKind
    }

    public static func clearsOn(event: String) -> Bool {
        clearEvents.contains(event)
    }
}

/// 钱包本机数据的落盘（G22；做法同 APP-08 OrderCacheStore）：Application Support 下的 `wallet/`（isExcludedFromBackup），按账号分目录
/// （目录名是账号的哈希，不落明文账号），原子写。另有提现页的金额草稿（进程回收后恢复，账号相同才用，不恢复估算；iOS I06）。
/// - 删除要确认落盘成功：任何一个文件删不掉、目录在却枚举失败（区分「目录不存在」）都保留「待清理」状态（内存 + 缓存目录之外的标记，
///   APP-08 共性第 20、28 条）并报失败；清理完成之前不读回、不写入；读、写之前都先核验并完成清理；
/// - 写入世代（APP-11 第 23 条）：每次清理推进世代，写入带发起读取时取得的世代票据，票据过期（期间清理过）不写；
/// - 读取失败或记录损坏一律当作「没有缓存」（并删掉坏文件）。只在主线程用。
@MainActor
public final class WalletCacheStore {
    public nonisolated static let directoryName = "wallet"
    static let ownerFile = "owner"
    static let summaryFile = "summary.json"
    public nonisolated static let draftFile = "withdraw_draft.json"
    static let marker = "pending_clear"
    static let unreadableOwner = "<unreadable>"

    public let root: URL
    private let flag: OrderPendingClearFlag
    /// 列目录（测试替换：模拟目录在、却枚举失败）。
    var lister: (URL) -> [URL]?
    private var pendingClear = false
    /// 写入世代：每次 `clearAll` 加一。
    public private(set) var generation = 0

    public init(root: URL, flag: OrderPendingClearFlag? = nil) {
        self.root = root
        self.flag = flag ?? OrderSiblingPendingFlag(root: root)
        lister = { url in try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
    }

    /// 生产位置：Application Support/com.couli.app/wallet。
    public nonisolated static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.couli.app", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    // MARK: - 摘要

    public func read(account: String?) -> CachedWalletSummary? {
        guard let dir = accountDir(account) else { return nil }
        let file = dir.appendingPathComponent(Self.summaryFile)
        guard let object = read(file) else { return nil }
        guard let summary = WalletJSON.summary(object["data"]), let at = WalletJSON.int64(object["fetched_at"]) else {
            discard(file)
            return nil
        }
        return CachedWalletSummary(summary: summary, fetchedAt: at)
    }

    /// 写摘要：`ticket` 是发起读取时的 `generation`（之后清理过就不写）。
    public func write(account: String?, summary: WalletSummary, fetchedAt: Int64, ticket: Int) {
        guard ticket == generation, let dir = ownedDir(account) else { return }
        write(
            dir.appendingPathComponent(Self.summaryFile),
            ["fetched_at": fetchedAt, "data": WalletJSON.encode(summary)]
        )
    }

    // MARK: - 提现金额草稿（iOS I06）

    /// 账号相同才给（不恢复估算）；没有为 nil。
    public func readDraft(account: String?) -> String? {
        guard let dir = accountDir(account) else { return nil }
        return read(dir.appendingPathComponent(Self.draftFile))?["amount"] as? String
    }

    public func writeDraft(account: String?, amount: String, ticket: Int) {
        guard ticket == generation, let dir = ownedDir(account) else { return }
        let file = dir.appendingPathComponent(Self.draftFile)
        if amount.isEmpty {
            discard(file)
        } else {
            write(file, ["amount": amount])
        }
    }

    public func deleteDraft(account: String?) {
        guard let dir = accountDir(account) else { return }
        discard(dir.appendingPathComponent(Self.draftFile))
    }

    // MARK: - 归属与清理

    /// 当前会话的账号（nil = 没有会话）与缓存的归属不一致（登出、换账号、会话失效）：全部删除。
    public func reconcileOwner(account: String?) {
        guard cleaned() else { return }
        let ownerURL = root.appendingPathComponent(Self.ownerFile)
        let owner: String?
        do {
            owner = FileManager.default.fileExists(atPath: ownerURL.path)
                ? try String(contentsOf: ownerURL, encoding: .utf8) : nil
        } catch {
            // 归属记录读不出不能当成「没有归属」：按不一致全部删除
            owner = Self.unreadableOwner
        }
        if let owner, owner != account.map(Self.hash) {
            try? clearAll()
        }
    }

    /// 全部删除（撤回同意、切换环境、登出、换账号）：任何一个文件删不掉都保留待清理并抛错。
    public func clearAll() throws {
        generation += 1
        pendingClear = true
        if !flag.set() {
            WalletLog.warn("wallet: cache pending flag not persisted")
        }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            try finishClear()
            return
        }
        let markerURL = root.appendingPathComponent(Self.marker)
        if isDirectory.boolValue {
            try? Data("1".utf8).write(to: markerURL, options: .atomic)
        }
        // 目录在、却枚举失败不能当成空目录：保留待清理并报失败
        guard isDirectory.boolValue, let children = lister(root) else {
            throw WalletCacheError.incomplete("wallet cache directory not listable")
        }
        for child in children where child.lastPathComponent != Self.marker {
            try? manager.removeItem(at: child)
        }
        guard let remaining = lister(root) else { throw WalletCacheError.incomplete("wallet cache not listable") }
        if remaining.contains(where: { $0.lastPathComponent != Self.marker }) {
            throw WalletCacheError.incomplete("wallet cache not fully deleted")
        }
        if manager.fileExists(atPath: markerURL.path) {
            do {
                try manager.removeItem(at: markerURL)
            } catch {
                throw WalletCacheError.incomplete("wallet cache marker not deleted")
            }
        }
        try finishClear()
    }

    private func finishClear() throws {
        guard flag.clear() else { throw WalletCacheError.incomplete("wallet cache pending flag not cleared") }
        pendingClear = false
    }

    /// 是否仍有没完成的清理。
    public var isPendingClear: Bool {
        pendingClear || flag.isSet()
            || FileManager.default.fileExists(atPath: root.appendingPathComponent(Self.marker).path)
    }

    private func cleaned() -> Bool {
        guard isPendingClear else { return true }
        return (try? clearAll()) != nil
    }

    private func accountDir(_ account: String?) -> URL? {
        guard let account, !account.isEmpty, cleaned() else { return nil }
        return root.appendingPathComponent(Self.hash(account), isDirectory: true)
    }

    private func ownedDir(_ account: String?) -> URL? {
        reconcileOwner(account: account)
        guard let account, let dir = accountDir(account) else { return nil }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var target = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? target.setResourceValues(values)
            try Data(Self.hash(account).utf8).write(to: root.appendingPathComponent(Self.ownerFile), options: .atomic)
            return dir
        } catch {
            WalletLog.warn("wallet: cache owner not written")
            return nil
        }
    }

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
            WalletLog.warn("wallet: cache write failed")
        }
    }

    private func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    /// 账号 → 目录名（SHA-256 前 16 位十六进制；不落明文账号）。
    public nonisolated static func hash(_ account: String) -> String {
        SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

public enum WalletCacheError: Error, Equatable {
    case incomplete(String)
}
