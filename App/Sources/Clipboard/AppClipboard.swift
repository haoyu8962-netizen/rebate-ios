import Clipboard
import Combine
import Config
import CouliNetwork
import DesignSystem
import Foundation
import Login
import Privacy
import ProductSearch
import Router
import UIKit

/// 剪贴板识别的 App 接线（APP-07；brief §2、§3 iOS；BR-ID-16、BR-INV-04；03 §4.6）。
///
/// - 读取时机（`watcher`）：场景生命周期 `sceneActive` / `sceneBackground`（CouliApp 的 scenePhase），冷启动进入前台或经过后台再回来才算一次，
///   每次最多判定 1 次。前提由 `readState` 现取：本机已同意当前版本隐私政策、配置开关 clipboard.enabled.ios 不为 false（G05）、当前路由与
///   浮层不在敏感清单、栈顶网页容器没有经 setAutoDetect(false) 抑制（G06）；另外只在首页 Tab 根页判定（A01 同口径，提示条只在首页显示）。
/// - 判定方式（brief §3 iOS）：先比 changeCount（没变化跳过；App 自写后记下的 changeCount 也跳过），变化了才 detectPatterns；命中出商品提示条，
///   条内是系统粘贴控件。用户点了才拿到文本，再做本地分类（App 自写 hash 排除）：商品 → parse；只有邀请内容且是游客 → 邀请提示条（G07）。
///   全程不读 `.string`、不调 detectValues，不出系统「允许粘贴」弹窗。
/// - 请求归属（brief §0、共性第 2、3、4、12 条）：手动粘贴与提示条的请求绑定发起页（`currentOrigin`）与界面世代（页面被覆盖、出栈、切 Tab、
///   敏感浮层出现时在 Router 发布的同步出口加 1，回到同一页面实例也不恢复）、前台、隐私、会话世代、网络作废世代；每次等待之后在主线程全量复核，
///   网络线程只读主线程发布的不可变快照（`OwnerBox`）。进后台、撤回同意、切换账号、切换环境都同步作废提示条与在途 parse，迟到的响应只丢弃。
/// - 42901：按 Retry-After 禁用所有粘贴入口与按钮（`blocked` 置灰，执行层另在每个入口拦）。
/// - 写剪贴板只经 `writer`（先记 hash，记不上不写）；识别、提示、上传、绑定的前后都不写系统剪贴板。
@MainActor
final class AppClipboard: ObservableObject {
    static let platform = ClipboardReadPolicy.platformIOS
    static let configFlag = "clipboard.enabled.ios"
    static let homeOriginPrefix = "home:"
    static let searchRoute = "Search"
    static let productDetailRoute = "ProductDetail"
    static let loginRoute = "Login"
    /// routes.json Search.q 的 maxLength。
    static let searchQueryMax = 100
    static let lastChangeKey = "ios_change_seen"

    @Published var prompt: ClipboardPrompt?
    @Published var result: ClipboardResult?
    /// 42901 限流中：所有粘贴入口与提示条按钮置灰（执行层另拦），含登录页邀请码【粘贴】（共性第 6 条）。
    @Published var blocked = false {
        didSet {
            for paste in invitePastes.allObjects {
                paste.enabled = !blocked
            }
        }
    }

    let invitePastes = NSHashTable<LoginInvitePaste>.weakObjects()
    /// 平台购买状态（03 §7.4、APP-06a 共性第 31 条、本任务共性第 32 条；R3-01）：与搜索卡同一来源（配置 + 点击结果确认的状态），
    /// AppSearch 接线时给；nil = 不接（单测组合），卡片按原映射。配置变化时 `purchaseRevision` 加 1，多卡弹层按新状态重画。
    var purchaseSource: PurchaseStatusSource? {
        didSet {
            purchaseObservation = purchaseSource?.observePurchaseStatus { [weak self] in
                self?.purchaseRevision += 1
            }
        }
    }

