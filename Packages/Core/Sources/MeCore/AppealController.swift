import Combine
import CouliNetwork
import Foundation
import WalletCore

/// 申诉页的状态。`override` 为 submit 时显示提交页（维持后点【再次申诉】）。
public struct AppealState {
    public enum Phase: Equatable, Sendable {
        case loading, content, error
    }

    public var phase: Phase = .loading
    public var risk: [String: Any]?
    public var appeals: [[String: Any]] = []
    public var override: String?
    public var input = ""
    public var submitting = false
    public var fieldError = false
    /// 字段错误事件编号（读屏焦点移到错误提示、播报一次，FieldErrorCue）。
    public var errorEvent = 0
    public var error: MeNotice?
    public var loadError: MeNotice?
    /// 退出确认框的一次性编号（R1-02）；nil = 没有显示。
    public var logoutDialog: Int?
    public var version = 0

    public init() {}
}

/// 账户申诉执行器（Appeal 路由；brief §2.11，§0 第 4 条；G10–G15；BR-ID-36、BR-TEXT-23）。构造时固定身份；只做账户申诉（G12）：
/// - 进入串行取 GET /v1/me 与 listAppeals（每个响应先处理它自己的限流，失败即停，Android R1-05）：列表里 target_type=account 的最新一条 → 提交 /
///   进度 / 结果版式（G15）；当前是否受限一律按本次 risk.state（`AppealCopy`）；列表读取失败或坏数据时清掉摘要、显示错误态（鸿蒙 R1-12）；
/// - 提交：说明去首尾空白后非空才可用；body {target_type: account, content}（不带 target_id，G11）；每次点击生成新的 Idempotency-Key，同一次点击的
///   传输重试沿用原键（网络层，G14）；结果未知不自动重发；成功 → 先推进读取世代、取消旧读取（共性第 29 条）再一次性切到进度态（共性第 35 条，
///   不新开页）；20001 字段旁提示；42901 申诉提交禁用期（执行层 + 页面）；表外码走统一错误消息函数（G13）；
/// - 不显示处理时限或截止时刻。离开页面：输入与进度清空；已发出的提交不取消，响应不改已出栈的页面。
@MainActor
public final class AppealController: ObservableObject, IdentityResumable {
    public static let route = "Appeal"
    public static let submitOperation = "submitAppeal"
    public static let wallet = "Wallet"
    public static let home = "Home"
    public static let messages = "Messages"

    public let identity: MeIdentity
    public let deps: MeDeps
    public let page: UUID?
    public let enteredBy10006: Bool
    @Published public private(set) var state = AppealState()
    private var left = false
    private var seq = 0
    private var ids = 0
    private let requests = MeRequests()
    private let deferral = IdentityDeferral()

    public init(deps: MeDeps, identity: MeIdentity, page: UUID?) {
        self.deps = deps
        self.identity = identity
        self.page = page
        enteredBy10006 = deps.env.enteredBy10006(identity)
    }

    public var alive: Bool {
        !left && deps.env.isCurrent(identity)
    }

    public var readGate: RetryAfterGate {
        deps.gates.read
    }

    public var submitGate: RetryAfterGate {
        deps.gates.appeal
    }

    /// 本次 risk.state（取不到为 nil）。
    public var riskState: String? {
        state.risk?["state"] as? String
    }

    /// G10 的版式组：frozen → 冻结组；banned → 封禁组；appealing / normal 按本次运行是否因 10006 进入。
    public var frozenLayout: Bool {
        switch riskState {
        case "frozen": true
        case "banned": false
        default: !enteredBy10006
        }
    }

    public var layout: String {
        state.override ?? AppealView.layout(state.appeals)
    }

    public var latest: [String: Any]? {
        AppealView.latestAccount(state.appeals)
    }

    public var submitEnabled: Bool {
        AppealForm.body(state.input) != nil && !state.submitting
    }

    private func nextId() -> Int {
        ids += 1
        return ids
    }

