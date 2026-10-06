import Foundation

// 隐私首启闸门（03 §4.1，BR-ID-11、BR-ID-12、BR-ID-13；APP-02b）。
// 本文件是第三方 SDK 初始化的唯一入口：只有 `PrivacyGate.onConsented(now:)` 会调用已登记的初始化步骤
// （SwiftLint 规则 sdk_init_only_in_privacy_gate 只放行名为 PrivacyGate.swift 的文件）。
// 向量：specs/privacy-gate-vectors.json；规则空白见 couli-runs/NATIVE/APP-02b/rule-gaps.md，按保守做法处理并标 TODO。

/// 隐私闸门结论。
public enum PrivacyDecision: String, Sendable, CaseIterable {
    case notDecided = "not_decided"
    case consented
    case basicMode = "basic_mode"
}

/// 当前要显示的弹窗。
public enum PrivacyPromptStage: String, Sendable, CaseIterable {
    case none
    /// 首启弹窗（摘要 + 协议链接，【同意】【不同意】）。
    case first
    /// 二次说明（【同意】【仍不同意】；iOS 不给退出按钮）。
    case second
}

/// 闸门状态快照。
public struct PrivacyGateState: Sendable, Equatable {
    /// 当前生效的结论。重新提示期间：基本模式用户点【开启完整功能】时仍是 basic_mode（还在基本模式里浏览）；
    /// 已同意的版本低于包内版本时是 not_decided（旧同意不再作数，下一次冷启动重新走首启闸门，BR-ID-12）。
    public let decision: PrivacyDecision
    public let mustPrompt: Bool
    public let promptStage: PrivacyPromptStage

    public init(decision: PrivacyDecision, promptStage: PrivacyPromptStage) {
        self.decision = decision
        self.promptStage = promptStage
        mustPrompt = promptStage != .none
    }

    public var decisionRaw: String {
        decision.rawValue
    }

    public var promptStageRaw: String {
        promptStage.rawValue
    }
}

/// 本机隐私决定的持久化（字段名照向量测试的接线约定）。生产实现见 `UserDefaultsPrivacyStore`。
public protocol PrivacyStore: AnyObject {
    /// not_decided / consented / basic_mode。
    var decisionRaw: String { get set }
    /// 同意时的包内隐私政策版本（整数的十进制串）。
    var consentedVersion: String? { get set }
    /// 同意的点击时间（毫秒）。
    var consentedAtMillis: Int64? { get set }
    var basicMode: Bool { get set }
    /// 撤回同意的本地清理尚未完成（BR-ID-13）。冷启动时只要它在就强制按基本模式处理；清理成功只删它。
    var withdrawalCleanupPending: Bool { get }
    /// 记录同意（结论、版本、点击时间、清基本模式标记）——生产存储一次写入。
    func commitConsent(version: String, atMillis: Int64)
    /// 进入基本模式（结论 + 基本模式标记）——生产存储一次写入。
    func commitBasicMode()
    /// 撤回同意：基本模式、清除同意记录、置待清理标记，三者在同一次持久化写入里完成（第 2 轮评审，三端统一）。
    func commitWithdrawal()
    /// 清理成功：只删待清理标记。
    func clearWithdrawalPending()
}

/// 默认实现（只有四个字段的简单存储，如向量测试的内存存储）：逐字段写，不支持待清理标记。
/// 生产存储 `UserDefaultsPrivacyStore` 全部覆盖为单次写入。
public extension PrivacyStore {
    var withdrawalCleanupPending: Bool {
        false
    }

    func commitConsent(version: String, atMillis: Int64) {
        decisionRaw = PrivacyDecision.consented.rawValue
        consentedVersion = version
        consentedAtMillis = atMillis
        basicMode = false
    }

    func commitBasicMode() {
        decisionRaw = PrivacyDecision.basicMode.rawValue
        basicMode = true
    }

    func commitWithdrawal() {
        consentedVersion = nil
        consentedAtMillis = nil
        commitBasicMode()
    }

    func clearWithdrawalPending() {}
}

/// 设备注册退避重试的调度器（可注入，单测用假调度器推进虚拟时间）。
public protocol RetryScheduler {
    func schedule(delayMillis: Int64, action: @escaping () -> Void)
}

/// 初始化步骤名（03 §4.1、BR-ID-11 的固定顺序）。
public enum PrivacyInitStep {
    public static let deviceRegister = "device_register"
    public static let push = "push"
    public static let union = "union"
    public static let crash = "crash"
    public static let wechat = "wechat"

    /// 执行顺序：设备注册 → 推送 → 联盟 → 崩溃 → 微信。
    public static let order = [deviceRegister, push, union, crash, wechat]
}

/// 隐私首启闸门：状态迁移、版本比对、撤回同意、同意后的初始化（唯一入口）。
///
/// 不是线程安全的：生产代码只在主线程使用（App 的 `PrivacyController` 是 @MainActor，调度器回到主队列）。
public final class PrivacyGate {
    /// 设备注册首次重试的等待（毫秒），之后每次翻倍。
    public static let retryBaseMillis: Int64 = 1000
    /// 设备注册重试等待的上限（毫秒）。
    public static let retryCapMillis: Int64 = 60000

