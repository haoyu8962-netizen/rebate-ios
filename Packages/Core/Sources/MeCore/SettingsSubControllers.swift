import Combine
import CouliNetwork
import Foundation
import WalletCore

/// 修改昵称子页的状态（输入、计数、错误、保存中）。
public struct NicknameState: Equatable, Sendable {
    public var input: String
    public var check: NicknameCheck
    /// 字段错误（20001、本地校验）；`error` 是提示内容。
    public var fieldError = false
    public var error: MeNotice?
    public var saving = false
    /// 字段错误事件编号（读屏焦点移到错误提示、播报一次，FieldErrorCue）。
    public var errorEvent = 0
    public var version = 0
}

/// 修改昵称子页执行器（Settings 页内子页，G01、G27、G32；照 SettingsNickname 一族）。构造时固定身份与原昵称；只在 Debug 假服务给了后端时存在
/// （Release 昵称行不可点、不建本执行器）。输入、清空、保存回调捕获渲染时的执行器与版本（共性第 6、59 条）。
/// - 【保存】：去首尾空白后 1–16 字素才可用，与当前昵称相同时不可用；42901 按 Retry-After 禁用（执行层 + 页面）；不自动重试写请求；
/// - 成功：推进 Me 读取世代（保存前发出的 getMe 晚到不覆盖），轻提示「昵称已修改」，只关发起的这个子页；
/// - 20001 nickname_sensitive / 20001 / 30415 字段旁或页内提示，保留输入；5xxxx 带 trace6。
@MainActor
public final class NicknameController: ObservableObject {
    public let identity: MeIdentity
    public let current: String
    public let deps: MeDeps
    private let backend: NicknameBackend
    private weak var host: SettingsController?
    @Published public private(set) var state: NicknameState
    private var left = false
    private var ids = 0

    init(deps: MeDeps, identity: MeIdentity, current: String, backend: NicknameBackend, host: SettingsController) {
        self.deps = deps
        self.identity = identity
        self.current = current
        self.backend = backend
        self.host = host
        state = NicknameState(input: current, check: NicknameInput.model(current: current, input: current))
    }

    public var alive: Bool {
        !left && deps.env.isCurrent(identity)
    }

    public var gate: RetryAfterGate {
        deps.gates.nickname
    }

    /// 本地校验的错误键（R2-04）：去首尾空白后为空 → nickname.empty；超过 16 字素 → nickname.too_long；其余 nil。
    public static let emptyKey = "nickname.empty"
    public static let tooLongKey = "nickname.too_long"

    static func localErrorKey(_ check: NicknameCheck) -> String? {
        if check.length == 0 {
            return emptyKey
        }
        return check.length > NicknameInput.max ? tooLongKey : nil
    }

    /// 输入（渲染时的执行器）：清掉上一次的错误提示；本地校验错误进入统一错误事件流程（R2-04）——错误出现或变化（空 ↔ 超长）时推进
    /// `errorEvent`（页面播报一次、布局后移焦点），同一错误持续时沿用原提示、不重复播报。
    public func input(_ text: String) {
        guard alive, !state.saving else { return }
        let previous = state.error.flatMap { [Self.emptyKey, Self.tooLongKey].contains($0.key) ? $0 : nil }
        state.input = text
        state.check = NicknameInput.model(current: current, input: text)
        state.fieldError = false
        state.error = nil
        guard let key = Self.localErrorKey(state.check) else { return }
        if let previous, previous.key == key {
            state.error = previous
            state.fieldError = true
            return
        }
        show(MeNotice(key, id: nextId()), field: true)
    }

    /// 清除按钮（读屏「清除昵称」）。
    public func clear() {
        input("")
    }

