import Foundation

/// 一个能力的结果：成功带 data（缺省 {}），失败带桥错误码。data 是只读的 JSON 对象（创建后不再修改）。
public struct BridgeOutcome: @unchecked Sendable {
    public let code: Int
    public let data: [String: Any]?

    public static func ok(_ data: [String: Any] = [:]) -> BridgeOutcome {
        BridgeOutcome(code: BridgeCode.ok, data: data)
    }

    public static func fail(_ code: Int) -> BridgeOutcome {
        BridgeOutcome(code: code, data: nil)
    }
}

/// 强更状态（03 §4.4 统一入口守卫的四种状态；检查中由宿主最多等 5 秒，到时按未知）。
public enum BridgeUpdateState {
    public static let supported = "supported"
    public static let checking = "checking"
    public static let unknown = "unknown"
    public static let below = "below"
}

/// 每次调用开始时取的调用方状态。
/// - privacy：`BridgePrivacy`。
/// - accountKey：当前会话的归属键（账号 + 会话世代；游客、隔离中为 nil）；调用结束时变了，结果不交回页面。同一账号退出后重新登录
///   也是新世代（APP-04 三端共性第 15 条）。
/// - update：`BridgeUpdateState`。
/// - fromForceUpdatePage：容器是从强更页打开的（隐私政策等）：低于最低版本时只读方法照常（03 §4.4 状态表）。
public struct BridgeCallerState: Sendable, Equatable {
    public let privacy: String
    public let accountKey: String?
    public let update: String
    public let fromForceUpdatePage: Bool

    public init(privacy: String, accountKey: String?, update: String, fromForceUpdatePage: Bool = false) {
        self.privacy = privacy
        self.accountKey = accountKey
        self.update = update
        self.fromForceUpdatePage = fromForceUpdatePage
    }

    /// 协议准入用的登录状态：只看有没有会话归属键（不另设可改写的登录标志，APP-04 三端共性第 2 条）。
    public var loggedIn: Bool {
        accountKey != nil
    }
}

/// 业务能力（App 实现：Router、ApiClient、Tracker、PermissionRequester 等）。没有接上的能力返回 90001，不臆造实现。
/// 全部在主线程调用。
@MainActor
public protocol BridgeServices: AnyObject {
    /// app.getEnv 的 result（不含任何「审核中」「隐藏返利」类标记）。
    func env() -> [String: Any]
    /// app.getConfig：只返回给 H5 白名单里的键。
    func config(keys: [String]) -> BridgeOutcome
    /// 以下三个经 ApiClient 发请求的能力都带上调用有效性（`validity`），请求在等待结束、重试、真正发出之前都要核对它
    /// （APP-04 三端共性第 22 条）。
    func user(validity: BridgeCallValidity) async -> BridgeOutcome
    /// auth.getH5Token：readOnly 时只申请只读作用域（强更检查不是 OK / 低于推荐，BR-ID-32 细则「只读作用域」）；令牌不缓存。
    func h5Token(readOnly: Bool, validity: BridgeCallValidity) async -> BridgeOutcome
    func login() async -> BridgeOutcome
    /// net.signedRequest：已过 signed_paths 白名单；原生签名代发。bodyJson 是 H5 给的 body 原样序列化的 JSON（没有时为 nil）。
    func signedRequest(
        method: String,
        path: String,
        bodyJson: String?,
        validity: BridgeCallValidity
    ) async -> BridgeOutcome
    /// nav.open：经 Router（in_app 入口）；readOnlyPagesOnly = 强更未知，只开只读页面，开不了以 90500 结束。
    func navOpen(route: String, paramsJson: String, readOnlyPagesOnly: Bool) async -> BridgeOutcome
    func clipboardWrite(text: String) -> BridgeOutcome
    func clipboardRead() async -> BridgeOutcome
    func setClipboardAutoDetect(enabled: Bool) -> BridgeOutcome
    func pushStatus() async -> BridgeOutcome
    /// perm.request：只走 PermissionRequester；isStillValid 一路传进去，出队、说明结束、调系统接口前各查一次（三端共性第 14 条）。
    func requestPermission(type: String, isStillValid: @escaping @MainActor () -> Bool) async -> BridgeOutcome
    /// track.event：只接受 Tracker 生成函数白名单里的事件；不在白名单的丢弃（不报错，TODO(N-22)）。
    func track(name: String) -> BridgeOutcome
    /// 被拒的调用记埋点 bridge_call（只记契约方法名与错误码）。
    func reportRejected(method: String, code: Int)
}

