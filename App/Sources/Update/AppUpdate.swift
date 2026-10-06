import Combine
import Config
import DesignSystem
import Foundation
import Generated
import Router
import Update

/// App 的强更检查接线（APP-02c；03 §4.1、§4.4，BR-ID-01）：`UpdateGate` 的结论 → Router 的 update 状态源
/// （`AppUpdate+Router.swift`）与界面（ForceUpdate 页、可关闭提示）。
///
/// - 检查时机：冷启动必查、回前台按间隔复查；只在「环境 settled 且已同意隐私政策」时发——同意前只允许请求协议文本与
///   /v1/config（BR-ID-11），基本模式不发 check（`GET /v1/app-versions/check` 不在匿名白名单）。冷启动时还不能查的，
///   等能查了（同意后）再补这次冷启动检查；离开基本模式后照常检查。
/// - 检查失败不拦用户自己的操作（Gate 保持上次已知结论或 unknown）。Release 的检查器永远失败（TODO(APP-03)）。
/// - 10405 入口 `on10405` 给网络层（APP-03）调用：直接进 below_min。
/// - 【去更新】按 Gate 选店；一家都不行 → 强更页显示 `app_update.unavailable` 与【重试】；【重试】重新检查再选。
@MainActor
final class AppUpdate: ObservableObject {
    /// 界面要的东西。
    struct ViewState: Equatable {
        var status: UpdateStatus
        var showPrompt: Bool
        var targetVersion: String?
        /// 最近一次成功检查的结果（标题、更新内容）。
        var result: UpdateCheckResult?
        /// 强更页没有可去的商店：显示 `app_update.unavailable` 与【重试】，不给任何下载地址。
        var forceUnavailable: Bool
        /// 正在重试检查或打开商店（按钮防连点、显示进行中）。
        var working: Bool
    }

    @Published private(set) var ui: ViewState
    /// 可关闭提示点了【去更新】时的目标版本（R1-05）：同一目标版本本次运行不再弹，更高的 latest 照样再弹。
    /// 【暂不更新】不用它，直接由 Gate 按 latest 记录。
    @Published private(set) var promptGoneToStoreFor: String?
    /// 可关闭提示【去更新】时来源商店打不开：轻提示 `app_update.unavailable`（可选更新不改去别家，BR-ID-01）。
    @Published var toast: CouliToastMessage?

    /// 强更结论变化（状态、检查开始或结束）后调用（AppRouting：Router 状态源、ForceUpdate 进出、启动协调）。
    var onChange: (() -> Void)?

    let gate: UpdateGate
    private let checker: any UpdateChecker
    private let stores: any StoreAccess
    let clock: () -> Int64
    /// 本进程启动的时刻：冷启动检查还没能发出（隐私未决等）时，Router 的等待从这里起算。
    let launchedAt: Int64

    private(set) var coldStartIssued = false
    private(set) var canCheck = false
    private(set) var basicMode = false
    /// 生命周期检查（冷启动 / 回前台）发出的时刻。
    private(set) var checkStartedAt: Int64?
    private var requestInFlight = false
    /// 检查请求结束后要做的事（【去更新】/【重试】的再选店）；请求已在进行时排在这里，不另发。
    private var afterRequest: [() -> Void] = []
    /// 用户点了【去更新】但没有商店可去（或打开失败）；下一次检查有结果时清掉、重新核对。
    private var storeChoiceFailed = false

    init(gate: UpdateGate, checker: any UpdateChecker, stores: any StoreAccess,
         clock: @escaping () -> Int64) {
        self.gate = gate
        self.checker = checker
        self.stores = stores
        self.clock = clock
        let now = clock()
        launchedAt = now
        ui = Self.makeUI(gate: gate, now: now, storeChoiceFailed: false, working: false)
    }

    // MARK: - 本构建的组装

    /// 本构建的强更记录键：Release 读写 `AppNamespace.updateRecordKey`；Debug / Staging 的检查器是调试假数据，
    /// 结论写在另一把键（`DebugUpdateScenario.recordKey`），假结果不会进 Release 读取的那一把（编排者裁定）。
    static var recordKey: String {
        #if DEBUG
        DebugUpdateScenario.recordKey
        #else
        AppNamespace.updateRecordKey
        #endif
    }

