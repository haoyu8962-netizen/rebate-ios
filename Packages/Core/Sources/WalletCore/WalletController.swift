import CouliNetwork
import Foundation

/// 钱包页的一次状态快照。`staleAt` 非 nil = 显示的是旧数据（断网的缓存、或刷新失败保留的旧摘要；【提现】置灰）。`version` 每次换数据加一：
/// 按钮回调带渲染时的版本与身份，执行时核对（APP-07 第 18、26 条，APP-09 共性第 4、63 条）。
public struct WalletSnapshot: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case loading, content, error
    }

    public var phase: Phase = .loading
    public var summary: WalletSummary?
    public var staleAt: Int64?
    /// `staleAt` 的原因是网络不可用（「网络不可用，以下为…」）；false 为其他读取失败（中性的「更新于 HH:mm」，共性第 38 条）。
    public var staleNetwork = true
    public var error: Notice?
    public var refreshing = false
    public var version = 0
    /// 本页的固定身份（渲染时随快照交给按钮回调）。
    public var owner: WalletOwner

    /// 【提现】是否可点（G11 + 旧数据态置灰）。
    public var withdrawEnabled: Bool {
        guard let summary, staleAt == nil, error == nil else { return false }
        return summary.withdrawEnabled && summary.negativeFen <= 0
    }
}

/// 钱包页执行器（Wallet 路由；BR-FUND-18、BR-TEXT-01，brief §2.2，G10、G11、G20、G22、G23）。
/// - 摘要只取服务端字段（`WalletSummaryView`）；进入、下拉、回到本页（返回、回前台）各取一次，不轮询；
/// - 断网缓存（G22）：只有传输层失败才用缓存，显示 WalletStale（role=status）并置灰【提现】；5xxxx 不用缓存，显示错误态带 trace6；成功时更新
///   缓存（按账号隔离）；
/// - 42901：读请求共享禁用期（下拉、【重试】置灰，执行层也拦）；10405 由网络层进强更；
/// - 提现成功的失效通知（共性第 53、58、61 条）：只收本页固定身份的通知，作废成功之前发出的摘要请求并重取。
/// 请求绑定页面与固定身份；会话换代时同步清掉已显示的摘要并按新身份重取。只在主线程使用。
@MainActor
public final class WalletController: ObservableObject, IdentityResumable {
    public static let operation = "getWalletSummary"

    @Published public private(set) var state: WalletSnapshot
    let deps: WalletDeps
    private var left = false
    private var seq = 0
    private var serial = 0
    private let requests = WalletRequests()
    /// 本会话最近一次成功取得摘要的时刻（内存；共性第 32 条：旧数据的「更新时间」不依赖磁盘缓存是否写成功）。
    private var lastSuccessAt: Int64?
    private var unsubscribe: (() -> Void)?
    public let visibility = PageVisibility()
    /// 因身份暂时未知中止、等身份确认后补做的读取（FU-IOS-0712 整体重理：订单、钱包、各资金页同一套机制）。「身份已确认」与「加载已完成」
    /// 分开记（RC-02 / G53）：App 在身份确认时（判据相同也算）统一补做。
    public let deferral = IdentityDeferral()

    /// 有因身份暂时未知中止、还没补取的读取。
    public var loadPending: Bool {
        deferral.isPending
    }

    public init(deps: WalletDeps) {
        self.deps = deps
        // 本页的固定身份在构造时一次性取得（共性第 65 条）
        state = WalletSnapshot(owner: deps.env.currentOwner())
        unsubscribe = deps.walletDirty.subscribe { [weak self] owner in
            MainActor.assumeIsolated { self?.dirty(owner) }
        }
    }

    public var alive: Bool {
        !left
    }

    /// 服务端校准后的当前时刻（月份同年 / 跨年判断、旧数据时间）。
    public func displayNowMillis() -> Int64 {
        deps.env.displayNowMillis()
    }

    /// 读请求的共享禁用期（页面置灰【重试】与下拉）。
    public var readGate: RetryAfterGate {
        deps.gates.read
    }

