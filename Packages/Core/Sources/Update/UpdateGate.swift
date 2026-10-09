import Foundation

/// 强更检查的纯逻辑与持久化（03 §4.1、§4.4，BR-ID-01；三端同名，任务书 §2.1；向量 `specs/update-vectors.json`）。
///
/// - 检查时机：冷启动必查；回前台距上一次**成功**检查严格超过 `recheckIntervalSec` 才查（失败与请求发起不重置计时）。
/// - 冷启动：本机记着「低于最低版本」（成功检查或 10405 带来的）就直接按低于处理（同时照常再查）——但要按**本机当前**
///   appVersion 与缓存的 min 重新比较：升级后已不低于的不再算强更（编排者裁定 rule-gaps G15），按检查中 / unknown。
///   本机记着的其他结论（ok、below_recommended）冷启动不作数，按「检查中」等这一次；本次失败按 unknown，不恢复旧结论
///   （03 §4.4）。「暂不更新」的记录不失效（03 §4.1）。
///   同一次运行里成功过之后，回前台复查期间保留已知结论（rule-gaps G12：不固定瞬态投影）。
/// - 失败不拦用户自己的操作：本次运行成功过的保持那次结论，没有就是 unknown；失败后下次回前台再试（不论间隔）。
/// - 10405（接口层拦截）直接进 below_min，直到下一次成功检查。
/// - 可关闭提示：严格低于 recommended 才算；按提示时的 latest 记「暂不更新」，同一版本不再提示，更高版本再提示；
///   提示前还要核对来源商店（读不到来源时看默认商店）的已上架版本不低于 recommended（BR-ID-01，rule-gaps G02）。
/// - 5 秒等待、基本模式不检查、只读降级都不在这里（属于启动协调与入口守卫，rule-gaps G06）。
///
/// 不是线程安全的：在主线程使用。时间一律毫秒。
public final class UpdateGate {
    /// `recheck_interval_sec` 的包内默认（BR-ID-01；配置接入前一直用它，rule-gaps G01）。
    public static let defaultRecheckIntervalSec = 1800

    public let appVersion: String
    public let platform: String
    public let channel: String
    /// 已按商店对照表归一化的安装来源商店键；读不到或不在表里为 nil（rule-gaps G03）。
    public let installSource: String?

    private let store: any UpdateStore
    private let clock: () -> Int64
    private var record: UpdateRecord
    /// 生命周期方法发起了检查、结果还没投递。
    private var inFlight = false
    /// 本次运行（这个 Gate 实例自冷启动以来）有过成功检查：本机记着的非强更结论只有这时才作数（03 §4.4）。
    private var succeededThisRun = false
    /// 最近一次检查失败（下次回前台不论间隔再试，03 §4.1），直到下一次成功检查。
    /// 界面投影可保留本次运行已知的旧结论（向量 G14），但路由按 unknown 处理（编排者裁定，APP-02c R2-01）。
    public private(set) var lastCheckFailed = false

    public init(
        store: any UpdateStore,
        clock: @escaping () -> Int64,
        appVersion: String,
        platform: String,
        channel: String,
        installSource: String?
    ) {
        self.store = store
        self.clock = clock
        self.appVersion = appVersion
        self.platform = platform
        self.channel = channel
        self.installSource = installSource
        record = store.load()
    }

    /// 最近一次成功检查的结果（强更页内容、选店用）。
    public var lastResult: UpdateCheckResult? {
        record.lastResult
    }

    /// 生命周期方法发起的检查还没有结果。
    public var isChecking: Bool {
        inFlight
    }

    // MARK: - 检查时机

    /// 冷启动：一律要查；本机记着的非强更结论从此不作数，等这一次的结果。
    @discardableResult
    public func onColdStart(now _: Int64) -> Bool {
        inFlight = true
        succeededThisRun = false
        return true
    }

    /// 回前台：本次运行还没成功过、上一次检查失败，或距上一次成功检查严格超过间隔才查。
    @discardableResult
    public func onForeground(now: Int64) -> Bool {
        if succeededThisRun, !lastCheckFailed, let last = record.lastSuccessAt {
            let interval = Int64(record.lastResult?.recheckIntervalSec ?? Self.defaultRecheckIntervalSec) * 1000
            guard now - last > interval else { return false }
        }
        inFlight = true
        return true
    }

    // MARK: - 结果投递

    public func apply(result: UpdateCheckResult, now: Int64) {
        record.lastResult = result
        record.lastSuccessAt = now
        record.forcedMinimum = nil
        record.forcedByServer = nil
        record.forcedAppVersion = nil
        store.save(record)
        succeededThisRun = true
        lastCheckFailed = false
        inFlight = false
    }