    /// 【保存】（渲染时的版本）。
    public func save(version: Int) {
        guard alive, !state.saving, state.version == version, state.check.saveEnabled else { return }
        if gate.active {
            show(MeNotice(MeCodes.rateKey, id: nextId()), field: false)
            return
        }
        let nickname = state.check.trimmed
        let probe = gate.probe()
        let identity = identity
        let deps = deps
        let gate = gate
        let backend = backend
        state.saving = true
        state.error = nil
        Task { @MainActor [weak self] in
            let result = await backend.save(nickname: nickname, owner: identity.request, allowed: probe.allowed)
            // 共享结算按保存时的身份（会话已换的不动新会话）：禁用期、Me 读取世代
            guard deps.env.isCurrent(identity) else { return }
            let gated = probe.gated(result)
            let outcome = gated ? WriteOutcome(WriteOutcome.retryAfter, textKey: MeCodes.rateKey, keepInput: true)
                : NicknameOutcome.model(result: MeResultInput.of(result))
            if outcome.actionRaw == WriteOutcome.retryAfter, !gated {
                gate.start(outcome.disableMs ?? MeCodes.defaultRetryMillis)
            }
            if outcome.actionRaw == WriteOutcome.saved {
                deps.repo.nicknameSaved(identity, nickname: nickname, page: self?.host)
            }
            // 写请求离开页面不取消，但响应回来不得改动已关闭的子页
            guard let self, alive else { return }
            settle(outcome, result: result)
        }
    }

    private func settle(_ outcome: WriteOutcome, result: ApiResult) {
        state.saving = false
        switch outcome.actionRaw {
        case WriteOutcome.saved:
            host?.nicknameSaved(self)
        case WriteOutcome.fieldError:
            show(MeNotice(outcome.textKey ?? "error.20001", id: nextId()), field: true)
        case WriteOutcome.errorTrace6:
            show(
                MeNotice(
                    outcome.textKey ?? "error.50001",
                    id: nextId(),
                    traceId: result.traceIdValue,
                    showTrace6: true
                ),
                field: false
            )
        case WriteOutcome.forceUpdate, WriteOutcome.riskNotice:
            break
        default:
            show(MeNotice(outcome.textKey ?? MeNotice.unfinishedKey, id: nextId(), serverMsg: result.msgValue),
                 field: outcome.actionRaw == WriteOutcome.retryAfter ? false : outcome.textKey == "error.30415")
        }
    }

    private func show(_ notice: MeNotice, field: Bool) {
        state.error = notice
        state.fieldError = field
        state.errorEvent += 1
        state.version += 1
    }

    private func nextId() -> Int {
        ids += 1
        return ids
    }

    /// 关闭子页、出栈、换代：输入清空（昵称草稿不残留，G29）。
    func leave() {
        guard !left else { return }
        left = true
        state = NicknameState(
            input: "",
            check: NicknameInput.model(current: current, input: ""),
            version: state.version + 1
        )
    }
}

/// 通知设置子页的状态。
public struct NotifySettingsState: Equatable, Sendable {
    /// 系统通知已开启（nil = 还在查）。
    public var systemGranted: Bool?
    /// 服务类推送开关（nil = 没有后端或还没取到）。
    public var service: Bool?
    public var loading = false
    public var switching = false
    public var error: MeNotice?
    public var toast: MeNotice?
    public var version = 0
}

/// 通知设置子页执行器（G02、OPS-16、BR-WATCH-19 ③）：系统通知状态只查不申请（未开启 → 提示条 perm.push.denied_forever +【去设置】，跳系统设置，
/// 属用户主动，不受 48 小时限制）；「服务类推送」开关只在 Debug 假服务给了后端时显示（Release 不显示开关行，只留说明句）；切换失败回到切换前的值
/// 并提示；回前台重新查询系统状态。构造时固定身份。
@MainActor
public final class NotifySettingsController: ObservableObject {
    public let identity: MeIdentity
    public let deps: MeDeps
    @Published public private(set) var state = NotifySettingsState()
    private var left = false
    private var ids = 0
    private var seq = 0
    private var systemSeq = 0
    private let requests = MeRequests()