    private func dirty(_ owner: WalletOwner) {
        // 与本页固定身份比较，并核对它仍是当前会话（共性第 61、65 条）；作废成功之前发出的摘要请求再重取
        // 接收端也三态（RV-03）：身份暂时未知时保留这次刷新责任，确认后补（作废旧摘要请求并重取）
        let resume: @MainActor () -> Void = { [weak self] in self?.dirty(owner) }
        guard !left, owner == state.owner,
              deferral.admit(deps.env.check(owner), slot: "walletDirty", resume: resume) else { return }
        seq += 1
        requests.cancelAll()
        load()
    }

    /// 进入、回到本页。
    public func load(refresh: Bool = false) {
        guard !left else { return }
        let owner = state.owner
        // 已确认没有会话的页面不读；身份暂时未知时构造的页面照常核对（结算为可重试，身份确认后由 App 换上身份）
        guard owner.account != nil || !owner.identityKnown else { return }
        guard admitLoad(deps.env.check(owner)) else { return }
        if deps.gates.read.active {
            failed(WalletError(.gated, "error.42901"))
            return
        }
        seq += 1
        let request = seq
        if state.summary == nil {
            state.phase = .loading
            state.error = nil
        } else {
            state.refreshing = refresh
        }
        let ticket = deps.cache?.generation ?? 0
        let probe = deps.gates.read.probe()
        let call = ApiCall(operationId: Self.operation)
        requests.send(deps.api, call, probe: probe, expected: owner.request) { [weak self] result in
            guard let self, !left, seq == request, state.owner == owner, admitLoad(deps.env.check(owner)) else {
                return
            }
            onResult(result, probe: probe, ticket: ticket)
        }
    }

    /// 身份确认之后（App 的会话核对；判据相同也调）补做因身份暂时未知中止的加载。固定身份校验与禁用期在 `load` 里照旧。
    public func resumeAfterIdentityConfirmed() {
        guard !left else { return }
        deferral.resume()
    }

    /// 读取的身份核对（发送前、响应时同一入口）：暂时未知 → 记待补取并结算；已换代 → 丢弃（换代另有重建）。
    private func admitLoad(_ check: IdentityCheck) -> Bool {
        deferral.admit(check, slot: Self.operation, resume: { [weak self] in self?.load() }, settle: {
            identityAborted()
        })
    }

    /// 加载因身份暂时未知中止（RC-02 / G53）：没有摘要时不留无出口的加载态，结算为可重试的失败态（【重试】、下拉重取；身份确认后
    /// App 也会统一补取）。已有摘要时保留显示、收起刷新指示。
    private func identityAborted() {
        if state.summary == nil {
            state = WalletSnapshot(phase: .error, version: state.version + 1, owner: state.owner)
        } else {
            state.refreshing = false
        }
    }

    private func onResult(_ result: ApiResult, probe: SendProbe, ticket: Int) {
        if case let .success(data, _, _) = result, let summary = WalletJSON.summary(WalletJSON.parse(data)) {
            let now = deps.env.displayNowMillis()
            // 按本页固定身份写缓存（共性第 65 条），不按响应到达时读到的账号；写入带发起时的清理世代（APP-11 第 23 条）
            deps.cache?.write(
                account: state.owner.account, loginEpoch: state.owner.loginEpoch, summary: summary, fetchedAt: now,
                ticket: ticket
            )
            lastSuccessAt = now
            state = WalletSnapshot(phase: .content, summary: summary, version: state.version + 1, owner: state.owner)
            return
        }
        let error = WalletErrors.of(result, probe: probe)
        if error.kind == .cancelled {
            state.refreshing = false
            return
        }
        failed(error)
    }