    /// 本构建的检查器：Debug / Staging 用调试面板的假数据（契约 openapi 示例），Release 用永远失败的占位
    /// （TODO(APP-03)），所以 Release 一直按 unknown 处理、不会误拦用户。
    static func makeChecker() -> any UpdateChecker {
        #if DEBUG
        DebugUpdateChecker()
        #else
        FailingUpdateChecker()
        #endif
    }

    static func makeForBuild(defaults: UserDefaults = .standard) -> AppUpdate {
        let stores = AppStoreAccess()
        let gate = UpdateGate(
            store: UserDefaultsUpdateStore(defaults: defaults, key: recordKey),
            clock: PendingActionStore.wallClockMillis,
            appVersion: AppRouting.appVersion,
            platform: AppStoreAccess.platform,
            channel: AppStoreAccess.channel,
            installSource: stores.installSource
        )
        return AppUpdate(gate: gate, checker: makeChecker(), stores: stores, clock: PendingActionStore.wallClockMillis)
    }

    // MARK: - 检查时机

    /// 环境闸门或隐私结论变化（AppRouting 在通知 Router 之前调用）。
    func conditionsChanged(environmentSettled: Bool, consented: Bool, basicMode: Bool) {
        let couldCheck = canCheck
        canCheck = environmentSettled && consented
        self.basicMode = basicMode
        let now = clock()
        if canCheck, !coldStartIssued {
            coldStartIssued = true
            if gate.onColdStart(now: now) {
                startLifecycleCheck(now: now)
                return
            }
        } else if canCheck, !couldCheck, !lifecycleCheckInFlight, gate.onForeground(now: now) {
            // 离开基本模式（重新同意）后照常检查（BR-ID-11 细则「基本模式与强更检查」）。
            startLifecycleCheck(now: now)
            return
        }
        publish()
    }

    /// App 回到前台：距上一次成功检查超过间隔才查。生命周期检查已在途时什么都不做——不重置检查起点与 5 秒等待、
    /// 不另发请求（R2-02：反复切前后台不能把等待一再延后）。
    func enteredForeground() {
        guard canCheck, coldStartIssued, !lifecycleCheckInFlight else { return }
        let now = clock()
        if gate.onForeground(now: now) {
            startLifecycleCheck(now: now)
        }
    }

    /// 生命周期检查（冷启动 / 回前台）已发出、结果还没回来。
    private var lifecycleCheckInFlight: Bool {
        checkStartedAt != nil && gate.isChecking
    }

    private func startLifecycleCheck(now: Int64) {
        checkStartedAt = now
        publish()
        request()
    }

    /// 发一次检查请求（同一时刻只有一个）；结果交给 Gate。`then` 在结果投递后调用一次；
    /// 已有请求在进行时不另发，`then` 跟着那一次的结果。`then` 里不得再进检查入口（R1-04：检查器可能同步回调）。
    private func request(then: (() -> Void)? = nil) {
        if let then {
            afterRequest.append(then)
        }
        guard !requestInFlight else { return }
        requestInFlight = true
        checker.check { [weak self] outcome in
            guard let self else { return }
            requestInFlight = false
            let now = clock()
            switch outcome {
            case let .success(result):
                gate.apply(result: result, now: now)
                storeChoiceFailed = false
            case .failure:
                gate.applyFailure(now: now)
            }
            checkStartedAt = nil
            setWorking(false)
            publish()
            let waiting = afterRequest
            afterRequest = []
            for next in waiting {
                next()
            }
        }
    }

    // MARK: - 接口层拦截

    /// 网络层收到 10405（APP-03 调用）：直接进 below_min。强更页内容取最近一次成功的检查结果，没有时立即再查一次（03 §4.2）。
    func on10405(minSupported: String?) {
        gate.on10405(minSupported: minSupported, now: clock())
        if gate.lastResult == nil, canCheck {
            request()
        }
        publish()
    }

    // MARK: - 强更页

    /// 【去更新】：按 Gate 选店并打开；一家都不行 → 显示「暂时无法更新」与【重试】。没有检查结果时先查一次再选，
    /// 这一次也失败（仍没有结果）就停在「暂时无法更新」，等用户再点【重试】（R1-04：一次点击最多一次检查，不自动重试）。
    func forceGoStore() {
        guard !ui.working else { return }
        guard let result = gate.lastResult else {
            checkThenPick()
            return
        }
        openStore(for: result)
    }

    /// 【重试】：重新调 check，再选一次（03 §4.1）。
    func retry() {
        guard !ui.working else { return }
        checkThenPick()
    }

