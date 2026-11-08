import CouliNetwork
import Foundation
import Generated

/// 实名页状态。`name`、`idNo` 是用户填写的原文（只在内存；不进日志、恢复记录与截图）。
public struct RealNameSnapshot: Equatable, Sendable, CustomStringConvertible {
    public var name = ""
    public var idNo = ""
    /// 单独同意半屏的实例编号（nil = 没打开；每次打开换新，回调核对，APP-11 第 17、28 条）。
    public var consentId: Int?
    public var consentChecked = false
    public var submitting = false
    public var awaitingIdentity = false
    public var showsSubmitting: Bool {
        submitting && !awaitingIdentity
    }

    public var showsRecheck: Bool {
        awaitingIdentity
    }

    public var error: Notice?
    public var fieldErrors: [String] = []
    /// 字段错误事件编号（共性第 24 条）。
    public var fieldErrorId = 0
    /// 30410 当日次数用完：按钮置灰到本页退出。
    public var lockedToday = false
    public var done: Notice?
    /// 本表单所属的身份（共性第 52 条）：按钮回调带上它，执行前核对。
    public var owner: WalletOwner

    public var description: String {
        "RealNameSnapshot(submitting=\(submitting), locked=\(lockedToday))"
    }
}

/// 实名认证执行器（RealName 路由；BR-ID-25，D10-856 ②）：姓名去首尾空白；身份证号只收数字与 X，18 位，小写 x 转大写，不做校验位计算。提交前
/// 先弹单独同意（默认不勾选，点遮罩不关闭）；勾选后【同意并继续】先记同意（recordConsent），code 0 之后才发实名提交（submitRealname）。
/// 后端为 nil（`installBackends(realname: nil)`）时【提交认证】置灰，显示「实名认证暂未开放」，不发任何请求。
///
/// 幂等键（契约 IdempotencyKey、BR-ID-10，编排 F-AND-48 / D10-887）：键与规范化后的请求体绑定，同一个键绝不配另一份请求体。
/// - 结果未知（断连、超时）、10004 id_verification（重开单独同意，同意后重放）、10001 / 10005：保留原键，表单不变再提交沿用；
///   表单改了旧键作废、用新键（D10-887 ③）。
/// - 40901：不是终态，保持在途，退避后自动用原键、原请求体重发（不重新记同意；连首发 6 秒内最多 4 次，D10-887 ⑤），重发用完后停在
///   可再提交（仍沿用原键）。
/// - 其余错误（2xxxx、3xxxx、10010、10405、5xxxx）：本次键结束，下次用新键。50301 回落 error.50001 + trace6（D10-887 ②）。
/// 成功后本会话按已实名放行、复查 GET /v1/me、清掉已填内容、出栈回发起页（G05，不重放）；结果只给表单固定的身份。只在主线程使用。
@MainActor
public final class RealNameController: ObservableObject, IdentityResumable {
    public static let fieldName = "name"
    public static let fieldId = "id_no"

    @Published public private(set) var state: RealNameSnapshot
    let tasks = SettlingTasks()
    let deps: WalletDeps
    public var page: UUID?
    public let visibility = PageVisibility()
    private var left = false
    private var serial = 0
    private var deferredBack = false
    private var completed = false
    /// 保留的幂等键与它绑定的请求体（规范化后的输入；只在内存）。nil = 下次提交用新键。`unknown`：这个键出现过结果未知（断连、超时），
    /// 之后再拿到 10405 / 5xxxx / 42901 也不结束键（错误码表「不结束未决幂等键」，D10-1018）。
    private var retained: Retained?
    /// 40901 后自动重发前的等待（毫秒）：发出时刻约 0、1、2.5、4.5 秒，连首发共 4 次、都在 6 秒内（D10-887 ⑤）；用完停下，
    /// 出 error.40901、保留原键，用户再提交仍沿用原键。
    static let busyDelaysMillis: [UInt64] = [1000, 1500, 2000]
    /// 身份暂时未知时到达的提交结果（FU-IOS-0712 整体重理：与各资金页同一套机制；不重放提交，身份确认后仍是本表单身份才采用）。
    public let deferral = IdentityDeferral()