/// 容器自身的界面能力（TrustedWebView 实现）。
@MainActor
public protocol BridgeUI: AnyObject {
    func toast(text: String, long: Bool)
    func showLoading(text: String?)
    func hideLoading()
    /// 应用标题栏设置。全部字段都生效才返回 true；有本端做不到的字段时什么都不改、返回 false（宿主回 90001，三端共性第 23 条）。
    func setNavBar(_ bar: BridgeNavBar) -> Bool
    func close()
}

/// BridgeHost（03 §5.3）：信封 → 协议准入（`BridgeProtocol.decide`）→ 能力是否在本端提供 → 强更守卫 → 分派到能力实现 → 标准响应。
///
/// - 在途 id：与仍在处理中的调用相同的 id，后到的那次 90002、不执行（03 §5.3「信封 id」）。
/// - 本端提供的方法见 `implemented`；契约里有、since.ios 为 null 或本任务不实现的（trade.*、share.open、media.*、ext.*、cs.open）
///   在协议准入通过后返回 90001（编排者三端裁定：先协议判定再 90001；TODO 见 `notImplementedTasks`）。
/// - 强更守卫（03 §4.4「未知状态下的桥调用」）：检查中最多等 5 秒按未知；未知时只读方法照常、nav.open 只开只读页面、其余 90500；
///   低于最低版本时全部 90500（从强更页进入的页面里只读方法照常）。被拒的调用不排队、不补执行。
/// - 异步方法按契约 timeout_ms 结束（90003）。
/// - 归属（APP-04 三端共性第 4 条）：每次调用开始时记下宿主世代与调用方状态；等待之后、执行之前再核对一次；`invalidate`（撤回同意、
///   切换环境、容器销毁、页面换了文档）让世代加一并取消在途调用，晚到的结果一律不交回（回 90500）；账号变了同样不交回。
@MainActor
public final class BridgeHost {
    /// 本任务实现的方法（APP-04 任务书 §2.2）。
    public static let implemented: Set<String> = [
        "app.getEnv", "app.getConfig", "auth.getUser", "auth.getH5Token", "auth.login", "net.signedRequest",
        "ui.toast", "ui.showLoading", "ui.hideLoading", "ui.setNavBar", "nav.open", "nav.close",
        "clipboard.write", "clipboard.read", "clipboard.setAutoDetect", "perm.getPushStatus", "perm.request",
        "track.event",
    ]

    /// 本任务不实现、准入通过后返回 90001 的方法与负责的任务（不臆造实现）：
    /// TODO(APP-07) trade.openProduct、trade.convertAndOpen、trade.authorize、ext.openApp（TradeJump 与授权）；
    /// TODO(APP-13) share.open、media.saveImage、media.previewImage（分享与图片）；TODO(APP-14) ext.openBrowser、cs.open；
    /// P1：trade.openUnionActivity、ext.openMiniProgram、media.scan、media.uploadImage（since 全为 null，不声明）。
    public static let notImplementedTasks: [String: String] = [
        "trade.openProduct": "APP-07", "trade.convertAndOpen": "APP-07", "trade.authorize": "APP-07",
        "ext.openApp": "APP-07", "share.open": "APP-13", "media.saveImage": "APP-13",
        "media.previewImage": "APP-13", "ext.openBrowser": "APP-14", "cs.open": "APP-14",
    ]

    /// 强更未知时照常执行的只读方法（03 §4.4「未知状态下的桥调用」第一类）。
    public static let readOnlyMethods: Set<String> = [
        "app.getEnv", "app.getConfig", "auth.getUser", "auth.getH5Token", "ui.toast", "ui.showLoading",
        "ui.hideLoading", "ui.setNavBar", "nav.close", "media.previewImage", "clipboard.write", "clipboard.read",
        "clipboard.setAutoDetect", "perm.getPushStatus", "track.event",
    ]

    /// 第二类：只打开只读页面。
    public static let openPageMethods: Set<String> = ["nav.open", "trade.openProduct"]

    private struct Call {
        let token: UUID
        let method: String
        var generation: UInt64
        let state: BridgeCallerState
        let reply: @MainActor (String?) -> Void
        let validity: BridgeCallValidity
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }

    private let protocolProvider: @MainActor () -> BridgeProtocol
    private let caller: @MainActor () -> BridgeCallerState
    /// 业务能力（强引用；它不持有容器）。界面能力是容器自己，弱引用（容器持有本宿主）。
    let services: any BridgeServices
    weak var ui: (any BridgeUI)?
    private let awaitUpdate: @MainActor () async -> String
    private var generation: UInt64 = 0
    private var inFlight: [String: Call] = [:]
    private var disposed = false
    /// 正在同步执行导航（nav.open 经 Router）的那次调用的有效性（三端共性第 43 条）。导航本身可能让本容器出栈
    /// （nav.open(Home) 清栈 → teardown → `invalidate`），这次调用不在作废之列，导航完成后按自己的结果结算。
    private var navigating: ObjectIdentifier?