    /// 进入、【重试】、回到本页。
    public func load() {
        guard !left, identity.member else { return }
        guard admitRead() else {
            if deferral.isPending {
                deps.env.recheckIdentity()
            }
            return
        }
        if readGate.active {
            failed(MeNotice(MeCodes.rateKey, id: nextId()))
            return
        }
        seq += 1
        let request = seq
        requests.cancelAll()
        if state.phase != .content {
            state.phase = .loading
            state.loadError = nil
        }
        let probe = readGate.probe()
        requests.send(deps.api, ApiCall(operationId: MeRepository.operation), probe: probe,
                      expected: identity.request) { [weak self] result in
            guard let self, current(request) else { return }
            // 每个响应到达即先处理它自己的限流，再决定是否续发（共性第 22 条）：getMe 失败就不再发 listAppeals
            guard case let .success(data, _, _) = result, let me = MeJson.me(MeJson.object(data)) else {
                readFailed(result, probe: probe)
                return
            }
            loadAppeals(request, risk: me.risk)
        }
    }

    private func loadAppeals(_ request: Int, risk: [String: Any]) {
        if readGate.active {
            failed(MeNotice(MeCodes.rateKey, id: nextId()))
            return
        }
        let probe = readGate.probe()
        requests.send(deps.api, ApiCall(operationId: RiskNoticeController.listAppeals), probe: probe,
                      expected: identity.request) { [weak self] result in
            guard let self, current(request) else { return }
            guard case let .success(data, _, _) = result, let list = MeJson.appealList(MeJson.object(data)) else {
                readFailed(result, probe: probe)
                return
            }
            state.phase = .content
            state.risk = risk
            state.appeals = list.items
            state.loadError = nil
            state.version += 1
        }
    }

    /// 一次读取失败：坏数据（code=0 却解析不了）按 50001 + trace6；其余按统一读取失败处理（被作废的静默）。
    private func readFailed(_ result: ApiResult, probe: SendProbe) {
        if case let .success(_, traceId, _) = result {
            failed(MeNotice("error.50001", id: nextId(), traceId: traceId, showTrace6: true))
        } else if let notice = MeErrors.readFailure(result, probe: probe, gate: readGate, id: nextId) {
            failed(notice)
        }
    }

    /// 读取失败：申诉摘要清空并重新发布（鸿蒙 R1-12），不把上一轮结论继续当最近一次结果。
    private func failed(_ notice: MeNotice) {
        state.phase = .error
        state.appeals = []
        state.risk = nil
        state.loadError = notice
        state.version += 1
    }

    private func current(_ request: Int) -> Bool {
        !left && seq == request && admitRead()
    }

    /// 申诉说明输入（渲染时的执行器）。
    public func input(_ text: String) {
        guard alive, !state.submitting else { return }
        state.input = text
        state.fieldError = false
        state.error = nil
    }

    /// 【提交申诉】（渲染时的版本）。返回是否发出。
    @discardableResult
    public func submit(version: Int) -> Bool {
        guard alive, !state.submitting, state.version == version, layout == AppealView.submit else { return false }
        if submitGate.active {
            state.error = MeNotice(MeCodes.rateKey, id: nextId())
            state.errorEvent += 1
            return false
        }
        guard let body = AppealForm.body(state.input) else { return false }
        // 每次用户点击生成新键；同一次点击的传输重试沿用原键（网络层，G14）
        let call = ApiCall(operationId: Self.submitOperation, body: MeJson.text(body), idempotencyKey: deps.newKey())
        let probe = submitGate.probe()
        let identity = identity
        let deps = deps
        let gate = submitGate
        state.submitting = true
        state.error = nil
        state.fieldError = false
        Task { @MainActor [weak self] in
            let result = await deps.api.send(call, isValid: { true }, sendAllowed: probe.allowed,
                                             expected: identity.request)
            guard deps.env.isCurrent(identity) else { return }
            let gated = probe.gated(result)
            let outcome = gated ? WriteOutcome(WriteOutcome.retryAfter, textKey: MeCodes.rateKey, keepInput: true)
                : AppealOutcome.model(result: MeResultInput.of(result))
            if outcome.actionRaw == WriteOutcome.retryAfter, !gated {
                gate.start(outcome.disableMs ?? MeCodes.defaultRetryMillis)
            }
            // 写请求离开页面不取消，但响应回来不得改动已出栈的页面
            guard let self, alive else { return }
            settle(outcome, result: result)
        }
        return true
    }