    public init(deps: WalletDeps) {
        self.deps = deps
        // 表单身份在构造时一次性取得（共性第 65 条）；之后只比较、不再读取当前会话来赋值
        state = RealNameSnapshot(owner: deps.env.currentOwner())
    }

    /// 没有实名后端（`installBackends(realname: nil)`）时不开放；生产接线为 `ApiRealNameBackend`。
    public var available: Bool {
        deps.realname != nil
    }

    public var submitEnabled: Bool {
        available && !state.lockedToday && !state.submitting && !state.awaitingIdentity && !completed && !deps.gates
            .realname.active
            && RealNameForm.normalize(name: state.name, idNo: state.idNo).submitEnabled
    }

    public var gate: RetryAfterGate {
        deps.gates.realname
    }

    private func owns(_ owner: WalletOwner) -> Bool {
        !left && owner == state.owner && deps.env.isCurrent(owner)
    }

    /// 姓名、身份证号的输入与自动填充回调带渲染这张表单时的身份（共性第 59、63 条）：会话已换后到达的旧回调不写入。
    public func onNameChange(_ text: String, owner: WalletOwner) {
        guard owns(owner) else { return }
        state.name = PayoutAccountForm.clip(text, max: RealNameForm.nameMax)
        state.fieldErrors.removeAll { $0 == Self.fieldName }
        state.error = nil
        dropKeyIfFormChanged()
    }

    public func onIdChange(_ text: String, owner: WalletOwner) {
        guard owns(owner) else { return }
        state.idNo = RealNameForm.acceptIdNo(current: state.idNo, next: text)
        state.fieldErrors.removeAll { $0 == Self.fieldId }
        state.error = nil
        dropKeyIfFormChanged()
    }

    /// 结果未知后改了表单：旧键作废，下次用新键（D10-887 ③；同一个键不配另一份请求体）。
    private func dropKeyIfFormChanged() {
        guard let held = retained,
              RealNameForm.normalize(name: state.name, idNo: state.idNo) != held.input else { return }
        retained = nil
    }

    /// 【提交认证】：先弹单独同意（默认不勾选）。
    public func submit(owner: WalletOwner) {
        guard owns(owner), submitEnabled else { return }
        serial += 1
        state.consentId = serial
        state.consentChecked = false
        deps.env.sensitiveOverlay(true)
    }

    /// 勾选（`consent` 是渲染时的半屏实例）。
    public func toggleConsent(consent: Int, owner: WalletOwner) {
        guard state.consentId == consent, owns(owner) else { return }
        state.consentChecked.toggle()
    }

    /// 【暂不认证】、关闭、系统返回（同一出口；`consent` 是渲染时的半屏实例）。
    public func declineConsent(consent: Int) {
        guard state.consentId == consent else { return }
        state.consentId = nil
        state.consentChecked = false
        deps.env.sensitiveOverlay(false)
    }

    /// 单独同意里勾选后点【同意并继续】：先记同意（code 0 之后才提交），再发实名提交。
    public func agreeAndSubmit(consent: Int, owner: WalletOwner) {
        guard let backend = deps.realname, state.consentId == consent, state.consentChecked, !state.submitting,
              owns(owner)
        else { return }
        let input = RealNameForm.normalize(name: state.name, idNo: state.idNo)
        guard input.submitEnabled else { return }
        state.consentId = nil
        state.submitting = true
        state.error = nil
        deps.env.sensitiveOverlay(false)
        let kept = retained.flatMap { $0.input == input ? $0 : nil }
        let key = kept?.key ?? deps.newKey()
        retained = Retained(input: input, key: key, unknown: kept?.unknown ?? false)
        let attempt = Attempt(input: input, key: key, owner: owner)
        let tasks = tasks
        tasks.begin()
        Task { @MainActor [weak self] in
            defer { tasks.end() }
            guard let self, !left, deps.env.isCurrent(owner) else {
                self?.state.submitting = false
                return
            }
            let result = await backend.recordConsent(owner: owner.request)
            consentArrived(result, attempt: attempt, backend: backend)
        }
    }

