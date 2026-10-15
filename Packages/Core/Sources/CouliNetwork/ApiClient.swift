import Foundation
import Generated
import Session

/// 请求管线（03 §4.2「中间件顺序」）：公共头 → 签名（仅 x-signed）→ 发送（10 秒超时；读接口超时 / 断连重试 1 次）→
/// 解包 `{code, msg, data, trace_id}` → `ErrorActionMapper`。
///
/// - 每次实际发送（含读接口重试、10002 / 10402 / 10401 的重放）前都重新取状态、重新校验环境 / 隐私 / 会话 / 白名单，
///   重新读凭据、重新组头、重新签名；不复用已捕获凭据的旧请求。`invalidateSessions()`（撤回同意、切换环境，经
///   `NetworkInvalidationCleaner` 登记进两个清理注册表）作废全部在途请求及其重试、重放，并取消在途任务。
/// - 会话世代：登录、清会话、作废时换代，刷新不换代（同一会话换令牌）。带过令牌的调用绑定发出时的世代：之后的重试与
///   重放只在同一世代里进行；退出、换账号、重新登录后，旧调用不会带着新账号的令牌重放（本地按 session_changed 结束）。
/// - 本地放行与剥离（`RequestHeaderPolicy`）：环境未就绪不发；基本模式与撤回清理未完成时只放行匿名白名单、不带凭据；
///   受限会话只发受限会话表里的接口。
/// - 10002：令牌单飞刷新，刷新窗口按会话世代隔离（同一世代同一时刻最多一个窗口，不同世代不共享；账号、作废世代、
///   refresh_token 在入队的同一把锁里固定成窗口快照）。成功后沿用原键、原请求体重放 1 次；失败清会话并发出一次跳登录
///   Effect（以结算那一刻的强更状态为准：强更状态下停在强更页）。每个等待者直接拿到所在窗口不可变的完整结果
///   （`RefreshOutcome`：成功 / 暂时失败 / 会话已清 / 已换代），不在醒来后查询可被下一窗口覆盖的全局状态。
///   本次用的令牌已被同一世代的刷新换掉时直接用新令牌重放；该世代因刷新失败被清掉后晚到的 10002 复用那次失败结果
///   （session_cleared，不再清会话、不再发 Effect）；用户换了会话的按 session_changed 结束。刷新结果晚于作废、换代
///   到达时丢弃，不把会话恢复回来，也不清掉新会话。
/// - 清会话（刷新被拒、10404、退出）：先在内存里让该会话不可读，删除失败时持续阻断旧令牌并重试删除。会话一次读出完整
///   四项（`SessionTokens.readSession()`）：读取失败不当成没有会话——需要会话的接口本地拒绝（session_unreadable），
///   隔离与删除重试保持；只有确认删除成功或新登录成功替换后才解除隔离。
/// - 受限会话屏障：进程启动（不论强更状态，below 时也先刷新）、强更状态由低于 / 未知恢复为受支持（App 把 AppUpdate 的状态变化接到
///   `updateStateChanged`，立即发起刷新；每次读状态时也会发现）后，存储的会话是 deletion_only 时，带令牌的请求先等
///   一次单飞刷新（不论目标接口在不在受限表里）；刷新失败结束原调用并跳登录。
/// - 10405：确需强更的调 `NetworkHooks.onForceUpdate`（App 接到 AppUpdate.on10405；`ApiCall.forceUpdateByCaller` 的调用只交回 Effect，
///   由调用方复核归属后自己进强更，APP-07 parse）；升级前留下的受限令牌只刷新
///   （失败同上）。登录 / 刷新成功时记下 session_scope；强更检查未知期间拿到 deletion_only 按「低于」处理。
///   登录响应的令牌保存失败（或响应已过期）不返回成功（`ApiResult.sessionNotSaved`）。
/// - 刷新暂时失败（超时、断连、没有外壳）不清会话：等待者与屏障后的首发按网络错误结束，屏障保留；被拒才清会话
///   （等待者按 session_cleared 结束）。旧世代响应的会话级副作用（刷新、清会话、跳登录、登记前置待办）一概不做：
///   该世代因刷新失败被清的按 session_cleared，其余按 session_changed 结束原调用。
/// - 作废未决键：completed 解包 original 按原操作给结果与 Effect；abandoned 返回 `.abandoned`。
/// - 10401：响应头 Date 与本机时钟相差超过 300 秒时校正偏移，用新的 X-Timestamp、X-Nonce 重签再发 1 次（BR-ID-09）。
///   业务请求与内部刷新都适用；校时重签的次数与前置动作重放的次数分开计。
/// - 四个 step-up 操作：账号取自会话（登录时保存的 user_id，取不到本地拒绝）；发送前未决记录必须落盘成功；没有统一外壳
///   即结果未知；之后同一操作的新提交本地拒绝、Effect 不再换新键（10003 仍可在二次验证后同键继续：
///   `confirmPending(stepUpToken:)`）。查询、确认、放弃都先核对记录账号与当前会话账号，发送前再核对一次，结算按原账号。
public final class ApiClient: @unchecked Sendable {
    static let refreshOperation = "refreshToken"
    static let abandonOperation = "abandonIdempotencyKey"
    static let loginOperations: Set<String> = ["loginBySms", "loginByWechat", "loginByApple", "loginByHuawei"]
    static let maxSkewMillis: Int64 = 300_000
    /// 签名校验失败（BR-ID-09）：时钟偏差超过 300 秒时校时重签 1 次。
    static let invalidSignatureCode = 10401
    /// 记住的「因刷新失败被清掉的世代」个数上限（只有迟到响应会查，留最近几代即可）。
    static let refreshFailureMemory = 16