    /// 检查失败：保持本次运行已知的结论（没有就是 unknown；本机记着的强更照旧）。
    public func applyFailure(now _: Int64) {
        lastCheckFailed = true
        inFlight = false
    }

    /// 接口层收到 10405（网络层 APP-03 调用）：本机版本确实低于 `minSupported` 时直接进 below_min。
    /// `minSupported` 为空、解析不了或本机不低于它时不处理——那是升级前留下的受限令牌，由会话层先刷新（rule-gaps G07）。
    public func on10405(minSupported: String?, now _: Int64) {
        guard let minSupported, Self.compareVersions(a: appVersion, b: minSupported) == -1 else {
            return
        }
        record.forcedMinimum = minSupported
        store.save(record)
    }

    // MARK: - 结论

    public func state(now _: Int64) -> UpdateState {
        if forcedByServer {
            return serverForcedState()
        }
        let known = Self.evaluate(
            appVersion: appVersion,
            result: record.lastResult,
            forcedMinimum: record.forcedMinimum,
            dismissedLatest: record.dismissedLatest,
            promptStore: promptStore(record.lastResult)
        )
        if known.status == .belowMin {
            return known
        }
        guard succeededThisRun else {
            return UpdateState(status: inFlight ? .checking : .unknown)
        }
        if inFlight, known.status == .unknown {
            return UpdateState(status: .checking)
        }
        return known
    }

    /// 可关闭提示的【暂不更新】：按提示时的 latest_version 记在本机。强更状态下不记（ForceUpdate 没有「暂不更新」）。
    public func dismissPrompt(now: Int64) {
        let current = state(now: now)
        guard current.status == .belowRecommended, let target = current.targetVersion else { return }
        record.dismissedLatest = target
        store.save(record)
    }

    // MARK: - 选店

    /// 【去更新】打开哪家商店（03 §4.1，BR-ID-01 细则）：
    /// - 强更：安装来源商店 → default_store → stores 其余（同一家只看一次），逐家核对已上架版本 ≥ min_supported_version
    ///   且本机能打开，第一家都满足的就是；
    /// - 可关闭提示：只看来源商店（读不到来源时看默认商店），门槛是 recommended_version，不改去别家；
    /// - 其余状态或一家都不满足：unavailable。
    /// `canOpen` 只是能力检查；真正打开失败后的处理在打开器（rule-gaps G08）。
    public func pickStore(
        result: UpdateCheckResult,
        now _: Int64,
        canOpen: (String) -> Bool
    ) -> StoreChoice {
        if forcedByServer {
            let forced = serverForcedState()
            // 没有高于本机的最低版本：已上架版本严格高于本机才算
            return pickForced(
                result: result, threshold: forced.targetVersion ?? appVersion,
                strict: forced.targetVersion == nil, canOpen: canOpen
            )
        }
        let evaluated = Self.evaluate(
            appVersion: appVersion,
            result: result,
            forcedMinimum: record.forcedMinimum,
            dismissedLatest: nil,
            promptStore: nil
        )
        let threshold: String
        let candidates: [String]
        switch evaluated.status {
        case .belowMin:
            guard let target = evaluated.targetVersion else { return Self.unavailable }
            threshold = target
            candidates = [installSource, result.defaultStore].compactMap(\.self) + result.stores.map(\.store)
        case .belowRecommended:
            guard let recommended = result.recommended, let source = installSource ?? result.defaultStore else {
                return Self.unavailable
            }
            threshold = recommended
            candidates = [source]
        case .ok, .unknown, .checking:
            return Self.unavailable
        }
        var seen = Set<String>()
        for key in candidates where seen.insert(key).inserted {
            guard let listed = result.listedVersion(of: key),
                  let order = Self.compareVersions(a: listed, b: threshold), order >= 0
            else {
                continue
            }
            if canOpen(key) {
                return StoreChoice(storeKey: key, unavailable: false)
            }
        }
        return Self.unavailable
    }

    private static let unavailable = StoreChoice(storeKey: nil, unavailable: true)

    /// 可关闭提示要核对的商店：来源商店，读不到来源时默认商店。
    private func promptStore(_ result: UpdateCheckResult?) -> String? {
        installSource ?? result?.defaultStore
    }

    // MARK: - 判定

