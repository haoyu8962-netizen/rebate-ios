import Combine
import CouliNetwork
import Foundation
import TradeJump

/// 授权管理的一行（BR-ID-17 细则「授权管理页」）。
public struct AuthManageRow: Equatable, Sendable {
    public let platform: String
    /// 只有两种文案：active 已授权，其余未授权（失效不另写「已失效」）。
    public var authorized: Bool
    /// blocked 且用户未被封禁：不给【去授权】，行下方 error.30153 +【联系客服】（AuthManageBlocked）。
    public var blocked: Bool

    /// 【去授权】只给未授权、未停用的行。
    public var canAuthorize: Bool {
        !authorized && !blocked
    }
}

/// 授权管理页的阶段。
public enum AuthManagePhase: String, Sendable {
    case loading
    case content
    case error
}

/// 授权管理页状态。
public struct AuthManageState {
    public var phase: AuthManagePhase = .loading
    public var rows: [AuthManageRow] = []
    public var busyPlatform: String?
    /// 列表加载失败的文案键（按实际错误映射，共性第 23 条）：42901 → error.42901，5xxxx → 对应错误，传输失败 → 网络错误。
    public var errorKey: String?
    /// 列表加载失败要展示的 trace（只有 5xxxx 带 trace6；其余为 nil）。
    public var errorTraceId: String?
    public var toast: PurchaseToast?
    /// 42901 限时禁用（Retry-After，缺省 5 秒）：列表【重试】与【去授权】都不可点，到期自动恢复（共性第 11 条）。
    public var rateLimited = false

    public init() {}
}

/// 授权管理执行器（APP-06b；BR-ID-17 细则「授权管理页」、BR-ID-22，routes.json AuthManage）：
/// - 只列淘宝、拼多多（京东不需要用户授权，不列）；listUnionBindings 的 active → 已授权；unbound / pending_auth / invalid / released →
///   未授权 +【去授权】；blocked → 未授权、不给【去授权】，显示 error.30153 +【联系客服】；
/// - 进入页面不自动发起授权（共性第 14 条）；【去授权】只能由用户在 App 内点击发起：getUnionAuthUrl → 淘宝按 auth_methods 取本端能执行的
///   第一种（bindings 每次新键；30104 按 reason 重新取授权上下文并换方式，TaobaoAuthFlow），拼多多执行 auth_jump（不上报 link_jump；
///   只在前台继续下一步，共性第 25 条），回到前台后刷新本页；本页发起的授权不重放任何 open；
/// - auth-url 返回 30153 → 该行改为停用（只给联系客服）；30101 / 30102 auth_unavailable → 只提示；
/// - 不提供改绑、解绑；不显示任何账号名、昵称、头像或授权时间。
@MainActor
public final class AuthManageController: ObservableObject {
    /// 授权管理页列出的平台（需要用户授权的：淘宝、拼多多；京东不列，BR-ID-22）。
    public static let platforms = ["taobao", "pdd"]
    public static let genericKey = "error.50001"
    public static let authFailedKey = "error.30104.credential_invalid"
    public static let networkKey = "buy.timeout"
    static let group = "manage"

    @Published public internal(set) var state = AuthManageState()

    private let calls: TradeCalls
    private let executor: TradeJumpExecutor
    private let ports: JumpPorts
    private let webCode: WebCodeAuthorizer
    private let baichuan: BaichuanAdapter
    private let keyGenerator: () -> String
    private let gate: TradeRetryGate
    private var left = false
    private var generation = 0
    /// 授权世代：每次点【去授权】加 1，离开时加 1（旧授权流程的结果只丢弃）。
    private var authGen = 0
    private var awaitingReturn = false
    private var foreground = true
    /// 用户点【去授权】发出的授权许可（进入后台即撤销，共性第 31 条）。
    private var authPermit = false
    private var backgroundCount = 0
    private var toastSeq = 0
    /// 页面构造时**一次**固定的请求归属（APP-08 iOS 第五次修复，APP-09 共性第 65 条）：加载、取授权地址、淘宝绑定与 30104 恢复都带着它
    /// 交网络层比较；之后换了账号 / 会话 / 环境的旧页面零发送（本地按不一致结束，显示网络错误），不把请求重新绑定到当前会话。nil = 不比较。
    private let ownership: RequestOwnership?
    /// 构造时的归属此刻仍是当前的（APP-08 iOS r3f NEW-04）：持有者给，只比较（会话世代、作废世代），不读令牌、不赋值。nil = 不比较。
    private let stillOwned: (@MainActor () -> Bool)?
    /// 已因会话变化作废（r3f NEW-04）：A 的授权状态已清空，之后的迟到响应零展示、零外跳，本页不再发请求（要重进）。
    public private(set) var revoked = false