    let identity: ClientIdentity
    let context: @Sendable () async -> NetworkContext
    let device: any DeviceCredentials
    let tokens: any SessionTokens
    let pendingKeys: PendingKeyStore
    let hooks: NetworkHooks
    let transport: HttpTransport
    let clock: @Sendable () -> Int64
    let sleeper: @Sendable (Int64) async -> Void
    let newId: @Sendable () -> String
    let nonce: @Sendable () -> String
    /// 删除失败的会话的重试间隔（毫秒，按次数退避；测试可缩短）。
    let revokedRetryDelays: [Int64]

    let lock = NSLock()
    /// 作废世代：撤回同意、切换环境时 +1，在途请求及其重试、重放全部作废。
    var epoch: UInt64 = 0
    /// 会话世代：登录、清会话、退出、作废时 +1；刷新不变（同一会话换令牌）。
    var generation: UInt64 = 0
    var clockOffsetMillis: Int64 = 0
    /// 显示用的服务端时钟偏移（`calibratedNowMillis`；响应头 Date 相差超过 300 秒时校正，10401 校时同步更新）。
    var displayOffsetMillis: Int64 = 0
    /// 冷启动的受限会话屏障待执行（进程启动时为 true）：不论强更状态（含 below）都在首次带令牌请求前刷新（R2-03）。
    var coldStartRefreshDue = true
    /// 强更状态由低于 / 未知恢复为受支持后的受限会话屏障待执行（只在不低于时执行）。
    var recoveryRefreshDue = false
    /// 受限会话屏障编号：冷启动为 1，每次恢复触发重新挂上屏障时 +1（R3-01）。
    var restrictedBarrierSerial: UInt64 = 1
    /// 已结算通过的屏障（会话世代 + 屏障编号）：在刷新窗口结算的那把锁里记下，之后的调用直接复用、不再刷新（R3-01）。
    var restrictedBarrierPassed: RestrictedBarrierMark?
    /// 最近一次读到的强更状态（发现「低于 / 未知 → 受支持」时重新挂上屏障；刷新失败结算时读它）。
    var lastUpdateSeen: String?
    /// 进行中的刷新窗口：会话世代 → 窗口。同一世代同一时刻最多一个，不同世代互不共享。
    var refreshWindows: [UInt64: RefreshWindow] = [:]
    /// 因刷新失败被清掉的会话世代 → 那次结算的会话 Effect（该世代晚到的响应复用，返回 session_cleared）。
    var refreshFailures: [UInt64: ErrorEffect] = [:]
    var refreshCount = 0
    /// 删除失败、在内存里已作废的会话（不可读；持续重试删除，删掉或被新会话覆盖后解除）。
    var revokedSession: RevokedSession?
    var revokedRetryAttempt = 0
    /// 撤回禁读屏障（APP-08 iOS r3f NEW-01）：撤回同意、切换环境（`invalidateSessions`）时在同一把锁里竖起；只有之后取得的状态快照
    /// （取快照前后作废世代未变）表明完整模式且撤回清理已完成时才放下（`readContext`）。网络层每一处令牌读取——包括没有状态快照的
    /// 登出、刷新入队、后台删除重试、Restricted 刷新后的读取、对外的隔离账号 / 作用域 / 请求归属——都先在锁里比较它，竖着时不读令牌。
    var readBarrier = false