    /// 查一次再选店。不能发检查时（基本模式）只按已有结果重新选；检查失败时按已有结果选，没有结果 → 「暂时无法更新」。
    /// 选店本身不会再发检查，所以同步回调的检查器也不会递归（R1-04）。
    private func checkThenPick() {
        guard canCheck else {
            pickAfterCheck()
            return
        }
        setWorking(true)
        request { [weak self] in
            self?.pickAfterCheck()
        }
    }

    private func pickAfterCheck() {
        guard ui.status == .belowMin else { return }
        guard let result = gate.lastResult else {
            storeChoiceFailed = true
            publish()
            return
        }
        storeChoiceFailed = false
        openStore(for: result)
    }

    private func openStore(for result: UpdateCheckResult) {
        let choice = gate.pickStore(result: result, now: clock(), canOpen: stores.canOpen)
        guard let key = choice.storeKey else {
            storeChoiceFailed = true
            publish()
            return
        }
        setWorking(true)
        stores.open(key) { [weak self] opened in
            guard let self else { return }
            setWorking(false)
            if !opened {
                // TODO(N-17): 打开失败接着看下一家（rule-gaps G08）；商店打开方式补齐前对照表全为 null，走不到这里。
                storeChoiceFailed = true
            }
            publish()
        }
    }

    // MARK: - 可关闭提示

    /// 可关闭提示：Gate 说要提示（「暂不更新」记的版本由 Gate 比较），且本次运行没有对同一目标版本点过【去更新】（R1-05）。
    var showsPrompt: Bool {
        guard ui.status == .belowRecommended, ui.showPrompt else { return false }
        guard let gone = promptGoneToStoreFor else { return true }
        guard let target = ui.targetVersion,
              let order = UpdateGate.compareVersions(a: target, b: gone) else { return false }
        return order > 0
    }

    /// 【暂不更新】：按提示时的 latest_version 记在本机（Gate），同一版本不再提示，更高版本再提示（R1-05）。
    func dismissPrompt() {
        gate.dismissPrompt(now: clock())
        publish()
    }

    /// 【去更新】：只看来源商店（读不到来源时看默认商店），打不开就轻提示，不改去别家（BR-ID-01）。
    /// 按目标版本临时关闭提示（本次运行同一版本不再弹，更高版本再弹，R1-05）。
    func promptGoStore() {
        promptGoneToStoreFor = ui.targetVersion
        guard let result = gate.lastResult else { return }
        let choice = gate.pickStore(result: result, now: clock(), canOpen: stores.canOpen)
        guard let key = choice.storeKey else {
            toast = CouliToastMessage(DefaultTexts.text("app_update.unavailable") ?? "")
            return
        }
        stores.open(key) { [weak self] opened in
            if !opened {
                self?.toast = CouliToastMessage(DefaultTexts.text("app_update.unavailable") ?? "")
            }
        }
    }

    #if DEBUG
    /// 调试面板切换场景后：当作一次冷启动重新检查（本次运行的提示关闭、选店失败一并复位）。
    func debugRecheck() {
        promptGoneToStoreFor = nil
        storeChoiceFailed = false
        guard canCheck else {
            publish()
            return
        }
        let now = clock()
        gate.onColdStart(now: now)
        startLifecycleCheck(now: now)
    }
    #endif

    // MARK: - 状态

    private func setWorking(_ working: Bool) {
        guard ui.working != working else { return }
        ui.working = working
    }

    private func publish() {
        let next = Self.makeUI(gate: gate, now: clock(), storeChoiceFailed: storeChoiceFailed, working: ui.working)
        if next != ui {
            ui = next
        }
        onChange?()
    }

    private static func makeUI(gate: UpdateGate, now: Int64, storeChoiceFailed: Bool, working: Bool) -> ViewState {
        let state = gate.state(now: now)
        let result = gate.lastResult
        var unavailable = false
        if state.status == .belowMin {
            // 版本预检：一家已上架版本都不够时直接显示「暂时无法更新」，不先给一个点了也去不了的【去更新】。
            // 只核对版本（能力一律按能打开），能不能打开等用户点【去更新】时再查。
            let versionCheck = result.map { gate.pickStore(result: $0, now: now, canOpen: { _ in true }) }
            unavailable = storeChoiceFailed || (versionCheck?.unavailable ?? false)
        }
        return ViewState(
            status: state.status,
            showPrompt: state.showPrompt,
            targetVersion: state.targetVersion,
            result: result,
            forceUnavailable: unavailable,
            working: working
        )
    }
}