    private static func evaluate(
        appVersion: String,
        result: UpdateCheckResult?,
        forcedMinimum: String?,
        dismissedLatest: String?,
        promptStore: String?
    ) -> UpdateState {
        // TODO(N-14): 本机或下发的版本串不合法时按 unknown（rule-gaps G05：非法输入如何表达未定）。
        guard parse(appVersion) != nil else { return UpdateState(status: .unknown) }
        var minimum: String?
        for candidate in [forcedMinimum, result?.minSupported].compactMap(\.self) {
            guard let order = compareVersions(a: appVersion, b: candidate) else {
                return UpdateState(status: .unknown)
            }
            if order < 0, minimum.flatMap({ compareVersions(a: candidate, b: $0) }).map({ $0 > 0 }) ?? true {
                minimum = candidate
            }
        }
        if let minimum {
            return UpdateState(status: .belowMin, targetVersion: minimum)
        }
        guard let result else { return UpdateState(status: .unknown) }
        guard let recommended = result.recommended else { return UpdateState(status: .ok) }
        guard let order = compareVersions(a: appVersion, b: recommended) else {
            return UpdateState(status: .unknown)
        }
        guard order < 0 else { return UpdateState(status: .ok) }
        let target = result.latest ?? recommended
        return UpdateState(
            status: .belowRecommended,
            showPrompt: promptAllowed(target: target, recommended: recommended, result: result,
                                      dismissedLatest: dismissedLatest, promptStore: promptStore),
            targetVersion: target
        )
    }

    /// 提示：目标版本高于「暂不更新」记下的版本，且来源（或默认）商店的已上架版本不低于 recommended。
    private static func promptAllowed(
        target: String,
        recommended: String,
        result: UpdateCheckResult,
        dismissedLatest: String?,
        promptStore: String?
    ) -> Bool {
        if let dismissedLatest {
            guard let order = compareVersions(a: target, b: dismissedLatest), order > 0 else { return false }
        }
        guard let promptStore, let listed = result.listedVersion(of: promptStore),
              let order = compareVersions(a: listed, b: recommended)
        else {
            return false
        }
        return order >= 0
    }

    // MARK: - 版本比较

    /// 逐段整数比较（1.0.0 < 1.0.10；前导零按整数，01.002 = 1.2；缺的段按 0）。
    /// 返回 -1 / 0 / 1；任一方不是「点分隔的十进制整数」时返回 nil（按 unknown 处理，不伪造比较结果，rule-gaps G05）。
    public static func compareVersions(a first: String, b second: String) -> Int? {
        guard let lhs = parse(first), let rhs = parse(second) else { return nil }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left < right ? -1 : 1
            }
        }
        return 0
    }

    /// TODO(N-14): 预发布 / 构建标识（1.2.0-beta）、超出 Int 的分段未定义（rule-gaps G05），一律按非法。
    static func parse(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else {
                return nil
            }
            numbers.append(number)
        }
        return numbers.isEmpty ? nil : numbers
    }
}

// MARK: - 服务端判定的强更（APP-07）

public extension UpdateGate {
    /// 服务端已对本机判定强更（APP-07 共性第 21、24 条）：行内 10405（parse 外层成功、结果行 error_code=10405）、整体 10405 不带最低版本、
    /// 登录拿到受限会话按「低于」处理时调用。进闸门本身并落盘：强制 below_min，不交给「按缓存最低版本比较」的判断（缓存可能不高于本机，
    /// 会把这次结论放掉）；跨进程保留，只对收到时的 appVersion 成立（升级后失效，G15）；下一次成功检查解除。
    func onServerForced(now _: Int64) {
        record.forcedByServer = true
        record.forcedAppVersion = appVersion
        store.save(record)
    }

    /// 此刻是服务端判定的强更（本机版本未变）。
    var forcedByServer: Bool {
        record.forcedByServer == true && record.forcedAppVersion == appVersion
    }
}

extension UpdateGate {
    /// 服务端判定的强更：目标版本只取高于本机的最低版本（10405 带来的或最近一次检查的），否则为 nil——选店时要求已上架版本高于本机。
    private func serverForcedState() -> UpdateState {
        let target = [record.forcedMinimum, record.lastResult?.minSupported].compactMap(\.self)
            .filter { Self.compareVersions(a: appVersion, b: $0) == -1 }
            .max { Self.compareVersions(a: $0, b: $1) == -1 }
        return UpdateState(status: .belowMin, targetVersion: target)
    }

    /// 服务端判定强更的选店：安装来源 → 默认商店 → 其余，已上架版本 ≥ threshold（strict 时 >）且能打开的第一家。
    private func pickForced(
        result: UpdateCheckResult, threshold: String, strict: Bool, canOpen: (String) -> Bool
    ) -> StoreChoice {
        var seen = Set<String>()
        let candidates = [installSource, result.defaultStore].compactMap(\.self) + result.stores.map(\.store)
        for key in candidates where seen.insert(key).inserted {
            guard let listed = result.listedVersion(of: key),
                  let order = Self.compareVersions(a: listed, b: threshold), strict ? order > 0 : order >= 0
            else {
                continue
            }
            if canOpen(key) {
                return StoreChoice(storeKey: key, unavailable: false)
            }
        }
        return Self.unavailable
    }
}