    public init(
        identity: ClientIdentity,
        context: @escaping @Sendable () async -> NetworkContext,
        device: any DeviceCredentials = UnregisteredDevice(),
        tokens: any SessionTokens,
        pendingKeys: PendingKeyStore,
        hooks: NetworkHooks = NetworkHooks(),
        configuration: URLSessionConfiguration = .ephemeral,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        sleeper: @escaping @Sendable (Int64) async -> Void = { millis in
            try? await Task.sleep(nanoseconds: UInt64(max(millis, 0)) * 1_000_000)
        },
        newId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        nonce: @escaping @Sendable () -> String = { RequestSigner.nonce() },
        revokedRetryDelays: [Int64] = [1000, 2000, 4000, 8000, 16000, 32000, 60000]
    ) {
        self.identity = identity
        self.context = context
        self.device = device
        self.tokens = tokens
        self.pendingKeys = pendingKeys
        self.hooks = hooks
        transport = HttpTransport(configuration: configuration)
        self.clock = clock
        self.sleeper = sleeper
        self.newId = newId
        self.nonce = nonce
        self.revokedRetryDelays = revokedRetryDelays.isEmpty ? [1000] : revokedRetryDelays
    }

    // MARK: - 对外入口

    /// 发一次调用。
    public func send(_ call: ApiCall) async -> ApiResult {
        guard let operation = ApiOperations.byId(call.operationId) else {
            return .localReject(reason: LocalRejectReason.invalidCall)
        }
        return await run(call, operation, isReplay: false, options: RunOptions(epoch: currentEpoch))
    }

    /// 服务端校准后的当前时刻（毫秒；BR-TEXT-11「以服务端校准后的时钟为准」，APP-08 共性第 34 条）：本机时钟 + 按响应头 Date
    /// 校出的偏移（任一响应的 Date 与本机相差超过 300 秒时校正；10401 校时也同步）。没校过或偏差在 300 秒以内就是本机时钟。
    /// 相对时间（今天 / 昨天）、缓存时间提示等显示用它；测时长（禁用期、超时）仍用本机时钟；签名用的偏移不受它影响。
    public var calibratedNowMillis: Int64 {
        clock() + lock.withLock { displayOffsetMillis }
    }

    /// 当前的作废世代（撤回同意、切换环境时 +1）。长流程（如设备注册）在开始时取下，发送时用 `send(_:ticket:)` 交回。
    public var invalidationTicket: UInt64 {
        currentEpoch
    }

    /// 带原始票据发送：票据已失效（之后撤回过同意或切换过环境）时在实际发送前的守卫里本地结束（call_cancelled），
    /// 不把这次请求重新绑定到当前环境（APP-03b 共性 13）。
    /// `isValid`（可选）：调用方的有效性，与 `send(_:isValid:)` 同样在等待结束、重试与实际发送前检查。
    public func send(_ call: ApiCall, ticket: UInt64, isValid: (@Sendable () -> Bool)? = nil) async -> ApiResult {
        guard let operation = ApiOperations.byId(call.operationId) else {
            return .localReject(reason: LocalRejectReason.invalidCall)
        }
        var options = RunOptions(epoch: ticket)
        options.callValid = isValid
        return await run(call, operation, isReplay: false, options: options)
    }

