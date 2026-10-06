import Foundation

/// 某家商店的已上架版本（check 响应 `stores[]` 的投影：`listed_version` 为 null 的条目不进来，rule-gaps G04）。
public struct UpdateStoreListing: Sendable, Equatable, Codable {
    public let store: String
    public let version: String

    public init(store: String, version: String) {
        self.store = store
        self.version = version
    }
}

/// 一次成功的版本检查（`GET /v1/app-versions/check` 的 data 投影；三端同名，任务书 §2.1）。
///
/// - `recheckIntervalSec` 不在 check 响应里，来自 `/v1/config.app_update.recheck_interval_sec`；配置接入（APP-03）前
///   用 BR-ID-01 的包内默认 1800 秒（rule-gaps G01，`UpdateGate.defaultRecheckIntervalSec`）。
/// - `updateTitle`、`updateNotes` 只给界面用（可关闭提示的标题与说明、强更页的更新内容），不参与判定。
public struct UpdateCheckResult: Sendable, Equatable, Codable {
    public let minSupported: String?
    public let recommended: String?
    public let latest: String?
    public let defaultStore: String?
    public let stores: [UpdateStoreListing]
    public let recheckIntervalSec: Int
    public let updateTitle: String?
    public let updateNotes: String?

    public init(
        minSupported: String?,
        recommended: String?,
        latest: String?,
        defaultStore: String?,
        stores: [UpdateStoreListing],
        recheckIntervalSec: Int = UpdateGate.defaultRecheckIntervalSec,
        updateTitle: String? = nil,
        updateNotes: String? = nil
    ) {
        self.minSupported = minSupported
        self.recommended = recommended
        self.latest = latest
        self.defaultStore = defaultStore
        self.stores = stores
        self.recheckIntervalSec = recheckIntervalSec
        self.updateTitle = updateTitle
        self.updateNotes = updateNotes
    }

    /// 某家商店的已上架版本；没有条目（含 listed_version 为 null 被丢弃的）为 nil。
    public func listedVersion(of store: String) -> String? {
        stores.first { $0.store == store }?.version
    }
}

/// 强更结论（03 §4.1、§4.4）。
public enum UpdateStatus: String, Sendable, CaseIterable {
    case checking
    case ok
    case belowRecommended = "below_recommended"
    case belowMin = "below_min"
    case unknown
}

/// `UpdateGate.state` 的结果（三端同名，任务书 §2.1）。
public struct UpdateState: Sendable, Equatable {
    public let status: UpdateStatus
    /// 是否弹可关闭的更新提示（只在 below_recommended 时可能为 true）。
    public let showPrompt: Bool
    /// below_min：最低支持版本（强更选店门槛）；below_recommended：提示时的 latest_version（「暂不更新」的记录键，rule-gaps G02）。
    public let targetVersion: String?

    public init(status: UpdateStatus, showPrompt: Bool = false, targetVersion: String? = nil) {
        self.status = status
        self.showPrompt = showPrompt
        self.targetVersion = targetVersion
    }

    /// "checking" | "ok" | "below_recommended" | "below_min" | "unknown"
    public var statusRaw: String {
        status.rawValue
    }
}

/// 【去更新】选店结果：`storeKey` 为第一家版本够、本机能打开的商店；一家都不满足时 `unavailable`
/// （界面显示 `app_update.unavailable` 与【重试】，不给任何下载地址）。
public struct StoreChoice: Sendable, Equatable {
    public let storeKey: String?
    public let unavailable: Bool

    public init(storeKey: String?, unavailable: Bool) {
        self.storeKey = storeKey
        self.unavailable = unavailable
    }
}
