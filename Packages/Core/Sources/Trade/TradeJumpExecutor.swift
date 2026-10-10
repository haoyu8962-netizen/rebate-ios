import CouliNetwork
import Foundation
import TradeJump

/// 外跳的系统能力（App 给 iOS 实现；测试给替身）。只在用户点击触发的流程里调用（BR-ATTR-21：无点击不外跳）。
@MainActor
public protocol JumpPorts: AnyObject {
    /// 目标 App 安装状态（BR-ATTR-27 ①）："true" / "false" / "unknown"。只查 apps.json 声明的 scheme；apps.json 的 iOS
    /// 查询 scheme 为空（candidate，未给值）时一律 unknown，检测失败也是 unknown，不能当 false（G05，TODO(N-28)）。
    func installed(_ platform: String) -> String
    /// scheme / universal_link 步骤：只拉起目标 App（universal_link 只在有 App 认领时打开，不落到浏览器）。返回是否拉起。
    func launchApp(type: String, value: String) async -> Bool
    /// h5 步骤：交系统浏览器（不进本 App 的两类容器，03 §4.5、AuthJumpStep）。返回是否打开。
    func openBrowser(_ url: String) async -> Bool
    /// copy_tpwd：复制口令。返回是否复制成功。
    func copy(_ text: String) -> Bool
}

/// link_jump 上报口（App 接 Tracker 本地队列，上报 sink 仍为 TODO(N-20)）：参数是 `LinkJumpEvents.build` 的一条业务字段。
@MainActor
public protocol LinkJumpSink: AnyObject {
    func report(_ fields: TradeObject)
    /// 购买外跳的步骤（APP-08 iOS r3g NEW-06）：带发起时固定的请求归属（账号 + 世代），上报口编码 user_id 时用它；交给埋点队列之前
    /// 比较当前归属，变了就丢弃。没有固定归属（nil）时同 `report(_:)`。
    func report(_ fields: TradeObject, owner: RequestOwnership?)
}

public extension LinkJumpSink {
    func report(_ fields: TradeObject, owner _: RequestOwnership?) {
        report(fields)
    }
}

/// 这次外跳属于哪一次购买（open 响应的 attempt_id 与替换后的 link_id）。auth_jump 为 nil（不上报 link_jump）。
public struct PurchaseIdentity: Equatable, Sendable {
    public let attemptId: String
    public let linkId: String
    /// 这次购买发起时固定的请求归属（APP-08 iOS r3g NEW-06）：link_jump 埋点的账号归属只取它。
    public let owner: RequestOwnership?

    public init(attemptId: String, linkId: String, owner: RequestOwnership? = nil) {
        self.attemptId = attemptId
        self.linkId = linkId
        self.owner = owner
    }
}

/// 执行结果：`run` 的 final 外加用户在浏览器提示里取消、sdk 步骤不可用、过期、许可作废。
public struct JumpOutcome: Equatable, Sendable {
    public var run: JumpRun
    public var cancelled = false
    /// 执行过淘宝 sdk 步骤且初始化 / 拉起失败（没有后续步骤时 ProductJumpSdkFailed，BR-ATTR-27 淘宝行）。
    public var sdkUnavailable = false
    public var copied = false
    public var browser = false
    /// 方案已过 expire_at（或 expire_at 缺失、无法解析，保守按过期）：从这一步起不再执行、不上报（共性第 12 条）。
    public var expired = false
    /// 续执行许可已作废（进入后台、被覆盖、离开、用户再点）：从这一步起不再执行、不上报（共性第 3、25 条）。
    public var stopped = false
}

/// 跳转方案执行器（03 §4.5、BR-ATTR-27）：购买外跳与授权跳转（AuthJumpPlan）共用。按 `JumpPlanRunner.run` 的同一个循环执行，
/// 每一步结果都上报 link_jump（`identity` 为 nil 即授权跳转，不上报）；sdk 步骤先让百川按「失败过就重试 1 次」初始化（BR-ATTR-27），
/// 仍不可用记 sdk_init_failed 并继续下一步。h5 步骤打开系统浏览器之前，先经 `confirmBrowser` 给出「将通过浏览器打开」的提示
/// （可取消；BR-ATTR-27 京东行），取消即停止，之后的步骤不执行、不上报。
@MainActor
public final class TradeJumpExecutor {
    private let ports: JumpPorts
    private let baichuan: BaichuanAdapter
    private let sink: LinkJumpSink
    private let elapsedMillis: () -> Int64
    /// 墙上时钟（判 expire_at 用，共性第 12 条）；测试注入。
    private let now: () -> Int64

