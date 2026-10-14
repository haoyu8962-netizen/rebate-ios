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

/// 实名认证执行器（RealName 路由；BR-ID-25，G01）：姓名去首尾空白；身份证号只收数字与 X，18 位，小写 x 转大写，不做校验位计算。提交前先弹
/// 单独同意（默认不勾选，点遮罩不关闭）。实名提交接口契约没有（G01）：只由 Debug 假服务实现（`RealNameBackend`）；Release 为 nil，【提交认证】
/// 置灰，显示「实名认证暂未开放」，不发任何请求。成功后刷新 realname_status、出栈回发起页（G05，不重放）。只在主线程使用。
@MainActor
public final class RealNameController: ObservableObject {
    public static let fieldName = "name"
    public static let fieldId = "id_no"

    @Published public private(set) var state: RealNameSnapshot
    let deps: WalletDeps
    public var page: UUID?
    public let visibility = PageVisibility()
    private var left = false
    private var serial = 0
    private var deferredBack = false

    public init(deps: WalletDeps) {
        self.deps = deps
        // 表单身份在构造时一次性取得（共性第 65 条）；之后只比较、不再读取当前会话来赋值
        state = RealNameSnapshot(owner: deps.env.currentOwner())
    }

    /// Release：契约补上实名接口之前不开放（G01）。
    public var available: Bool {
        deps.realname != nil
    }

    public var submitEnabled: Bool {
        available && !state.lockedToday && !state.submitting && !deps.gates.realname.active
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
    }

    public func onIdChange(_ text: String, owner: WalletOwner) {
        guard owns(owner) else { return }
        state.idNo = RealNameForm.acceptIdNo(current: state.idNo, next: text)
        state.fieldErrors.removeAll { $0 == Self.fieldId }
        state.error = nil
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

    /// 单独同意里勾选后点【同意并继续】：同意记录与实名提交在 Debug 假服务里一起发生（Release 不调 /v1/consents）。
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
        let key = deps.newKey()
        Task { @MainActor [weak self] in
            // 发送前核对：会话已换的不发（共性第 39、52 条）；后端实现也按固定身份核对
            guard let self, deps.env.isCurrent(owner) else {
                self?.state.submitting = false
                return
            }
            let result = await backend.submit(name: input.name, idNo: input.idNo, idempotencyKey: key,
                                              owner: owner.request)
            guard !left, state.owner == owner, deps.env.isCurrent(owner) else { return }
            onResult(result)
        }
    }

    private func onResult(_ result: ApiResult) {
        if case .success = result {
            // 实名完成：清掉已填的姓名与身份证号，刷新 realname_status，出栈回发起页
            serial += 1
            state = RealNameSnapshot(done: Notice("realname.done", id: serial, assertive: false), owner: state.owner)
            deps.env.realnameChanged()
            back()
            return
        }
        let error = WalletErrors.of(result)
        if error.kind == .retryAfter {
            deps.gates.realname.start(error.disableMillis)
        }
        var code: Int?
        var fields: [String] = []
        if case let .failure(failed, _, data, _, _, _) = result {
            code = failed
            let object = WalletJSON.parse(data) as? [String: Any] ?? [:]
            fields = failed == 20001 ? (object["fields"] as? [Any])?.compactMap { $0 as? String } ?? [] : []
        }
        let key: String = if code == 20001 {
            "error.20001"
        } else if let code, code / 10000 != 5, DefaultTexts.text("error.\(code)") != nil {
            "error.\(code)"
        } else {
            error.textKey
        }
        serial += 1
        state.submitting = false
        // 带 fields 的 20001 由字段旁的错误提示承担（首错定位并播报一次，iOS R2-06）；页内错误条只给没有字段的错误，避免同一事件播报两次
        state.error = fields.isEmpty
            ? Notice(key, id: serial, traceId: error.traceId, showTrace6: error.showTrace6) : nil
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
        if state.consentId != nil {
            deps.env.sensitiveOverlay(false)
        }
        state = RealNameSnapshot(owner: owner)
    }

    public func leave() {
        guard !left else { return }
        left = true
        if state.consentId != nil {
            deps.env.sensitiveOverlay(false)
        }
        state = RealNameSnapshot(owner: state.owner)
    }
}