    /// 同意记录的结果：code 0 才发实名提交；失败（含断连）不提交、给出错误、恢复按钮。身份暂时未知时与提交结果同一套机制：不采用、记下
    /// （结束忙碌展示但保持提交锁，显示核对身份），身份确认后仍是本表单身份才继续；已换代 → 丢弃（换代另有重建）。
    private func consentArrived(_ result: ApiResult, attempt: Attempt, backend: RealNameBackend) {
        guard !left, state.owner == attempt.owner, state.submitting else { return }
        guard deferral.admit(deps.env.check(attempt.owner), slot: "consent", resume: { [weak self] in
            self?.consentArrived(result, attempt: attempt, backend: backend)
        }, settle: { state.awaitingIdentity = true }) else {
            if deps.env.check(attempt.owner) == .stale {
                state.submitting = false
            }
            return
        }
        state.awaitingIdentity = false
        if case .success = result {
            send(attempt, backend: backend, busy: 0)
            return
        }
        let error = WalletErrors.of(result)
        if error.kind == .retryAfter {
            deps.gates.realname.start(error.disableMillis)
        }
        serial += 1
        state.submitting = false
        if error.kind != .cancelled {
            state.error = Self.notice(error, code: Self.code(result), id: serial)
        }
    }

    private func send(_ attempt: Attempt, backend: RealNameBackend, busy: Int) {
        let tasks = tasks
        tasks.begin()
        Task { @MainActor [weak self] in
            defer { tasks.end() }
            // 发送前核对：会话已换的不发（共性第 39、52 条）；后端实现也按固定身份核对
            guard let self, !left, deps.env.isCurrent(attempt.owner) else {
                self?.state.submitting = false
                return
            }
            let result = await backend.submit(name: attempt.input.name, idNo: attempt.input.idNo,
                                              idempotencyKey: attempt.key, owner: attempt.owner.request)
            submitArrived(result, attempt: attempt, backend: backend, busy: busy)
        }
    }

    /// 提交结果的身份核对：暂时未知 → 不采用、记下（结束忙碌展示但保持提交锁，身份确认后仍是本表单身份才采用）；已换代 → 丢弃。
    private func submitArrived(_ result: ApiResult, attempt: Attempt, backend: RealNameBackend, busy: Int) {
        guard !left, state.owner == attempt.owner else { return }
        guard deferral.admit(deps.env.check(attempt.owner), slot: "submit", resume: { [weak self] in
            self?.submitArrived(result, attempt: attempt, backend: backend, busy: busy)
        }, settle: { state.awaitingIdentity = true }) else { return }
        state.awaitingIdentity = false
        if Self.code(result) == Self.busyCode, busy < Self.busyDelaysMillis.count {
            retryBusy(attempt, backend: backend, busy: busy)
            return
        }
        onResult(result)
    }

    /// 40901：保持在途，等一会儿用原键、原请求体再发（F-AND-48；不重新记同意）。
    private func retryBusy(_ attempt: Attempt, backend: RealNameBackend, busy: Int) {
        state.error = nil
        let delay = Self.busyDelaysMillis[busy]
        let tasks = tasks
        tasks.begin()
        Task { @MainActor [weak self] in
            defer { tasks.end() }
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
            // 重发的是这次提交自己的键与请求体（等待期间改了表单也不混用）
            guard let self, !left, state.owner == attempt.owner, state.submitting else { return }
            send(attempt, backend: backend, busy: busy + 1)
        }
    }

