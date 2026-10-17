import CouliNetwork
import Foundation

/// 劳务协议页状态。
public struct LaborSnapshot: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case loading, content, error, unavailable
    }

    public var phase: Phase
    public var version: String?
    public var text: String?
    public var sha256: String?
    public var checked = false
    public var signing = false
    public var awaitingIdentity = false
    public var showsSigning: Bool {
        signing && !awaitingIdentity
    }

    public var showsRecheck: Bool {
        awaitingIdentity
    }

    public var error: Notice?
    /// 这份协议内容所属的身份（共性第 52 条）：读取时绑定，【同意并签署】回调带上它。
    public var owner: WalletOwner
}

/// 劳务协议签署执行器（LaborAgreement 路由，只有 in_app；BR-WDR-31，FUND-05，G02）：全文可滚动、可被读屏完整读到；勾选默认不勾，勾选后
/// 【同意并签署】可用；签署成功后出栈回 Withdraw（不重放、由用户再点【提交】）。接口契约没有（G02）：只由 Debug 假服务实现（`LaborBackend`）；
/// Release 全文区显示「协议正文暂未提供」，【同意并签署】置灰，不发请求。sha256 取服务端返回的值原样回传。只在主线程使用。
@MainActor
public final class LaborAgreementController: ObservableObject, IdentityResumable {
    @Published public private(set) var state: LaborSnapshot
    let tasks = SettlingTasks()
    let deps: WalletDeps
    public var page: UUID?
    public let visibility = PageVisibility()
    private var left = false
    private var serial = 0
    private var loadSeq = 0
    private var deferredBack = false
    private var completed = false
    /// 因身份暂时未知中止的读取与签署结果（FU-IOS-0712 整体重理：与各资金页同一套机制；签署不重放，只在身份确认后采用已到的结果）。
    public let deferral = IdentityDeferral()

    public init(deps: WalletDeps) {
        self.deps = deps
        // 本页的固定身份在构造时一次性取得（共性第 65 条）
        state = LaborSnapshot(phase: deps.labor == nil ? .unavailable : .loading, owner: deps.env.currentOwner())
    }

    public var gate: RetryAfterGate {
        deps.gates.labor
    }

    public var signEnabled: Bool {
        state.phase == .content && state.checked && !state.signing && !state.awaitingIdentity && !completed && !deps
            .gates.labor.active
    }

    public func load() {
        guard let backend = deps.labor, !left, !state.signing, !state.awaitingIdentity, !completed else { return }
        let owner = state.owner
        // 当前会话已不是本页身份：不读，内容不绑到别的账号；身份暂时未知：记待补取并结算为可重试的失败态
        guard admitLoad(deps.env.check(owner)) else { return }
        if deps.gates.read.active {
            serial += 1
            state.phase = .error
            state.error = Notice("error.42901", id: serial)
            return
        }
        // 读取请求序号（共性第 19 条同类）：重试、会话换代各发一次时，只收最新一次
        loadSeq += 1
        let request = loadSeq
        state.phase = .loading
        state.error = nil
        let tasks = tasks
        tasks.begin()
        Task { @MainActor [weak self] in
            defer { tasks.end() }
            let result = await backend.current(owner: owner.request)
            guard let self, !left, loadSeq == request, state.owner == owner, admitLoad(deps.env.check(owner)) else {
                return
            }
            loaded(result)
        }
    }

    /// 页面【重试】：照常读取；身份暂时未知时请 App 立即核对一次。
    public func retry() {
        load()
        if deferral.isPending {
            deps.env.recheckIdentity()
        }
    }

    /// 本页重试只核对身份，不重发签署。
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

    /// 读取的身份核对：暂时未知 → 记待补取，没有内容时结算为可重试的失败态（不是无出口的加载）；已换代 → 丢弃。
    private func admitLoad(_ check: IdentityCheck) -> Bool {
        deferral.admit(check, slot: "current", resume: { [weak self] in self?.load() }, settle: {
            if state.phase != .content {
                state.phase = .error
                state.error = nil
            }
        })
    }

    private func loaded(_ result: ApiResult) {
        let data: [String: Any]? = if case let .success(raw, _, _) = result {
            WalletJSON.parse(raw) as? [String: Any]
        } else {
            nil
        }
        if let version = data?["version"] as? String, let text = data?["text"] as? String,
           let sha = data?["text_sha256"] as? String {
            state = LaborSnapshot(phase: .content, version: version, text: text, sha256: sha, owner: state.owner)
            return
        }
        // 读取错误统一处理（共性第 3 条）：42901 更新共享截止时间、5xxxx 带 trace6
        let error = WalletErrors.of(result)
        if error.kind == .retryAfter {
            deps.gates.read.start(error.disableMillis)
        }
        serial += 1
        state = LaborSnapshot(phase: .error, error: error.notice(id: serial), owner: state.owner)
    }

    /// 勾选回调带渲染这份协议时的身份（共性第 59 条）：换代后到达的旧勾选不作用于新会话读到的协议。
    public func toggle(owner: WalletOwner) {
        guard !left, owner == state.owner, deps.env.isCurrent(owner), state.phase == .content, !state.signing else {
            return
        }
        state.checked.toggle()
    }

    /// 【同意并签署】：`owner` 是渲染这份协议时的身份（共性第 52 条）。
    public func sign(owner: WalletOwner) {
        guard let backend = deps.labor, signEnabled, !left, owner == state.owner, deps.env.isCurrent(owner),
              let version = state.version, let sha = state.sha256
        else { return }
        state.signing = true
        state.error = nil
        let tasks = tasks
        tasks.begin()
        Task { @MainActor [weak self] in
            defer { tasks.end() }
            let result = await backend.sign(version: version, textSha256: sha, owner: owner.request)
            self?.signArrived(result, owner: owner)
        }
    }

    /// 签署结果的身份核对：暂时未知 → 不采用、记下（身份确认后仍是本页身份才采用，不重放签署）；已换代 → 丢弃。
    private func signArrived(_ result: ApiResult, owner: WalletOwner) {
        guard !left, state.owner == owner else { return }
        guard deferral.admit(deps.env.check(owner), slot: "sign", resume: { [weak self] in
            self?.signArrived(result, owner: owner)
        }, settle: { state.awaitingIdentity = true }) else { return }
        state.awaitingIdentity = false
        signed(result)
    }

    private func signed(_ result: ApiResult) {
        state.signing = false
        if case .success = result {
            completed = true
            // 出栈回 Withdraw 是导航：页面此刻不可见时留到回到可见再做（共性第 37、41 条）
            back()
            return
        }
        let error = WalletErrors.of(result)
        if error.kind == .retryAfter {
            deps.gates.labor.start(error.disableMillis)
        }
        serial += 1
        state.error = error.notice(id: serial)
    }

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

    public func sessionChanged(_ owner: WalletOwner) {
        guard !left else { return }
        deferredBack = false
        completed = false
        loadSeq += 1
        deferral.reset()
        state = LaborSnapshot(phase: deps.labor == nil ? .unavailable : .loading, owner: owner)
        load()
    }

    public func leave() {
        left = true
        loadSeq += 1
        deferral.reset()
    }
}