    private func settle(_ outcome: WriteOutcome, result: ApiResult) {
        state.submitting = false
        switch outcome.actionRaw {
        case WriteOutcome.progress:
            // 成功：先推进读取世代并取消提交之前发起的读取（共性第 29 条），再一次性恢复页面（共性第 35 条）：切到 CONTENT、清掉旧的加载错误、
            // 应用返回的申诉单（处理中再次提交服务端返回原单，同样进度态）。当前风险状态不从申诉单推算，仍只取 getMe（risk 保持原值）
            seq += 1
            requests.cancelAll()
            let appeal: [String: Any]? = if case let .success(data, _, _) = result {
                MeJson.appeal(MeJson.object(data))
            } else {
                nil
            }
            if let appeal {
                let id = appeal["appeal_id"] as? String
                state.appeals = [appeal] + state.appeals.filter { $0["appeal_id"] as? String != id }
                state.override = nil
            } else {
                state.override = AppealView.progress
            }
            state.phase = .content
            state.loadError = nil
            state.input = ""
            state.version += 1
        case WriteOutcome.fieldError:
            state.fieldError = true
            state.error = MeNotice(outcome.textKey ?? "error.20001", id: nextId())
            state.errorEvent += 1
        case WriteOutcome.errorTrace6:
            state.error = MeNotice(outcome.textKey ?? "error.50001", id: nextId(), traceId: result.traceIdValue,
                                   showTrace6: true)
            state.errorEvent += 1
        case WriteOutcome.forceUpdate, WriteOutcome.riskNotice:
            break
        default:
            state.error = MeNotice(outcome.textKey ?? MeNotice.unfinishedKey, id: nextId(), serverMsg: result.msgValue)
            state.errorEvent += 1
        }
    }

    /// 【再次申诉】（维持结果页）：回到提交页（客户端不计次数、不预判第 4 次，G13）。
    public func again(version: Int) {
        guard alive, state.version == version, layout == AppealView.resultUpheld else { return }
        state.override = AppealView.submit
        state.input = ""
        state.version += 1
    }

    /// 结果页按钮：go_wallet / start / view_messages / contact_cs。
    public func action(_ raw: String, version: Int) {
        guard alive, state.version == version else { return }
        switch raw {
        case "go_wallet": deps.env.open(Self.wallet, params: [:], from: page)
        case "start": deps.env.open(Self.home, params: [:], from: page)
        case "view_messages": deps.env.open(Self.messages, params: [:], from: page)
        case "contact_cs": deps.env.customerService(from: Self.route)
        default: break
        }
    }

    public func contactCs() {
        guard alive else { return }
        deps.env.customerService(from: Self.route)
    }

    public func askLogout() {
        guard alive else { return }
        ids += 1
        state.logoutDialog = ids
    }

    public func cancelLogout(_ dialog: Int) {
        if state.logoutDialog == dialog {
            state.logoutDialog = nil
        }
    }

    /// 【退出登录】确认（确认框生成时的编号）：只认正显示的这一个，用过即作废；再核对身份与页面（R1-02）。
    public func confirmLogout(_ dialog: Int) {
        guard state.logoutDialog == dialog else { return }
        state.logoutDialog = nil
        guard alive else { return }
        deps.env.logout(identity, from: page)
    }

    /// 出栈、换代：作废读请求，清空输入与进度（申诉草稿不残留，G29）。
    public func leave() {
        guard !left else { return }
        left = true
        deferral.reset()
        seq += 1
        requests.cancelAll()
        state = AppealState()
    }

    public var hasLeft: Bool {
        left
    }
}

extension AppealController {
    private func settleUnknown() {
        state.phase = state.risk == nil ? .error : .content
        state.loadError = MeNotice(MeNotice.unfinishedKey, id: nextId())
    }

    private func admitRead() -> Bool {
        deferral.admit(deps.env.check(identity), slot: "read", resume: { [weak self] in self?.load() }, settle: {
            settleUnknown()
        })
    }

    public func resumeAfterIdentityConfirmed() {
        guard !left else { return }
        deferral.resume()
    }
}