    private func failed(_ error: WalletError) {
        if error.kind == .retryAfter {
            deps.gates.read.start(error.disableMillis)
        }
        serial += 1
        let message = error.notice(id: serial)
        let transport = error.kind == .transport
        let now = deps.env.displayNowMillis()
        if state.summary != nil {
            // 已有旧数据时读取失败（共性第 30、32、38、46 条）：保留数据，不再算「当前」——断网标「网络不可用，以下为…」，其余标「更新于」并
            // 独立显示错误（带 trace6）与【重试】；【提现】都置灰
            state.staleAt = state.staleAt ?? lastSuccessAt ?? now
            state.staleNetwork = transport
            state.error = transport ? nil : message
            state.refreshing = false
            state.version += 1
            return
        }
        // 只有传输层失败才用缓存（G22）；5xxxx 不用缓存、不伪装成余额为 0
        if transport, let cached = deps.cache?.read(account: state.owner.account, loginEpoch: state.owner.loginEpoch) {
            state = WalletSnapshot(
                phase: .content, summary: cached.summary, staleAt: cached.fetchedAt, version: state.version + 1,
                owner: state.owner
            )
            return
        }
        state = WalletSnapshot(phase: .error, error: message, version: state.version + 1, owner: state.owner)
    }

    /// 下拉刷新、【重试】与回到本页（禁用期内不发，但按限流结算显示，共性第 55 条）。
    @discardableResult
    public func refresh() -> Bool {
        guard !left else { return false }
        if deps.gates.read.active {
            failed(WalletError(.gated, "error.42901"))
            return false
        }
        load(refresh: true)
        // 用户重试时身份暂时未知：请 App 立即核对一次（确认了就换上身份并补取）
        if deferral.isPending {
            deps.env.recheckIdentity()
        }
        return true
    }

    // MARK: - 按钮（回调带渲染时的版本与身份）

    /// 【提现】：只按摘要判断（G11）；旧数据态置灰。能不能提由 Withdraw 页的 rules 决定。
    public func withdraw(version: Int, owner: WalletOwner) {
        guard current(version, owner), state.withdrawEnabled else { return }
        open(WalletRoutes.withdraw)
    }

    public func openRecords(version: Int, owner: WalletOwner) {
        guard current(version, owner) else { return }
        open(WalletRoutes.withdrawRecords)
    }

    public func openEntry(_ route: String, version: Int, owner: WalletOwner) {
        let allowed = [WalletRoutes.orderList, WalletRoutes.ledger, WalletRoutes.riskNotice]
        guard allowed.contains(route) || (route == WalletRoutes.earnings && earningsVisible) else { return }
        guard current(version, owner) else { return }
        open(route)
    }

    /// 收益看板入口（G20）：flag 为 true 且 Earnings 在本端本版本可用（现在三端 since 都为 null，入口不显示）。
    public var earningsVisible: Bool {
        EarningsEntry.visible(flag: deps.env.earningsFlag(), routeSince: deps.env.earningsSince,
                              appVersion: deps.env.appVersion)
    }

    /// 眼睛按钮（金额隐藏，与订单页共用本机偏好）：回调带渲染时的身份。
    public func toggleMask(owner: WalletOwner) {
        guard !left, owner == state.owner else { return }
        deps.mask.toggle()
    }

    private func open(_ route: String) {
        visibility.navigated()
        deps.env.open(route, params: [:], from: page)
    }

    /// 本页的导航实例（App 在建页时给）。
    public var page: UUID?

    private func current(_ version: Int, _ owner: WalletOwner) -> Bool {
        !left && state.version == version && state.owner == owner && deps.env.isCurrent(owner)
    }

    /// 会话换代：作废在途请求，同步清掉已显示的摘要（版本加一，旧按钮回调失效）；新身份由 App 在同一处一次性取得后传入，再按新身份重取。
    public func sessionChanged(_ owner: WalletOwner) {
        guard !left else { return }
        seq += 1
        requests.cancelAll()
        deferral.reset()
        lastSuccessAt = nil
        state = WalletSnapshot(version: state.version + 1, owner: owner)
        load()
    }

    /// 页面出栈（同步出口）：作废读请求并取消传输。
    public func leave() {
        guard !left else { return }
        left = true
        seq += 1
        requests.cancelAll()
        deferral.reset()
        unsubscribe?()
        unsubscribe = nil
    }
}