    /// 带调用有效性发送（桥调用用；APP-04 三端共性第 22 条）：`isValid` 在每次等待结束后、每次重试前、真正发出前
    /// （与作废世代同一处守卫）都要为真，否则本地结束（call_cancelled），不再发出。页面关闭或导航后桥把它置为假。
    /// `isValid` 可能在任意线程调用，须线程安全。
    public func send(_ call: ApiCall, isValid: @escaping @Sendable () -> Bool) async -> ApiResult {
        guard let operation = ApiOperations.byId(call.operationId) else {
            return .localReject(reason: LocalRejectReason.invalidCall)
        }
        var options = RunOptions(epoch: currentEpoch)
        options.callValid = isValid
        return await run(call, operation, isReplay: false, options: options)
    }

    /// 带调用有效性与发送前闸门发送（订单请求，APP-08 共性第 13、27 条）：`isValid` 同 `send(_:isValid:)`（归属，失效即作废、
    /// 丢弃迟到响应）；`sendAllowed` 只在每次实际写出前核对（含退避重试与各类重放），为假时本地结束（`send_blocked`），
    /// 已写出的请求不受它影响。两个闭包都可能在任意线程调用，须线程安全。
    public func send(
        _ call: ApiCall, isValid: @escaping @Sendable () -> Bool, sendAllowed: @escaping @Sendable () -> Bool
    ) async -> ApiResult {
        guard let operation = ApiOperations.byId(call.operationId) else {
            return .localReject(reason: LocalRejectReason.invalidCall)
        }
        var options = RunOptions(epoch: currentEpoch)
        options.callValid = isValid
        options.sendAllowed = sendAllowed
        return await run(call, operation, isReplay: false, options: options)
    }

    /// 实际发起的刷新次数（`POST /v1/auth/refresh`）。
    public var refreshCalls: Int {
        lock.withLock { refreshCount }
    }

    /// 是否有进行中的刷新窗口。
    public var refreshing: Bool {
        lock.withLock { !refreshWindows.isEmpty }
    }

    /// 撤回同意、切换环境时调用（`NetworkInvalidationCleaner` 登记在两个清理注册表的第一位，先于清令牌）：
    /// 作废全部在途请求、它们的重试与重放，取消在途任务（含还在等连接、TLS 的）；会话换代，迟到的刷新结果不再保存。
    ///
    /// 锁顺序（APP-08 iOS r3g NEW-05）：先在**不持网络锁**时通知设备凭据竖起撤回禁读屏障（只取设备锁），再取网络锁推进作废世代。
    /// 全局只有「设备锁 → 网络锁」一个方向（DeviceRegistry 在设备锁里读 `invalidationTicket`、在设备锁里调用组请求的准入判断）；
    /// 网络锁里从不调用设备凭据。设备屏障先于作废世代竖起，所以任何在网络锁里判断通过、尚未读设备凭据的组请求，
    /// 读取时都会在设备锁里看到屏障（或在屏障竖起之前读完，即读取发生在撤回开始之前）。调用方须串行调用（清理器都在主线程）。
    ///
    /// 切换环境（FU-IOS-0711）：`EnvironmentApplier` 在发布 switching、读取保留项之前经 `EnvironmentSwitchClosing` 先同步调用一次，
    /// 清理器第一位再调一次（可重复）。推进作废世代与取消在途任务在传输层登记任务的同一把锁里（`HttpTransport.closeAll`），
    /// 与 `sendOnce` 的最终准入互斥：准入通过的请求在作废之前已经启动并随即被取消，作废之后的准入一律不启动。
    public func invalidateSessions() {
        device.withdrawalStarted(networkEpoch: currentEpoch)
        transport.closeAll { raiseNetworkBarrier() }
    }

    /// 撤回禁读屏障（APP-08 iOS r3h NEW-05）：竖起设备屏障（只取设备锁）→ 取网络锁推进作废世代、会话换代、竖起网络屏障。
    /// 撤回清理的每个入口在**发布待清理标记之前**同步调用（`EnvironmentSwitchCleanerRegistry.raiseWithdrawalReadBarriers`），
    /// 清理器执行时（`invalidateSessions`）再调一次。可重复调用：每次都推进世代，屏障只由之后取得的可读快照放下。
    /// 锁顺序不变：先不持网络锁地取设备锁，再取网络锁，两步不嵌套。
    public func raiseWithdrawalReadBarriers() {
        device.withdrawalStarted(networkEpoch: currentEpoch)
        raiseNetworkBarrier()
    }