    public init(
        protocol protocolProvider: @escaping @MainActor () -> BridgeProtocol,
        caller: @escaping @MainActor () -> BridgeCallerState,
        services: any BridgeServices,
        ui: any BridgeUI,
        awaitUpdate: @escaping @MainActor () async -> String
    ) {
        self.protocolProvider = protocolProvider
        self.caller = caller
        self.services = services
        self.ui = ui
        self.awaitUpdate = awaitUpdate
    }

    /// 本端声明给 H5 的方法（`__REBATE_BRIDGE__.methods`）：契约里 since.ios 不为 null 的方法。
    public var declaredMethods: [String] {
        BridgeProtocol.declaredMethods
    }

    public var bridgeVersion: Int {
        BridgeProtocol.contractVersion
    }

    /// 在途调用数（测试与调试用）。
    public var inFlightCount: Int {
        inFlight.count
    }

    /// origin 是否为当前可信源（判定口径同 `BridgeProtocol.decide`）。
    public func acceptsOrigin(_ origin: String) -> Bool {
        protocolProvider().isTrustedOrigin(origin)
    }

    /// 处理一条 H5 消息。`reply` 恰好调用一次：标准响应体；信封里没有合法 id 时无法配对，回 nil。
    /// origin、isMainFrame 来自传输层（WKFrameInfo，不是页面自报），userGesture 来自原生记录的点击。
    public func handle(
        raw: String,
        origin: String,
        isMainFrame: Bool,
        userGesture: Bool,
        reply: @escaping @MainActor (String?) -> Void
    ) {
        let envelope = BridgeProtocol.parseStructure(raw: raw)
        guard let id = envelope.id else {
            reply(nil)
            return
        }
        guard !disposed else {
            reply(BridgeProtocol.response(id: id, code: BridgeCode.nativeError))
            return
        }
        // 重复的在途 id（三端共性第 19 条）：后到的这次直接 90002，不判定、不执行，也不覆盖原来那条待回应的调用。
        guard inFlight[id] == nil else {
            reply(BridgeProtocol.response(id: id, code: BridgeCode.invalidParams))
            return
        }
        guard envelope.structureValid, let method = envelope.method else {
            reply(BridgeProtocol.response(id: id, code: BridgeCode.invalidParams))
            return
        }
        let state = caller()
        let params = envelope.params ?? [:]
        let ctx = BridgeContext(
            method: method, origin: origin, isMainFrame: isMainFrame, userGesture: userGesture,
            privacy: state.privacy, loggedIn: state.loggedIn, params: params
        )
        let decision = protocolProvider().decide(ctx: ctx)
        guard decision.allow else {
            let code = decision.errorCode ?? BridgeCode.notAllowed
            reject(method: method, code: code) {
                reply(BridgeProtocol.response(id: id, code: code))
            }
            return
        }
        guard let contract = BridgeContract.shared.methods[method], contract.sinceIOS != nil,
              Self.implemented.contains(method)
        else {
            reject(method: method, code: BridgeCode.notSupported) {
                reply(BridgeProtocol.response(id: id, code: BridgeCode.notSupported))
            }
            return
        }
        start(id: id, contract: contract, params: BridgeParams(raw: params), state: state, reply: reply)
    }

    /// 撤回同意、切换环境、容器销毁或页面换了文档：作废并取消全部在途调用（各回 90500，不让页面一直等）。
    ///
    /// 例外（三端共性第 43 条）：发起这次出栈的导航调用（`performNavigation` 里）不作废，改记到新世代上，等导航返回后
    /// 按自己的结果结算（成功回 code=0）；其他在途调用照常立即作废。
    public func invalidate() {
        generation &+= 1
        var calls = inFlight
        inFlight.removeAll()
        if let navigating, let entry = calls.first(where: { ObjectIdentifier($0.value.validity) == navigating }) {
            var survivor = entry.value
            survivor.generation = generation
            inFlight[entry.key] = survivor
            calls[entry.key] = nil
        }
        for (id, call) in calls {
            call.validity.revoke()
            call.work?.cancel()
            call.timer?.cancel()
            call.reply(BridgeProtocol.response(id: id, code: BridgeCode.nativeError))
        }
    }

    /// 容器销毁：取消全部调用，之后不再接受新调用。
    public func dispose() {
        invalidate()
        disposed = true
    }

    // MARK: - 执行与结算

    private func reject(method: String, code: Int, reply: () -> Void) {
        if BridgeProtocol.isContractMethod(method) {
            services.reportRejected(method: method, code: code)
        }
        reply()
    }