    public init(
        ports: JumpPorts,
        baichuan: BaichuanAdapter,
        sink: LinkJumpSink,
        elapsedMillis: @escaping () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) },
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.ports = ports
        self.baichuan = baichuan
        self.sink = sink
        self.elapsedMillis = elapsedMillis
        self.now = now
    }

    /// 执行方案。每一步执行前（含 sdk 初始化、浏览器提示这些等待之后）都复核：`allowed`（允许开始下一步：本次点击的续执行许可仍有效、
    /// 页面在前台、平台与商品仍可购，共性第 40 条）与
    /// expire_at（`now` 已到或无法判定即停）；不满足即停止，这一步与之后的步骤不执行、不上报。
    public func execute(
        plan: TradeObject,
        platform: String,
        installed: String,
        identity: PurchaseIdentity?,
        allowed: @escaping @MainActor () -> Bool = { true },
        mayReport: @escaping @MainActor () -> Bool = { true },
        confirmBrowser: @escaping @MainActor () async -> Bool = { true }
    ) async -> JumpOutcome {
        let context = RunContext(
            platform: platform, installed: installed, identity: identity, expireAt: Self.expireAtMillis(plan),
            allowed: allowed, confirmBrowser: confirmBrowser
        )
        context.mayReport = mayReport
        let app: Bool? = installed == TradeConstants.installedTrue ? true
            : installed == TradeConstants.installedFalse ? false : nil
        let run = await JumpPlanRunner.run(JumpPlanRunner.steps(plan), installedApp: app) { [self] _, step in
            await runStep(step, context)
        }
        context.outcome.run = run
        return context.outcome
    }

    /// 一次执行的上下文（标志随步骤累积）。
    private final class RunContext {
        let platform: String
        let installed: String
        let identity: PurchaseIdentity?
        let expireAt: Int64?
        let allowed: @MainActor () -> Bool
        let confirmBrowser: @MainActor () async -> Bool
        var outcome = JumpOutcome(run: JumpRun(executed: [], final: JumpTypes.finalFailed))
        /// 允许上报已执行的步骤（只看尝试与取消，不看前台：拉起目标 App 时本 App 进后台，那一步照常上报，共性第 40 条）。
        var mayReport: @MainActor () -> Bool = { true }

        init(
            platform: String, installed: String, identity: PurchaseIdentity?, expireAt: Int64?,
            allowed: @escaping @MainActor () -> Bool, confirmBrowser: @escaping @MainActor () async -> Bool
        ) {
            self.platform = platform
            self.installed = installed
            self.identity = identity
            self.expireAt = expireAt
            self.allowed = allowed
            self.confirmBrowser = confirmBrowser
        }
    }

    /// 已停（取消、过期、许可作废）：置上对应标志并返回 true。
    private func halted(_ context: RunContext) -> Bool {
        if context.outcome.cancelled || context.outcome.expired || context.outcome.stopped {
            return true
        }
        if !context.allowed() {
            context.outcome.stopped = true
        } else if context.expireAt.map({ now() >= $0 }) ?? true {
            context.outcome.expired = true
        }
        return context.outcome.stopped || context.outcome.expired
    }

    private func runStep(_ step: TradeObject, _ context: RunContext) async -> String {
        if halted(context) {
            return JumpTypes.failed
        }
        let type = TJSON.string(step["type"]) ?? ""
        let value = TJSON.string(step["value"]) ?? ""
        let started = elapsedMillis()
        var result = JumpTypes.failed
        switch type {
        case JumpTypes.sdk:
            result = sdk(value)
            context.outcome.sdkUnavailable = context.outcome.sdkUnavailable || result != JumpTypes.launched
        case JumpTypes.scheme, JumpTypes.universalLink:
            let launched = value.isEmpty ? false : await ports.launchApp(type: type, value: value)
            result = launched ? JumpTypes.launched : JumpTypes.failed
        case JumpTypes.h5:
            guard await context.confirmBrowser() else {
                context.outcome.cancelled = true
                return JumpTypes.failed
            }
            // 提示停留期间进入后台、过期：不打开浏览器、不上报
            if halted(context) {
                return JumpTypes.failed
            }
            let opened = value.isEmpty ? false : await ports.openBrowser(value)
            result = opened ? JumpTypes.launched : JumpTypes.failed
            context.outcome.browser = opened
        case JumpTypes.copyTpwd:
            let copied = !value.isEmpty && ports.copy(value)
            result = copied ? JumpTypes.copied : JumpTypes.failed
            context.outcome.copied = copied
        default:
            // 契约枚举以外的步骤：不执行（不臆造执行方式，G14），按失败继续
            result = JumpTypes.failed
        }
        // 已执行的步骤：本次尝试没被替代、没离开就上报（共性第 40 条：与「允许开始下一步」分开）
        if let identity = context.identity, JumpTypes.known.contains(type), context.mayReport() {
            let fields: TradeObject = [
                "phase": LinkJumpEvents.phasePurchase, "union_platform": context.platform, "step": type,
                "result": result, "duration_ms": max(0, elapsedMillis() - started), "installed": context.installed,
            ]
            report(identity, fields)
        }
        return result
    }

    /// 方案此刻是否已过期（expire_at 缺失、无法解析按已过期，保守不外跳）。
    public func expired(_ plan: TradeObject) -> Bool {
        Self.expireAtMillis(plan).map { now() >= $0 } ?? true
    }

    static func expireAtMillis(_ plan: TradeObject) -> Int64? {
        guard let text = TJSON.string(plan["expire_at"]) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text).map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    /// 百川初始化失败（同意隐私后的那次）：phase=startup 上报 sdk_init_failed（events.json link_jump，BR-ATTR-27 淘宝行）。
    public func reportStartupInitFailed() {
        let step: TradeObject = [
            "phase": LinkJumpEvents.phaseStartup, "union_platform": "taobao",
            "step": JumpTypes.sdk, "result": JumpTypes.sdkInitFailed,
        ]
        for fields in LinkJumpEvents.build(attemptId: nil, linkId: nil, steps: [step], isAuthJump: false) {
            sink.report(fields)
        }
    }

    private func sdk(_ value: String) -> String {
        // 下一次执行 sdk 步骤之前重试初始化 1 次（BR-ATTR-27 淘宝行）；仍不可用就跳过、记 sdk_init_failed
        if !baichuan.ready, !baichuan.retryInitIfFailed() {
            return JumpTypes.sdkInitFailed
        }
        switch baichuan.open(value) {
        case .launched: return JumpTypes.launched
        case .initFailed: return JumpTypes.sdkInitFailed
        case .failed: return JumpTypes.failed
        }
    }

    private func report(_ identity: PurchaseIdentity, _ step: TradeObject) {
        for fields in LinkJumpEvents.build(
            attemptId: identity.attemptId, linkId: identity.linkId, steps: [step], isAuthJump: false
        ) {
            sink.report(fields, owner: identity.owner)
        }
    }
}
