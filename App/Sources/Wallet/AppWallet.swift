import Clipboard
import Combine
import CouliNetwork
import Foundation
import Generated
import OrderCore
import Privacy
import Router
import Wallet
import WalletCore

/// App 侧的钱包（APP-09）：
/// - 网络经 ApiClient（读请求带页面归属与固定身份；提交、确认、放弃走未决键管线）；Router 打开 Withdraw、WithdrawRecords、Ledger（h5）、
///   Earnings（h5，G20）、RealName、PayoutAccount、LaborAgreement、Help、RiskNotice、BindPhone、OrderList、Login；
/// - 交易流水号复制只经 APP-07 的统一写入口（AppClipboard.writer）；10405 由网络层进已有的强更分流；
/// - 会话换代（登录、退出、换账号、会话失效）、撤回同意、切换环境时同步：禁用期整体重置、内存里的 step-up token 清空、发码倒计时清空、
///   实名结论作废、缓存归属不一致的删除；栈里每个钱包类页面清掉已显示的余额、金额与已填内容，换上同一次读取的新身份后按新会话重取
///   （APP-09 共性第 13 条：保留页面、清空重建）。未决记录本身按账号保留在 PendingKeyStore；
/// - 实名状态（守卫 realnameVerified 的来源，iOS I02）：要实名的资金页在本会话还没查过时先取 GET /v1/me 再打开；实名成功后再取一次；
/// - 资金与实名四页带参数打开时，Router 丢弃全部参数照常打开，这里记 route_params_dropped（只有路由名与个数，AC-S1-81 ⑫）；
/// - 页面可见性（共性第 37、41、47、57 条）：只看 Router 栈顶与场景是否在前台。
@MainActor
final class AppWallet: ObservableObject, WalletEnv {
    let client: ApiClient
    let api: WalletApi
    let router: Router
    let routing: AppRouting
    let config: AppConfig
    let cache: WalletCacheStore
    let gates: WalletGates
    let mask: AmountMaskStore
    let lifetimes: WebRouteLifetimes
    private(set) var deps: WalletDeps!
    /// 剪贴板的统一写入口（APP-07）；nil = 没接（复制提示失败，不写剪贴板）。
    weak var clipboard: AppClipboard?
    /// 统一写入口的替身（测试注入同一个 ClipboardWriter 实现与假系统剪贴板）；nil = 用 `clipboard.writer`。
    var writer: ClipboardWriter?
    /// 埋点（route_params_dropped）。
    var track: (TrackEvent) -> Void = { _ in }
    /// 二次验证发码的号码（G31）：Release 恒为 nil（本机不保存手机号，iOS I01）；Debug 假服务给测试号。
    var phoneProvider: (String) -> String? = { _ in nil }
    /// 统一客服出口（APP-12 接上 AppMe.cs；接入前经 Router 打开 Help，同 APP-08 G09）。
    var customerService: (String) -> Void
    /// getMe 的共享读取截止时间（APP-12 MeGates.read；实名查询与「我的」、桥 auth.getUser 共用，双向生效）。nil = 没接。
    var meReadGate: RetryAfterGate?
    /// 撤回同意的清理已完成、会话凭据可读（生产为 `PrivacyWithdrawalCleanup.runner`；测试注入）。
    let credentialsReadable: @MainActor () -> Bool
    /// 测试注入（FU-IOS-0712 第 2 轮修复 R2-02）：身份核对通过之后、调用方继续执行之前调用（确定性交错：在这里同账号重登）。生产为 nil。
    var identityCheckPassed: (@MainActor () -> Void)?
    /// 本机时钟（测试注入）。
    var clock: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    /// 撤回同意 / 切换环境删掉钱包缓存的次数（固定身份的一部分）。
    var clearedCount = 0
    var pages: [UUID: WalletPageEntry] = [:]
    /// 唯一的身份快照入口（与订单同一口径；FU-IOS-0712 整体重理）。建页期间钉住一份（执行器固定身份与「是否已确认」同一次读取）。
    let identity: AppIdentity
    /// 换代判据（结论只由它给出；启动时身份暂时未知不记判据，RC-04）。
    let reconciler: SessionReconciler
    var sceneActive = true
    /// 本页可见性每变一次加一（实名查询后的导航许可，共性第 57 条）。
    var visibleGen: [UUID: Int] = [:]
    var lastVisible: [UUID: Bool] = [:]
    var navGeneration = 0
    var realnameState: (key: String, verified: Bool)?
    var realnameSerial = 0
    var realnameFlag: RequestFlag?
    var errorSerial = 0
    private var subscriptions: Set<AnyCancellable> = []