    public var retryScheduler: any RetryScheduler
    /// 撤回同意时的本地清理入口（令牌、device_id、install_secret）。
    /// 生产接 `PrivacyWithdrawalCleanup.registry`（APP-01 清理器注册表的形式，见 PrivacyWithdrawal.swift）。
    public var withdrawalCleanup: () -> Void

    private let store: any PrivacyStore
    private let clock: () -> Int64
    private let bundledPolicyVersion: String
    /// 当前弹窗（只在内存；冷启动时由 `coldStart` 按存储重新算出）。
    private var stage: PrivacyPromptStage
    private var steps: [String: () throws -> Void] = [:]
    /// 本次同意周期是否已发起过初始化。
    private var initStarted = false
    /// 同意周期代次：撤回同意时递增，旧周期排着的设备注册重试据此作废。
    private var cycle: UInt64 = 0

    public init(store: any PrivacyStore, clock: @escaping () -> Int64, bundledPolicyVersion: String) {
        self.store = store
        self.clock = clock
        self.bundledPolicyVersion = bundledPolicyVersion
        retryScheduler = MainQueueRetryScheduler()
        withdrawalCleanup = {}
        stage = .none
        forceBasicModeIfCleanupPending()
        stage = initialStage()
    }

    // MARK: - 状态

    public func state(now _: Int64) -> PrivacyGateState {
        PrivacyGateState(decision: effectiveDecision, promptStage: stage)
    }

    /// 冷启动：按存储与包内版本决定要不要弹首启弹窗。
    /// - 未决 → first；
    /// - 已同意且版本不低于包内版本 → 不弹；版本更低（或记录缺版本、版本串不是整数）→ first（BR-ID-12）；
    /// - 基本模式 → 不弹，政策版本升级也不自动弹（BR-ID-11）。
    /// - 撤回清理未完成（待清理标记在）→ 强制按基本模式处理（再写一次撤回记录，同意记录一并清掉），不弹。
    public func coldStart(now _: Int64) {
        forceBasicModeIfCleanupPending()
        stage = initialStage()
    }

    // MARK: - 用户操作

    /// 首启弹窗或二次说明里点【同意】：先把同意落本地（版本 = 包内版本，时间 = 点击时间），再由调用方调 `onConsented`。
    /// TODO(rule-gaps): 没有弹窗时的【同意】规则未定义，按忽略处理（不凭空记同意）。
    /// 撤回清理还没完成（待清理标记在）时，先重试清理；仍没清干净就不记同意、留在基本模式（第 2 轮评审 R2-01：
    /// 标记在期间不放行完整功能、不初始化、不读凭据）。TODO(rule-gaps): 此时给用户的提示文案未定义，由 APP-12 补。
    public func agree(now: Int64) {
        guard stage != .none else { return }
        if store.withdrawalCleanupPending {
            withdrawalCleanup()
            guard !store.withdrawalCleanupPending else {
                stage = .none
                return
            }
        }
        store.commitConsent(version: bundledPolicyVersion, atMillis: now)
        stage = .none
    }

    /// 首启弹窗点【不同意】：进二次说明（只展示 1 次）。
    public func disagree(now _: Int64) {
        guard stage == .first else { return }
        stage = .second
    }

    /// 二次说明点【仍不同意】：进入并保存基本模式。拒绝新版政策不是撤回同意：不清令牌（BR-ID-12 细则示例）。
    public func stillDisagree(now _: Int64) {
        guard stage == .second else { return }
        enterBasicMode()
        stage = .none
    }

    /// 基本模式点【开启完整功能】或任何需要同意的功能：弹首启弹窗（BR-ID-02、BR-ID-11）。已同意当前版本时无事可做。
    public func requestFullFunction(now _: Int64) {
        guard effectiveDecision != .consented else { return }
        stage = .first
    }

    /// 隐私中心【撤回同意】（BR-ID-13）：清本地令牌、device_id、install_secret，然后进入并保存基本模式。
    /// 撤回后再同意算新的同意周期：会重新发起初始化（device_id 已清，需要重新注册设备）。
    /// TODO(rule-gaps): 服务端撤回记录（POST /v1/consents accepted=false）与在途请求取消由 APP-03 / APP-12 接入；
    /// SDK 无法在进程内反初始化，再次同意时各步骤须自行保证重复调用安全（各 SDK 接入任务）。
    /// 中断安全（第 2 轮评审）：先在一次持久化写入里落「基本模式 + 清除同意记录 + 待清理标记」，再清凭据；
    /// 清理成功只删标记（`WithdrawalCleanupRunner`）。任何时刻中断，下次冷启动都是基本模式且会重试清理。
    public func withdraw(now _: Int64) {
        store.commitWithdrawal()
        withdrawalCleanup()
        stage = .none
        initStarted = false
        cycle &+= 1
    }