    /// 取网络锁推进作废世代、会话换代、竖起网络屏障（调用方不持网络锁；可在传输锁里调用，顺序「传输锁 → 网络锁」）。
    private func raiseNetworkBarrier() {
        lock.withLock {
            epoch &+= 1
            generation &+= 1
            readBarrier = true
        }
    }

    /// 网络禁读屏障此刻是否竖着（测试与诊断）。
    public var withdrawalReadBarrierRaised: Bool {
        lock.withLock { readBarrier }
    }

    /// 退出登录（APP-05 调用；切换账号时先调它再登录）：清会话、换代——旧世代的在途请求不再重试、重放；
    /// 未决记录停止读取（不删除，换回该账号后恢复）。删除失败时内存里照样作废旧会话并持续重试删除。
    public func signOut() {
        let retry = lock.withLock { clearSessionLocked() }
        if retry {
            scheduleRevokedRetry()
        }
        pendingKeys.signOut()
    }

    /// 强更状态恢复为受支持（升级后、最低版本调低后）：存储的会话若是 deletion_only，立即单飞刷新，期间带令牌的请求
    /// 都等这次刷新。
    public func updateBecameSupported() {
        lock.withLock {
            lastUpdateSeen = UpdateRaw.supported
            armRecoveryBarrierLocked()
        }
        Task { await self.refreshRestrictedSessionNow() }
    }

    /// 强更状态变更通知（App 把 AppUpdate 的状态发布接到这里，每次状态发布都调）：由 below / unknown 恢复为
    /// supported 时重新挂上受限会话屏障；状态是 supported 且屏障待执行（冷启动、刚恢复）时立即发起一次单飞刷新
    /// （存储的会话是 deletion_only 时），期间带令牌的请求都等这次刷新（lessons 19、31）。
    public func updateStateChanged(_ update: String) {
        _ = noteUpdate(update)
        let due = lock.withLock { coldStartRefreshDue || recoveryRefreshDue }
        guard update == UpdateRaw.supported, due else {
            return
        }
        Task { await self.refreshRestrictedSessionNow() }
    }

    // MARK: - 管线

    /// 本次调用占用的未决键（四个 step-up 操作）：键、它所属的账号与这次调用的占用标识。结算一律按这个账号与标识。
    struct PendingHold: Equatable {
        let key: String
        let account: String
        let owner: String?
    }

    struct RunOptions {
        /// 本次请求开始时的作废世代。
        let epoch: UInt64
        /// 已占用（in_flight）的未决键：确认入口或自动重放带进来；任何没发出的退出都要释放。
        var held: PendingHold?
        /// 调用归属：会话世代。在任何屏障等待之前绑定，之后的发送、重试与续发都必须在同一世代。
        var boundGeneration: UInt64?
        /// 调用归属：会话账号（确认、放弃未决键时由入口给出；其余在绑定世代时一并记下）。
        var boundAccount: String?
        /// 作废请求：10001 / 10004 / 10005 只引导。
        var guideOnlyPrerequisites = false
        /// 本次逻辑调用已用掉 10401 校时重签（至多 1 次；与前置动作重放的预算 isReplay 分开计，R2-05）。
        var resigned = false
        /// 调用方给的有效性（桥调用：页面关闭、导航后为假）；nil = 只看作废世代。
        var callValid: (@Sendable () -> Bool)?
        /// 发送前闸门（APP-08 共性第 13、27 条）：只在每次实际写出前核对（首发、读接口退避后的重试、10002 / 10402 / 10401 的
        /// 重放），为假时本地结束（send_blocked），不写出。不参与归属：已写出的请求照常收结果（成功、错误、10405 都不丢）。
        var sendAllowed: (@Sendable () -> Bool)?
        /// 调用方固定的请求归属（APP-08 iOS RC-01）：首次归属绑定前、组请求后与实际写出前只比较，不一致零发送；nil = 不比较。
        var expected: RequestOwnership?
        /// 登录响应的会话保存成功时，在保存所用的同一把锁里回调保存后的会话世代（APP-04 共性 68：桥 auth.login 绑定本次登录
        /// 保存的会话）。nil = 不需要。
        var onSessionSaved: (@Sendable (UInt64) -> Void)?
        /// 逻辑调用开始时取的导航票据（APP-12 G09）：只在第一次 `run` 取一次，重放、续发沿用。
        var navTicket: UInt64?
        var navTicketTaken = false
    }