    private func start(
        id: String,
        contract: BridgeMethodContract,
        params: BridgeParams,
        state: BridgeCallerState,
        reply: @escaping @MainActor (String?) -> Void
    ) {
        let token = UUID()
        let started = generation
        let validity = BridgeCallValidity()
        var call = Call(
            token: token, method: contract.name, generation: started, state: state, reply: reply, validity: validity
        )
        // 两个任务都在主线程上、本函数返回之后才开始执行，登记总在它们之前完成。
        call.work = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await run(
                contract: contract, params: params, state: state, generation: started, validity: validity
            )
            settle(id: id, token: token, outcome: outcome)
        }
        if contract.model == BridgeMethodContract.asyncModel, let timeout = contract.timeoutMs {
            call.timer = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)
                guard !Task.isCancelled else { return }
                self?.settle(id: id, token: token, outcome: .fail(BridgeCode.timeout))
            }
        }
        inFlight[id] = call
    }

    /// 结算一次调用：只结算自己的登记（invalidate 之后同一个 id 可能已被新的调用占用）；世代与账号都没变才交回结果，否则 90500。
    private func settle(id: String, token: UUID, outcome: BridgeOutcome) {
        guard let call = inFlight[id], call.token == token else { return }
        inFlight[id] = nil
        call.validity.revoke()
        call.work?.cancel()
        call.timer?.cancel()
        let owned = call.generation == generation && caller().accountKey == call.state.accountKey
        guard owned else {
            call.reply(BridgeProtocol.response(id: id, code: BridgeCode.nativeError))
            return
        }
        if outcome.code == BridgeCode.ok {
            call.reply(BridgeProtocol.response(id: id, code: BridgeCode.ok, data: outcome.data ?? [:]))
        } else {
            reject(method: call.method, code: outcome.code) {
                call.reply(BridgeProtocol.response(id: id, code: outcome.code))
            }
        }
    }

    private func run(
        contract: BridgeMethodContract,
        params: BridgeParams,
        state: BridgeCallerState,
        generation started: UInt64,
        validity: BridgeCallValidity
    ) async -> BridgeOutcome {
        let update = state.update == BridgeUpdateState.checking ? await awaitUpdate() : state.update
        // 等待之后、执行任何副作用之前再核对一次归属（APP-04 三端共性第 4 条）：宿主世代（撤回同意、切换环境、页面换文档、容器销毁）、
        // 隐私状态与账号都没变才执行；变了就不执行，以 90500 结束（不排队、不补执行）。
        guard !Task.isCancelled, stillOwned(generation: started, state: state) else {
            return .fail(BridgeCode.nativeError)
        }
        if let code = Self.updateGuard(
            method: contract.name,
            update: update,
            fromForceUpdatePage: state.fromForceUpdatePage
        ) {
            return .fail(code)
        }
        return await dispatch(
            contract.name, params.raw, readOnlyMode: update != BridgeUpdateState.supported,
            owner: BridgeCallOwner(generation: started, state: state, validity: validity)
        )
    }

    /// 同步执行一次导航（nav.open）：执行期间本调用不被 `invalidate` 作废（导航让本容器出栈时，先按结果结算这次调用）。
    /// 能力实现里的 Router 调用是同步的（不跨挂起点），标记只覆盖这段同步执行。
    func performNavigation(
        _ owner: BridgeCallOwner,
        _ body: @MainActor () async -> BridgeOutcome
    ) async -> BridgeOutcome {
        navigating = ObjectIdentifier(owner.validity)
        defer { navigating = nil }
        return await body()
    }

    func stillOwned(generation started: UInt64, state: BridgeCallerState) -> Bool {
        let now = caller()
        return started == generation && now.privacy == state.privacy && now.accountKey == state.accountKey
    }

    /// 强更守卫（03 §4.4）：返回不执行时的错误码；照常执行为 nil。
    static func updateGuard(method: String, update: String, fromForceUpdatePage: Bool) -> Int? {
        switch update {
        case BridgeUpdateState.supported:
            nil
        case BridgeUpdateState.below:
            fromForceUpdatePage && readOnlyMethods.contains(method) ? nil : BridgeCode.nativeError
        default:
            // 未知（含检查中等满 5 秒）：只读方法照常，打开页面类只开只读页面（在分派里），其余 90500。
            readOnlyMethods.contains(method) || openPageMethods.contains(method) ? nil : BridgeCode.nativeError
        }
    }
}

/// 已校验的 params（只读，跨越一次 Task 边界用）。
struct BridgeParams: @unchecked Sendable {
    let raw: [String: Any]
}

/// 一次调用的归属：开始时的宿主世代、调用方状态与有效性。
struct BridgeCallOwner {
    let generation: UInt64
    let state: BridgeCallerState
    let validity: BridgeCallValidity
}