    // MARK: - 初始化（SDK 唯一入口）

    /// 登记一个初始化步骤（同名再登记则替换）。执行顺序只由 `PrivacyInitStep.order` 决定，与登记顺序无关；
    /// 不在固定顺序里的名字排在最后、按名字排序。`action` 抛错表示本次失败。
    /// TODO(rule-gaps): 步骤重复登记、缺失的处理规则未定义；这里替换、缺失的跳过。
    public func registerInitStep(name: String, action: @escaping () throws -> Void) {
        steps[name] = action
    }

    /// 同意后的初始化，唯一入口（03 §3.5、§4.1）。只有当前生效的结论是「已同意当前版本」时才执行；
    /// 同一同意周期内只发起一次，重复调用不重复执行。
    /// 设备注册失败不阻塞其余步骤；设备注册按 1s、2s、4s…上限 60s 退避重试，成功即停（BR-ID-11）。
    /// 其余步骤抛错时本次忽略，不重试。TODO(rule-gaps): 其余 SDK 初始化失败后的处理规则未定义。
    public func onConsented(now _: Int64) {
        guard effectiveDecision == .consented, stage == .none, !initStarted else { return }
        initStarted = true
        let currentCycle = cycle
        for name in orderedStepNames() {
            if name == PrivacyInitStep.deviceRegister {
                attemptDeviceRegister(attempt: 1, cycle: currentCycle)
            } else {
                try? steps[name]?()
            }
        }
    }

    // MARK: - 内部

    private var effectiveDecision: PrivacyDecision {
        // 撤回清理未完成：无论记录里写着什么，一律按基本模式（不初始化、不放行完整功能，R2-01）。
        if store.withdrawalCleanupPending || isBasicModeStored {
            return .basicMode
        }
        if store.decisionRaw == PrivacyDecision.consented.rawValue, consentIsCurrent {
            return .consented
        }
        return .notDecided
    }

    /// 基本模式：decision 与标记任一为基本模式即按基本模式（二者矛盾时取保守的一方：不初始化、不自动弹）。
    /// TODO(rule-gaps): decision 与 basicMode 互相矛盾时的恢复策略未定义。
    private var isBasicModeStored: Bool {
        store.decisionRaw == PrivacyDecision.basicMode.rawValue || store.basicMode
    }

    /// 已同意的版本不低于包内版本。版本按整数比较（"9" < "10"）；缺版本或不是整数按不作数处理（重新提示）。
    /// TODO(rule-gaps): 损坏记录、非法版本串的恢复策略未定义，这里保守地重新走首启闸门。
    private var consentIsCurrent: Bool {
        guard let stored = store.consentedVersion.flatMap(Self.policyVersion),
              let bundled = Self.policyVersion(bundledPolicyVersion)
        else {
            return false
        }
        return stored >= bundled
    }

    static func policyVersion(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) else {
            return nil
        }
        return Int(text)
    }

    private func initialStage() -> PrivacyPromptStage {
        switch effectiveDecision {
        case .consented, .basicMode:
            .none
        case .notDecided:
            .first
        }
    }

    private func enterBasicMode() {
        store.commitBasicMode()
    }

    private func forceBasicModeIfCleanupPending() {
        if store.withdrawalCleanupPending {
            store.commitWithdrawal()
        }
    }

    private func orderedStepNames() -> [String] {
        let known = PrivacyInitStep.order.filter { steps[$0] != nil }
        let extra = steps.keys.filter { !PrivacyInitStep.order.contains($0) }.sorted()
        return known + extra
    }

    /// 第 n 次失败后的等待：1s、2s、4s…，上限 60s。
    static func retryDelayMillis(afterFailure attempt: Int) -> Int64 {
        let exponent = min(max(attempt - 1, 0), 16)
        return min(retryBaseMillis << Int64(exponent), retryCapMillis)
    }

    private func attemptDeviceRegister(attempt: Int, cycle attemptCycle: UInt64) {
        guard attemptCycle == cycle, effectiveDecision == .consented,
              let action = steps[PrivacyInitStep.deviceRegister]
        else {
            return
        }
        do {
            try action()
        } catch {
            retryScheduler.schedule(delayMillis: Self.retryDelayMillis(afterFailure: attempt)) { [weak self] in
                self?.attemptDeviceRegister(attempt: attempt + 1, cycle: attemptCycle)
            }
        }
    }
}

/// 生产调度器：在主队列上延时执行（PrivacyGate 只在主线程使用）。
public final class MainQueueRetryScheduler: RetryScheduler {
    public init() {}

    public func schedule(delayMillis: Int64, action: @escaping () -> Void) {
        let box = MainThreadAction(action)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMillis))) {
            box.run()
        }
    }
}

/// 只在主线程创建与执行的闭包包装（跨 asyncAfter 的 @Sendable 边界）。
private final class MainThreadAction: @unchecked Sendable {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func run() {
        action()
    }
}