    /// 本页重试只核对身份，不重发提交。
    public func recheckIdentity() {
        guard !left, state.awaitingIdentity else { return }
        deps.env.recheckIdentity()
    }

    public func whenIdle() async {
        await tasks.whenIdle()
    }

    public func resumeAfterIdentityConfirmed() {
        guard !left else { return }
        deferral.resume()
    }

    private func onResult(_ result: ApiResult) {
        if case .success = result {
            completed = true
            retained = nil
            // 实名完成：本会话按已实名放行并复查 realname_status，清掉已填的姓名与身份证号，出栈回发起页
            let owner = state.owner
            serial += 1
            state = RealNameSnapshot(done: Notice("realname.done", id: serial, assertive: false), owner: owner)
            deps.env.realnameSubmitted(owner)
            back()
            return
        }
        let error = WalletErrors.of(result)
        if error.kind == .retryAfter {
            deps.gates.realname.start(error.disableMillis)
        }
        let code = Self.code(result)
        var fields: [String] = []
        var consentType: String?
        if case let .failure(failed, _, data, _, effect, _) = result {
            let object = WalletJSON.parse(data) as? [String: Any] ?? [:]
            fields = failed == 20001 ? (object["fields"] as? [Any])?.compactMap { $0 as? String } ?? [] : []
            consentType = effect.consentType ?? object["consent_type"] as? String
        }
        let reopenConsent = code == Self.consentCode && consentType == ApiRealNameBackend.consentType
        // 键是否保留：有响应外壳的码按表（前置码、40901 沿用原键；键出现过结果未知时 10405 / 5xxxx / 42901 也不结束，D10-1018）；
        // 没有外壳（断连、超时、本地拒绝）结果未知或没发出，保留原键，断连另记「出现过结果未知」
        retained = retained.flatMap { Self.keyAfter(result, code: code, reopenConsent: reopenConsent, held: $0) }
        serial += 1
        state.submitting = false
        if reopenConsent {
            // 10004 id_verification：重开单独同意（默认不勾选），用户同意后先记同意、再用原键重放；不自动重放
            state.error = nil
            state.consentId = serial
            state.consentChecked = false
            deps.env.sensitiveOverlay(true)
            return
        }
        // 带 fields 的 20001 由字段旁的错误提示承担（首错定位并播报一次，iOS R2-06）；页内错误条只给没有字段的错误，避免同一事件播报两次
        state.error = fields.isEmpty ? Self.notice(error, code: code, id: serial) : nil
        state.fieldErrors = fields
        if !fields.isEmpty {
            state.fieldErrorId = serial
        }
        state.lockedToday = state.lockedToday || code == 30410
    }

    /// 实名完成后的出栈只在页面此刻可见时做，否则回到可见再做（共性第 37、41 条）。
    private func back() {
        guard visibility.now, let page else {
            deferredBack = true
            return
        }
        _ = deps.env.close(page: page)
    }

    public func setVisible(_ shown: Bool) {
        visibility.set(shown)
        guard shown, !left, deferredBack else { return }
        deferredBack = false
        back()
    }

    public func consumeDone(_ id: Int) {
        if state.done?.id == id {
            state.done = nil
        }
    }

    /// 会话换代：同步清空已填的姓名与身份证号；新身份由 App 传入。
    public func sessionChanged(_ owner: WalletOwner) {
        guard !left else { return }
        deferredBack = false
        completed = false
        retained = nil
        deferral.reset()
        if state.consentId != nil {
            deps.env.sensitiveOverlay(false)
        }
        state = RealNameSnapshot(owner: owner)
    }

    public func leave() {
        guard !left else { return }
        left = true
        retained = nil
        deferral.reset()
        if state.consentId != nil {
            deps.env.sensitiveOverlay(false)
        }
        state = RealNameSnapshot(owner: state.owner)
    }
}