    init(
        network: AppNetwork, config: AppConfig, routing: AppRouting, login: AppLogin, mask: AmountMaskStore,
        cleaner: WalletCacheCleaner = .shared,
        credentialsReadable: @escaping @MainActor () -> Bool = { PrivacyWithdrawalCleanup.runner.credentialsReadable },
        api: WalletApi? = nil
    ) {
        client = network.client
        self.api = api ?? network.client
        router = routing.router
        self.routing = routing
        self.config = config
        cache = cleaner.store
        gates = WalletGates()
        self.mask = mask
        self.credentialsReadable = credentialsReadable
        let identity = AppIdentity(client: network.client, credentialsReadable: credentialsReadable)
        self.identity = identity
        // 判据与启动对账用同一次身份快照（RC-03）；启动时身份暂时未知不记判据（RC-04），首次确认时按结论处理
        let snapshot = identity.snapshot()
        reconciler = SessionReconciler(snapshot)
        lifetimes = WebRouteLifetimes(router: routing.router)
        let router = routing.router
        customerService = { _ in router.open(RouteRequest(route: WalletRoutes.help, from: .inApp)) }
        // 实名提交走契约（D10-856 ②）；劳务协议仍是 G02 待定接口（nil）。Debug 假登录模式与测试经 installBackends 替换
        let realname = ApiRealNameBackend(api: self.api, gate: gates.realname) { [weak self] in
            self?.idVerificationConsentVersion() ?? 1
        }
        deps = WalletDeps(
            api: self.api, env: self, gates: gates, cache: cleaner.store, mask: mask, realname: realname, labor: nil
        )
        // 摘要与金额草稿按「账号 + 持久化登录世代」分区（FU-IOS-0712）：世代与会话可用性同口径，未知不读不写；世代只取执行器构造时
        // 固定的那一份（WalletOwner.loginEpoch，R1-01），存储不读当前世代
        cleaner.store.partitionedByLoginEpoch = true
        reconcileCache(snapshot)
        routing.realnameSource = { [weak self] in self?.realnameVerified() ?? false }
        router.onParamsDropped = { [weak self] route, count in self?.paramsDropped(route, count: count) }
        login.$sessionVersion.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSession() }
        }.store(in: &subscriptions)
        router.$path.sink { [weak self] path in
            MainActor.assumeIsolated { self?.pathChanged(path) }
        }.store(in: &subscriptions)
        cleaner.onCleared = { [weak self] in self?.cacheCleared() }
    }

    /// 换实名与劳务协议后端（Debug 假服务、测试替身；`realname: nil` = 实名「暂未开放」）。生产默认：实名为 ApiRealNameBackend，劳务为 nil（G02）。
    func installBackends(realname: RealNameBackend?, labor: LaborBackend?) {
        let fresh = WalletDeps(
            api: api, env: self, gates: gates, cache: cache, mask: mask, realname: realname, labor: labor
        )
        fresh.newKey = deps.newKey
        deps = fresh
    }

    // MARK: - WalletEnv

    /// 持久化登录世代与账号、会话世代同一次读出（`currentIdentity`，R1-01）：摘要与金额草稿的分区只用这一份。建页期间返回建页那一份快照。
    func currentOwner() -> WalletOwner {
        owner(for: identity.snapshot())
    }

    /// 按一次快照构造的固定身份（账号、版本串、网络归属、登录世代与是否已确认同一次读取）。
    func owner(for snapshot: IdentitySnapshot) -> WalletOwner {
        WalletOwner(
            account: snapshot.account,
            key: AppIdentity.ownerKey(account: snapshot.account, snapshot, cleared: clearedCount),
            request: snapshot.request, loginEpoch: snapshot.loginEpoch, identityKnown: snapshot.known
        )
    }

    /// 缓存归属对账（启动、启动态落定、换代、撤回 / 切环境）：只用调用方这一次快照（不另读，RC-03）。待清理先完成（R3-02）；身份暂时
    /// 未知延后（R2-01）；确认没有会话照旧删除；缺登录世代的旧会话不删也不读写（F-X-21）。
    func reconcileCache(_ snapshot: IdentitySnapshot) {
        cache.completePendingClear()
        guard snapshot.known else { return }
        cache.reconcileOwner(account: snapshot.account, loginEpoch: snapshot.loginEpoch)
    }

    func isCurrent(_ owner: WalletOwner) -> Bool {
        check(owner) == .current
    }

    /// 固定身份与此刻身份的核对（一次读取；口径见 `AppIdentity.check`，与订单相同）。
    func check(_ owner: WalletOwner) -> IdentityCheck {
        let now = identity.snapshot()
        let result = AppIdentity.check(
            matchesNow: self.owner(for: now) == owner,
            fixed: FixedIdentity(key: owner.key, account: owner.account, known: owner.identityKnown),
            now: now, cleared: clearedCount
        )
        if result == .current {
            identityCheckPassed?()
        }
        return result
    }

    /// 页面在身份暂时未知时被用户点了【重试】：立即核对一次。
    func recheckIdentity() {
        checkSession()
    }

    func configText(_ key: String) -> String? {
        configObject("texts")?[key] as? String
    }

    func helpLinks() -> [String: Any]? {
        configObject("help_links")
    }

    func earningsFlag() -> Bool? {
        #if DEBUG
        // APP-09v-a：WalletEarningsEntry 画板的 UI 测试（COULI_FAKE_WALLET_VISUAL earnings:true）；生产不变
        if DebugWalletVisual.earnings {
            return true
        }
        #endif
        let flags = configObject("features")?["flags"] as? [String: Any]
        guard let number = flags?[EarningsEntry.flagKey] as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    var appVersion: String {
        AppRouting.appVersion.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
    }

    var earningsSince: String? {
        #if DEBUG
        if DebugWalletVisual.earnings {
            return "1.0.0"
        }
        #endif
        return Routes.all[WalletRoutes.earnings]?.sinceIOS
    }

    func copy(_ text: String) -> Bool {
        #if DEBUG
        DebugWalletLog.copy(text)
        #endif
        return (writer ?? clipboard?.writer)?.write(text) ?? false
    }

    func contactService(from route: String) {
        #if DEBUG
        DebugWalletLog.contact(route)
        #endif
        customerService(route)
    }

    func stepUpPhone(account: String) -> String? {
        phoneProvider(account)
    }

    func markWalletDirty(_ owner: WalletOwner) {
        deps.walletDirty.send(owner)
    }

    func realnameChanged() {
        refreshRealname(nil)
    }

    /// 实名提交成功：固定身份仍是当前会话才按已实名记下（换号后到达的结果不给新账号），再复查 GET /v1/me（复查失败保持已实名）。
    func realnameSubmitted(_ owner: WalletOwner) {
        guard isCurrent(owner) else { return }
        realnameState = (owner.key, true)
        refreshRealname(nil)
    }

    /// 实名单独同意的 version（D10-887 ①）：/v1/config.legal.privacy.version；取不到用本机已同意的隐私政策版本，再取不到用包内默认配置。
    func idVerificationConsentVersion() -> Int {
        let legal = configObject("legal")
        if let version = ((legal?["privacy"] as? [String: Any])?["version"] as? NSNumber)?.intValue, version >= 1 {
            return version
        }
        if let consented = routing.privacy.consentedVersion, consented >= 1 {
            return consented
        }
        let bundled = DefaultConfig.json.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let privacy = (bundled?["legal"] as? [String: Any])?["privacy"] as? [String: Any]
        return max(1, (privacy?["version"] as? NSNumber)?.intValue ?? 1)
    }

    func sensitiveOverlay(_ showing: Bool) {
        if showing {
            clipboard?.sensitiveOverlayShown()
        }
    }

    func nowMillis() -> Int64 {
        clock()
    }

    func displayNowMillis() -> Int64 {
        client.calibratedNowMillis
    }

    private func configObject(_ key: String) -> [String: Any]? {
        guard let text = config.store.value(key: key), let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func paramsDropped(_ route: String, count: Int) {
        guard FundRouteParams.filtered(route: route, paramCount: count).event != nil,
              let value = TrackerEvents.RouteParamsDropped.RouteValue(rawValue: route)
        else { return }
        track(TrackerEvents.routeParamsDropped(page: route, route: value, droppedCount: count))
    }
}
