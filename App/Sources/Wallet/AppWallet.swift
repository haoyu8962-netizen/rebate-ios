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
    /// 本机时钟（测试注入）。
    var clock: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    /// 撤回同意 / 切换环境删掉钱包缓存的次数（固定身份的一部分）。
    var clearedCount = 0
    var pages: [UUID: WalletPageEntry] = [:]
    var sessionKey = ""
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
        credentialsReadable: @escaping @MainActor () -> Bool = { PrivacyWithdrawalCleanup.runner.credentialsReadable }
    ) {
        client = network.client
        router = routing.router
        self.routing = routing
        self.config = config
        cache = cleaner.store
        gates = WalletGates()
        self.mask = mask
        self.credentialsReadable = credentialsReadable
        lifetimes = WebRouteLifetimes(router: routing.router)
        let router = routing.router
        customerService = { _ in router.open(RouteRequest(route: WalletRoutes.help, from: .inApp)) }
        deps = WalletDeps(
            api: network.client, env: self, gates: gates, cache: cleaner.store, mask: mask, realname: nil, labor: nil
        )
        sessionKey = currentSessionKey()
        cache.reconcileOwner(account: currentOwner().account)
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

    /// Debug 假服务的实名与劳务协议后端（G01、G02；Release 为 nil）。
    func installBackends(realname: RealNameBackend?, labor: LaborBackend?) {
        let fresh = WalletDeps(
            api: client, env: self, gates: gates, cache: cache, mask: mask, realname: realname, labor: labor
        )
        fresh.newKey = deps.newKey
        deps = fresh
    }

    // MARK: - WalletEnv

    func currentOwner() -> WalletOwner {
        let readable = credentialsReadable()
        let network = client.currentOwnership(credentialsReadable: readable)
        let key = "\(network.account ?? "-")#\(network.generation)#\(network.epoch)#\(clearedCount)"
        return WalletOwner(
            account: readable ? network.account : nil, key: readable ? key : key + "#withdrawing",
            request: RequestOwnership(account: network.account, generation: network.generation, epoch: network.epoch)
        )
    }

    func isCurrent(_ owner: WalletOwner) -> Bool {
        credentialsReadable() && currentOwner() == owner
    }

    func configText(_ key: String) -> String? {
        configObject("texts")?[key] as? String
    }

    func helpLinks() -> [String: Any]? {
        configObject("help_links")
    }

    func earningsFlag() -> Bool? {
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
        Routes.all[WalletRoutes.earnings]?.sinceIOS
    }

    func copy(_ text: String) -> Bool {
        (writer ?? clipboard?.writer)?.write(text) ?? false
    }

    func contactService(from route: String) {
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