    init(deps: MeDeps, identity: MeIdentity) {
        self.deps = deps
        self.identity = identity
    }

    public var alive: Bool {
        !left && deps.env.isCurrent(identity)
    }

    public var hasSwitch: Bool {
        deps.notify != nil
    }

    public var gate: RetryAfterGate {
        deps.gates.notify
    }

    /// 进入：查系统状态，取开关（Debug 后端）。
    public func load() {
        refreshSystem()
        guard alive, let backend = deps.notify else { return }
        if gate.active {
            state.error = MeNotice(MeCodes.rateKey, id: nextId())
            return
        }
        seq += 1
        let mine = seq
        state.loading = true
        state.error = nil
        let probe = gate.probe()
        let identity = identity
        Task { @MainActor [weak self] in
            let result = await backend.get(owner: identity.request, allowed: probe.allowed)
            guard let self, alive, seq == mine else { return }
            state.loading = false
            if case let .success(data, _, _) = result,
               let service = JSONKind.bool((MeJson.object(data) as? [String: Any])?["service"]) {
                state.service = service
                state.version += 1
                return
            }
            state.error = MeErrors.readFailure(result, probe: probe, gate: gate, id: nextId)
            state.version += 1
        }
    }

    /// 回前台、从系统设置回来：重新查询系统状态（只查不申请）。
    public func refreshSystem() {
        guard alive else { return }
        systemSeq += 1
        let mine = systemSeq
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await deps.env.permissionStatus("push")
            guard alive, systemSeq == mine else { return }
            state.systemGranted = status == "granted"
        }
    }

    /// 【去设置】：跳系统里本 App 的通知设置（不经 PermissionRequester 申请）。
    public func goSettings() {
        guard alive else { return }
        deps.env.openNotificationSettings()
    }

    /// 开关切换（渲染时的版本）：先按新值显示，失败回到切换前的值并提示。
    public func toggle(_ on: Bool, version: Int) {
        guard alive, !state.switching, state.version == version, let before = state.service, before != on,
              let backend = deps.notify
        else { return }
        if gate.active {
            state.toast = MeNotice(MeCodes.rateKey, id: nextId())
            return
        }
        let probe = gate.probe()
        let identity = identity
        let gate = gate
        let deps = deps
        state.service = on
        state.switching = true
        state.version += 1
        Task { @MainActor [weak self] in
            let result = await backend.put(service: on, owner: identity.request, allowed: probe.allowed)
            guard deps.env.isCurrent(identity) else { return }
            let error = MeErrors.of(result, probe: probe)
            if error.kind == .retryAfter {
                gate.start(error.disableMillis)
            }
            guard let self, alive else { return }
            state.switching = false
            if case .success = result {
                state.version += 1
                return
            }
            state.service = before
            state.version += 1
            switch error.kind {
            case .gated, .retryAfter:
                state.toast = MeNotice(MeCodes.rateKey, id: nextId())
            case .server:
                state.toast = MeErrors.notice(error, id: nextId())
            case .cancelled, .forceUpdate:
                break
            default:
                state.toast = MeNotice("notify.switch_failed", id: nextId())
            }
        }
    }

    public func consumeToast(_ id: Int) {
        if state.toast?.id == id {
            state.toast = nil
        }
    }

    private func nextId() -> Int {
        ids += 1
        return ids
    }

    func leave() {
        guard !left else { return }
        left = true
        seq += 1
        systemSeq += 1
        requests.cancelAll()
        state = NotifySettingsState(version: state.version + 1)
    }
}

extension NotifySettingsState {
    init(version: Int) {
        self.init()
        self.version = version
    }
}

extension ApiResult {
    /// 业务错误的服务端 msg（表外码兜底，G13）。
    var msgValue: String? {
        if case let .failure(_, msg, _, _, _, _) = self {
            return msg
        }
        return nil
    }
}