    public init(
        api: TradeApi,
        executor: TradeJumpExecutor,
        ports: JumpPorts,
        webCode: WebCodeAuthorizer,
        baichuan: BaichuanAdapter,
        keyGenerator: @escaping () -> String = { UUID().uuidString.lowercased() },
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        ownership: RequestOwnership? = nil,
        stillOwned: (@MainActor () -> Bool)? = nil
    ) {
        self.ownership = ownership
        self.stillOwned = stillOwned
        calls = TradeCalls(api: api)
        self.executor = executor
        self.ports = ports
        self.webCode = webCode
        self.baichuan = baichuan
        self.keyGenerator = keyGenerator
        gate = TradeRetryGate(clock: clock)
    }

    /// 加载（进入页面、【重试】、授权回来）。42901 禁用期间执行层直接拦下（不只靠按钮置灰）。
    public func load() {
        guard owned(), !left, !gate.active else { return }
        generation += 1
        let gen = generation
        state.phase = .loading
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await calls.send(
                ApiCall(operationId: TradeOperations.listUnionBindings), group: Self.group, expected: ownership
            )
            // 结算前比较构造时的归属（r3f NEW-04）：换号后才回来的 A 的结果零展示
            guard !left, gen == generation, owned() else { return }
            switch result {
            case let .success(data, _, _):
                state.rows = Self.rows(TJSON.objects(TJSON.parse(data)?["items"]))
                state.phase = .content
                state.errorKey = nil
                state.errorTraceId = nil
            case let .failure(rawCode, _, data, traceId, effect, _):
                // 按实际错误码选文案（共性第 23 条）：42901 用 error.42901 并按 Retry-After 禁用；5xxxx 用对应文案并带 trace6。
                // 非强更的 10405 按 50001（F-X-09，FU-IOS-0712）
                let code = NonForcedUpdate.pageCode(code: rawCode, effect: effect)
                state.errorKey = OpenErrorAction.map(code: code, data: TJSON.parse(data) ?? [:]).textKey ?? Self
                    .genericKey
                state.errorTraceId = (50000...59999).contains(code) ? traceId : nil
                state.phase = .error
                rateLimit(result)
            default:
                // 传输失败（断网、超时）：网络错误文案，不冒充服务端错误
                state.errorKey = Self.networkKey
                state.errorTraceId = nil
                state.phase = .error
            }
        }
    }

    /// 用户点【去授权】。
    public func authorize(_ platform: String) {
        guard owned(), let row = state.rows.first(where: { $0.platform == platform }), !gate.active, !left,
              row.canAuthorize, state.busyPlatform == nil
        else { return }
        state.busyPlatform = platform
        authPermit = true
        authGen += 1
        let gen = authGen
        let installed = ports.installed(platform)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let call = ApiCall(
                operationId: TradeOperations.getUnionAuthUrl, pathParams: ["platform": platform],
                query: "installed=" + installed
            )
            let result = await calls.send(call, group: Self.group, expected: ownership)
            guard alive(gen) else { return }
            switch result {
            case let .success(data, _, _):
                await run(platform, TJSON.parse(data) ?? [:], gen: gen)
            case .failure:
                failed(platform, result)
            default:
                done(Self.networkKey)
            }
        }
    }

    /// 授权流程仍属本次点击且本页归属仍是当前的（r3f NEW-04）：auth-url 成功响应、拼多多外跳、淘宝绑定 / 恢复的每一步都经它，
    /// 换号后不执行旧授权方案、不外跳。
    private func alive(_ gen: Int) -> Bool {
        !left && gen == authGen && owned()
    }

    /// 构造时的归属仍是当前的；不是就清空并作废本页（r3f NEW-04）。只比较。
    private func owned() -> Bool {
        guard !revoked else { return false }
        guard stillOwned?() ?? true else {
            revoke()
            return false
        }
        return true
    }

    /// 会话变化（持有者在会话版本变化时调用；回到前台、每次结算前也会自查，r3f NEW-04）：归属已不是当前的就清空并作废本页。
    public func sessionChanged() {
        _ = owned()
    }

    /// 清空 A 的授权状态并作废：世代加 1 丢弃在途加载与授权流程，取消在途请求，撤销授权许可；页面显示需重进的错误态。
    private func revoke() {
        guard !revoked else { return }
        revoked = true
        generation += 1
        authGen += 1
        authPermit = false
        awaitingReturn = false
        gate.cancelTimer()
        calls.cancel()
        var cleared = AuthManageState()
        cleared.phase = .error
        cleared.errorKey = Self.networkKey
        state = cleared
    }

    /// 拼多多：授权跳转（不上报 link_jump）。只在前台、仍属本次授权、用户许可仍有效时执行下一步（共性第 25、31 条）。
    private func runAuthJump(_ platform: String, _ authJump: TradeObject, gen: Int) async {
        let backgrounds = backgroundCount
        // 只在前台、仍属本次授权、用户许可仍有效时执行下一步（共性第 25、31 条）
        let outcome = await executor.execute(
            plan: authJump, platform: platform, installed: ports.installed(platform), identity: nil,
            allowed: { [weak self] in self.map { $0.alive(gen) && $0.foreground && $0.authPermit } ?? false }
        )
        guard alive(gen) else { return }
        if outcome.run.final == JumpTypes.finalOpened || outcome.run.final == JumpTypes.finalBrowser
            || outcome.stopped {
            state.busyPlatform = nil
            // 拉起的异步回调晚于回前台通知：已进过后台、此刻已在前台就立即刷新（共性第 38 条）
            if foreground, backgroundCount > backgrounds {
                load()
            } else {
                awaitingReturn = true
            }
        } else {
            done(Self.authFailedKey)
        }
    }

    private func run(_ platform: String, _ data: TradeObject, gen: Int) async {
        if let authJump = TJSON.object(data["auth_jump"]) {
            await runAuthJump(platform, authJump, gen: gen)
            return
        }
        // 淘宝：含 30104 按 reason 的恢复（共性第 18 条）；本页发起的授权不重放任何 open
        let flow = TaobaoAuthFlow(
            calls: calls, group: Self.group, webCode: webCode, baichuan: baichuan, keyGenerator: keyGenerator,
            expected: ownership,
            alive: { [weak self] in self?.alive(gen) ?? false },
            installed: { [weak self] in self?.ports.installed($0) ?? TradeConstants.installedUnknown },
            relaunchAllowed: { [weak self] in self.map { $0.authPermit && $0.foreground } ?? false }
        )
        guard flow.pick(platform: platform, data: data) != nil else {
            // 本端执行不了下发的任何方式（TODO(N-28)：web_code 回跳未登记、百川不可用）
            done(Self.authFailedKey)
            return
        }
        let outcome = await flow.run(platform: platform, initial: data)
        // 授权流程结束时本页已换号 / 离开 / 有新的点击（r3f NEW-04）：结果零展示
        guard alive(gen) else { return }
        switch outcome {
        case .bound:
            // 绑定成功：刷新本页，不重放任何 open（BR-ID-17 细则）
            state.busyPlatform = nil
            load()
        case .cancelled:
            state.busyPlatform = nil
        case .failed:
            done(Self.authFailedKey)
        case let .requestFailed(result):
            if case .failure = result {
                failed(platform, result)
            } else {
                done(Self.networkKey)
            }
        case .abandoned:
            break
        }
    }

    private func failed(_ platform: String, _ result: ApiResult) {
        guard case let .failure(rawCode, _, data, traceId, effect, _) = result else { return }
        let code = NonForcedUpdate.pageCode(code: rawCode, effect: effect)
        let outcome = OpenErrorAction.map(code: code, data: TJSON.parse(data) ?? [:])
        rateLimit(result)
        if code == 30153 {
            // 授权管理页的 30153：只给联系客服（error-codes 30153）
            state.busyPlatform = nil
            state.rows = state.rows.map { row in
                guard row.platform == platform else { return row }
                var out = row
                out.authorized = false
                out.blocked = true
                return out
            }
            return
        }
        done(outcome.textKey ?? Self.genericKey, traceId: outcome.showTrace6 ? traceId : nil)
    }

    /// 回到前台：拼多多授权跳转之后刷新本页。
    public func onForeground() {
        foreground = true
        // 换号后返回（r3f NEW-04）：先比较归属，不是当前的就清空 A 的状态
        guard owned(), awaitingReturn, !left else { return }
        awaitingReturn = false
        load()
    }

    /// 页面被盖住或 App 进入后台：授权跳转的续执行许可作废（共性第 25 条）。
    public func onBackground() {
        foreground = false
        authPermit = false
        backgroundCount += 1
    }

    public func leave() {
        left = true
        authGen += 1
        gate.cancelTimer()
        calls.cancel()
    }

    public func consumeToast() {
        state.toast = nil
    }

    private func done(_ key: String, traceId: String? = nil) {
        toastSeq += 1
        state.busyPlatform = nil
        state.toast = PurchaseToast(key: key, traceId: traceId, id: toastSeq)
    }

    /// 42901：按 Retry-After（缺省 5 秒）禁用加载与授权，到期自动恢复（共性第 11 条）。
    private func rateLimit(_ result: ApiResult) {
        let millis = TradeResults.disableMillis(result)
        guard millis > 0 else { return }
        state.rateLimited = true
        gate.start(millis) { [weak self] in
            guard let self, !left else { return }
            state.rateLimited = false
        }
    }

    /// listUnionBindings 的投影：没有返回的平台按未授权。
    public static func rows(_ items: [TradeObject]) -> [AuthManageRow] {
        platforms.map { platform in
            let status = items.first { TJSON.string($0["platform"]) == platform }.flatMap { TJSON.string($0["status"]) }
            return AuthManageRow(
                platform: platform, authorized: status == TradeConstants.active, blocked: status == "blocked"
            )
        }
    }
}