    @Published private(set) var purchaseRevision = 0
    private var purchaseObservation: SearchObservation?
    /// 已播报过的结果编号（R3-02，共性第 33 条）：每个新结果播报一次；普通重绘、视图重新出现不重复播报。
    var announcedResult: Int64?
    /// 读屏播报出口（测试替换为记录）。
    var announcer: @MainActor (String) -> Void = { text in
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// 手动粘贴的 parse 在途：粘贴入口暂不可点（一次点击只读一次，H04 同口径）。
    @Published var busy = false

    /// 诊断（不含内容）：detectPatterns 次数、parse 请求次数。
    var detectCount = 0
    var parseCount = 0
    /// 诊断（不含内容）：商品粘贴入口发起系统读取的次数（首页常驻卡、SearchTyping、商品提示条共用，R2-02）。
    var readCount = 0

    let ledger: ClipboardWriteLedger
    let history: PromptHistory
    let writer: ClipboardWriter
    let seeds = ProductSeeds()
    let invitePrefill = InvitePrefill()
    private(set) lazy var watcher = ClipboardWatcher { [weak self] event, round in
        self?.evaluate(event: event, round: round)
    }

    let system: SystemClipboard
    /// 调试计数用（Debug 的诊断读写入次数）。
    var systemClipboard: SystemClipboard {
        system
    }

    let store: ClipboardHashStore
    let parser: ParseInputService
    let router: Router
    let deps: Deps
    let clock: () -> Int64

    /// 外部状态源（App 接线时给；测试替换）。
    struct Deps {
        var privacy: @MainActor () -> PrivacyState
        /// 首启弹窗 / 二次说明 / 补同意弹窗正在显示。
        var privacyPrompting: @MainActor () -> Bool
        /// 强更（below_min）：ForceUpdate 在前台。
        var forceUpdate: @MainActor () -> Bool
        /// 生效配置（JSON 文本）。
        var configJson: @MainActor () -> String
        var guest: @MainActor () -> Bool
        /// 会话世代（登录、退出、换账号时变）。
        var sessionGeneration: @MainActor () -> UInt64
        /// 网络作废世代（撤回同意、切换环境时变）。
        var networkEpoch: @MainActor () -> UInt64
        /// 服务端已判定强更（行内 10405，共性第 20、21 条）。
        var serverForced: @MainActor () -> Void = {}
        /// 整体 10405（网络层判定确需强更、不替 parse 执行）：发起页仍是当前页时由执行层进强更（AppUpdate.on10405，共性第 29 条）。
        var networkForced: @MainActor (String?) -> Void = { _ in }
    }

    // MARK: - 当前前台界面

    var path: [RouteDestination] = []
    var tab = RouteDestination(route: RoutePolicy.home)
    var homeGen: Int64 = 0
    /// 界面世代：当前前台界面每变一次、敏感浮层每出现一次都加 1，不回退（共性第 2、4 条）。
    var screenGen: Int64 = 0
    var manualGen: Int64 = 0
    var lastOrigin = ""
    var lastHomeRoot = true
    var suppressedWeb: Set<UUID> = []
    var fills: [UUID: (String) -> Void] = [:]
    var counter: Int64 = 0
    var tasks: [Int64: Task<Void, Never>] = [:]
    var subscriptions: Set<AnyCancellable> = []
    var blockUntil: Int64 = 0
    var blockTimer: Task<Void, Never>?
    /// 系统粘贴控件已点、文本还没交付的那次读取（共性第 28 条）：作废出口同步清掉，交付时不是它就丢弃。
    var reading: Int64?
    /// 登录页邀请码【粘贴】已点、文本还没交付的那次读取（R2-01）：页面被覆盖、出栈、作废出口同步清掉，回到同一登录页实例也不恢复。
    var loginReading: Int64?
    let owner = OwnerBox()
    var subscriptionsForWiring: Set<AnyCancellable> = []
    /// 敏感浮层（AuthSheet、auth_jump 执行中、购买弹层等，G12、H06）；没有为 nil。AppTrade 创建后接上。
    var overlaySource: @MainActor () -> String? = { nil }

    init(
        system: SystemClipboard,
        store: ClipboardHashStore,
        api: ParseApi,
        router: Router,
        deps: Deps,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.system = system
        self.store = store
        self.router = router
        self.deps = deps
        self.clock = clock
        ledger = ClipboardWriteLedger(store: store)
        history = PromptHistory(clock: clock, store: store)
        writer = ClipboardWriter(system: system, ledger: ledger)
        parser = ParseInputService(api: api)
        path = router.path
        tab = router.tabRoot
        lastOrigin = currentOrigin()
        // @Published 在赋值前发布新值：导航、切 Tab 的同步出口里就作废（共性第 3 条），不等界面重画。
        router.$path.sink { [weak self] next in
            MainActor.assumeIsolated { self?.pathChanged(next) }
        }.store(in: &subscriptions)
        router.$tabRoot.sink { [weak self] next in
            MainActor.assumeIsolated { self?.tabChanged(next) }
        }.store(in: &subscriptions)
        publishOwner()
    }

    // MARK: - 生命周期入口（CouliApp scenePhase）

    func sceneActive() {
        watcher.onActive()
        publishOwner()
    }

    /// 进后台：作废未点击的提示条、在途探测与 parse、结果提示；回来后按新的一次前台重新判定。
    func sceneBackground() {
        watcher.onBackground()
        invalidateAll()
    }

    // MARK: - 界面

    func pathChanged(_ next: [RouteDestination]) {
        let alive = Set(next.map(\.id))
        suppressedWeb.formIntersection(alive)
        fills = fills.filter { alive.contains($0.key) }
        seeds.retain(alive)
        // 预填只给这一次登录：登录页出栈后丢弃（G16）
        if !next.contains(where: { $0.route == Self.loginRoute }),
           path.contains(where: { $0.route == Self.loginRoute }) {
            invitePrefill.discard()
        }
        path = next
        screenChanged()
    }

    func tabChanged(_ next: RouteDestination) {
        tab = next
        screenChanged()
    }

    /// 首页 Tab 根页在前台（已同意、不在基本模式页、没有推入的页面、隐私弹窗没有显示）。
    func homeRoot() -> Bool {
        path.isEmpty && tab.route == RoutePolicy.home && deps.privacy() == .consented && !deps.privacyPrompting()
    }

    /// 当前页的标识：首页根页 = home:<世代>；推入的页面 = 路由目的地 id；其余 Tab 根页 = tab:<路由名>。
    func currentOrigin() -> String {
        if homeRoot() {
            return Self.homeOriginPrefix + String(homeGen)
        }
        if let top = path.last {
            return top.id.uuidString
        }
        return "tab:" + (tab.route ?? "")
    }

    static func isHomeOrigin(_ origin: String) -> Bool {
        origin.hasPrefix(homeOriginPrefix)
    }

    /// 隐私弹窗的显示变化等（RootView / AppRouting 通知）：重新核对当前界面。
    func screenChanged() {
        let nowHome = homeRoot()
        if lastHomeRoot, !nowHome {
            // 离开首页根页：首页世代换代（旧提示条、首页发起的在途请求一并失效），回来也不补出
            homeGen += 1
        }
        lastHomeRoot = nowHome
        if !nowHome {
            prompt = nil
        }
        let origin = currentOrigin()
        if origin != lastOrigin {
            lastOrigin = origin
            screenGen += 1
            publishOwner()
            cancelTasks()
        } else {
            publishOwner()
        }
        if let result, result.origin != origin {
            self.result = nil
        }
    }

    /// 敏感浮层出现（AuthSheet、购买弹层、auth_jump 等；AppTrade 在显示的同步出口调）：作废提示条、在途请求与结果；浮层关闭后也不恢复（共性第 4 条）。
    func sensitiveOverlayShown() {
        homeGen += 1
        screenGen += 1
        lastOrigin = currentOrigin()
        prompt = nil
        result = nil
        publishOwner()
        cancelTasks()
    }

    /// SearchTyping（路由目的地 id）登记本页搜索框的填入：30132 的【用商品名搜索】直接填进本页（A15）。
    func bindSearchFill(_ id: UUID, fill: @escaping (String) -> Void) {
        fills[id] = fill
    }

    /// 网页容器（路由目的地 id）经桥 clipboard.setAutoDetect：只对这个容器实例生效的临时抑制，容器出栈即失效；不写本机存储（G06）。
    func setWebAutoDetect(container: UUID?, enabled: Bool) {
        guard let container else { return }
        if enabled {
            suppressedWeb.remove(container)
        } else {
            suppressedWeb.insert(container)
        }
    }

    // MARK: - 自动识别

    func evaluate(event: String, round: Int64) {
        let state = readState(event: event)
        let decision = ClipboardReadPolicy.decide(platform: Self.platform, state: state)
        // 一次前台最多判定一次（共性第 1 条）：不论结果，本轮都算读过
        watcher.consume(round)
        let unchanged = decision.reasonRaw == ClipboardReadPolicy.reasonUnchanged
        guard decision.actionRaw == ClipboardReadPolicy.actionDetect || unchanged else { return }
        let count = system.changeCount
        try? store.write(Self.lastChangeKey, String(count))
        // TODO(N-30) rule-gaps A01 / I01：提示条只在首页根页显示，别的页面上回前台不探测（探测了也不会提示），回到首页不补做
        guard !unchanged, homeRoot(), !ledger.containsChangeCount(count) else { return }
        let gen = homeGen
        detectCount += 1
        system.detectLink { [weak self] hit in
            self?.detected(hit, event: event, round: round, homeGen: gen, changeCount: count)
        }
    }

    func detected(_ hit: Bool, event: String, round: Int64, homeGen gen: Int64, changeCount: Int) {
        // 等待之后复核：仍是这一轮前台、仍在首页根页、隐私仍已同意、没有敏感浮层、剪贴板没再变
        guard round == watcher.round, watcher.inForeground, gen == homeGen, homeRoot(), overlayClear(),
              system.changeCount == changeCount
        else { return }
        var state = readState(event: event)
        state.readThisForeground = false
        state.iosChangeCountChanged = true
        state.iosDetectHit = hit
        guard ClipboardReadPolicy.decide(platform: Self.platform, state: state).actionRaw
            == ClipboardReadPolicy.actionShowPrompt
        else { return }
        counter += 1
        prompt = ClipboardPrompt(id: counter)
    }

    /// 商品提示条的【关闭】：放弃（同一 changeCount 不再提示，G08 iOS 口径见 rule-gaps I02）。
    func closePrompt(_ id: Int64) {
        guard prompt?.id == id else { return }
        prompt = nil
    }

    /// 商品提示条里的系统粘贴控件被点了（UIKit 同步调接收方的那一刻）：核对仍是当前提示条、仍在首页根页、没被限流，绑定点击时的票据；
    /// 返回系统稍后交付文本时的回调（交付时复核票据，失效即丢弃，共性第 28 条）。nil = 这次点击不读。
    func beginPromptPaste(_ id: Int64) -> PasteDelivery? {
        // 与首页常驻卡、SearchTyping 共享在途保护（R2-02）：读取或 parse 在途时不再发起第二次读取
        guard prompt?.id == id, !busy else { return nil }
        prompt = nil
        guard watcher.inForeground, homeRoot(), overlayClear(), !blockActive else { return nil }
        return startRead(entry: ManualPasteAction.entryHome)
    }

    /// 商品提示条的粘贴控件此刻可用（界面置灰用；执行层另在 beginPromptPaste 拦）：没有限流、没有在途读取或 parse。
    var promptPasteEnabled: Bool {
        !blocked && !busy
    }

    /// 点击与交付在同一时刻（测试与同步调用方）。
    func promptPasted(_ id: Int64, text: String?) {
        beginPromptPaste(id)?(text)
    }

    // MARK: - 归属快照（网络线程只读它）

    func publishOwner() {
        owner.set(OwnerBox.Snapshot(
            manual: manualGen, screen: screenGen, origin: currentOrigin(),
            foreground: watcher.inForeground, overlayClear: overlayClear(),
            consented: deps.privacy() == .consented
        ))
    }
}