    struct Ready {
        let request: PreparedRequest
        let idempotencyKey: String?
        let accessToken: String?
        /// 当前会话账号（凭据可读时）。
        let account: String?
        let generation: UInt64
    }

    enum Prepared {
        case rejected(String)
        case ready(Ready)
    }

    var currentEpoch: UInt64 {
        lock.withLock { epoch }
    }

    var updateIsBelow: Bool {
        lock.withLock { lastUpdateSeen == UpdateRaw.below }
    }

    var currentGeneration: UInt64 {
        lock.withLock { generation }
    }

    func isCurrent(_ value: UInt64) -> Bool {
        lock.withLock { epoch == value }
    }

    /// 作废世代未变，且调用方的有效性仍为真。
    func stillValid(_ options: RunOptions) -> Bool {
        isCurrent(options.epoch) && (options.callValid?() ?? true)
    }

    /// 调用方给的有效性（没给的按有效）。
    func callStillValid(_ options: RunOptions) -> Bool {
        options.callValid?() ?? true
    }

    /// 桥调用的迟到响应（APP-04 三端共性第 30 条）：调用已失效（页面关闭、换文档、撤回同意、切换环境）时不进入恢复分支——
    /// 不刷新（10002 刷新后重放、10405 refresh_only）、不重新注册（10402），本地按 call_cancelled 结束；10401 校时重签在
    /// `run` 里同样拦下。重放预算用完的 10402 不在此列：照常隔离凭据并交给唯一的退避链（凭据事实，不是这次调用的恢复）。
    func abandonsRecovery(_ effect: ErrorEffect, _ options: RunOptions) -> Bool {
        let recovery: Set<ErrorEffectKind> = [.refreshReplay, .refreshOnly, .registerDeviceReplay]
        return recovery.contains(effect.kind) && !callStillValid(options)
    }

    /// 调用结束时会话已不是它绑定的那一代：作废导致的按 call_cancelled，其余按 session_changed。
    func supersededReason(_ options: RunOptions) -> String {
        isCurrent(options.epoch) ? LocalRejectReason.sessionChanged : LocalRejectReason.callCancelled
    }

    /// 读状态，顺便记下最新的强更状态（发现恢复为受支持时重新挂上受限会话屏障）。
    /// 快照记下取之前的作废世代（`NetworkContext.readEpoch`，APP-08 iOS NEW-01）：之后凭据读取前在同一把锁里先比较它，
    /// 期间撤回过同意 / 切过环境就不再信任这份快照里的可读性。
    func readContext() async -> NetworkContext {
        let before = currentEpoch
        var state = await context()
        state.readEpoch = before
        // 撤回禁读屏障只由「作废之后取得、期间没有再作废」的可读快照放下（APP-08 iOS r3f NEW-01）；切换环境期间（环境未就绪）
        // 的快照不放下（FU-IOS-0711）
        lock.withLock {
            if readBarrier, epoch == before, state.environmentSettled, state.privacy == PrivacyRaw.full,
               state.credentialsReadable {
                readBarrier = false
            }
        }
        _ = noteUpdate(state.update)
        return state
    }

    /// 记下强更状态；由 below / unknown 恢复为 supported 时重新挂上受限会话屏障，返回 true。
    func noteUpdate(_ update: String) -> Bool {
        lock.withLock {
            let previous = lastUpdateSeen
            lastUpdateSeen = update
            let recovered = (previous == UpdateRaw.below || previous == UpdateRaw.unknown)
                && update == UpdateRaw.supported
            if recovered {
                armRecoveryBarrierLocked()
            }
            return recovered
        }
    }

    func syncPendingAccount(_ account: String) {
        if pendingKeys.currentAccount != account {
            pendingKeys.coldStart(account: account)
        }
    }
}
