import Combine
import Config
import Foundation
import Privacy
import Router

/// 包内协议副本的版本（BR-ID-11 细则「包内协议副本」、BR-ID-12：整数版本号）。
/// TODO(N-16): 包内协议副本与版本号由构建时从当前生效版本导出（规划/03 §4.3）；法务定稿前固定为 1。
enum BundledLegal {
    static let privacyPolicyVersion = "1"
}

/// App 侧的隐私闸门：持有 Core 的 `PrivacyGate`，把状态发布给界面，结论变化时通知路由接线。
///
/// - 冷启动：`coldStart` 后，已同意当前版本的立即走 `onConsented`（初始化入口，03 §4.1）。
/// - 同意：先由 `PrivacyGate.agree` 落本地，再调 `onConsented`。
/// - 撤回同意（BR-ID-13）：清理入口接 `PrivacyWithdrawalCleanup`（APP-01 清理器注册表形式）。页面在 APP-12。
@MainActor
final class PrivacyController: ObservableObject {
    @Published private(set) var state: PrivacyGateState

    /// 用户在弹窗或隐私中心做了什么（AppRouting 据此通知 Router）。
    enum Action: Equatable {
        case agree
        case disagree
        case stillDisagree
        case requestFullFunction
        case withdraw
    }

    /// 结论或弹窗阶段变化后调用（AppRouting 接到 Router.privacyChanged 与启动协调）。
    var onChange: (() -> Void)?
    /// 每次用户操作后调用（在 `onChange` 之后；状态没变也会调用）。
    var onAction: ((Action) -> Void)?

    private let gate: PrivacyGate
    private let clock: () -> Int64

    init(
        store: any PrivacyStore = UserDefaultsPrivacyStore(),
        clock: @escaping () -> Int64 = PendingActionStore.wallClockMillis,
        bundledPolicyVersion: String = BundledLegal.privacyPolicyVersion
    ) {
        self.clock = clock
        gate = PrivacyGate(store: store, clock: clock, bundledPolicyVersion: bundledPolicyVersion)
        gate.withdrawalCleanup = {
            MainActor.assumeIsolated {
                // 清理失败时保留「待清理」标记，下次启动重试（WithdrawalCleanupRunner）。
                _ = PrivacyWithdrawalCleanup.runner.run()
            }
        }
        Self.registerInitSteps(on: gate)
        let now = clock()
        gate.coldStart(now: now)
        state = gate.state(now: now)
        gate.onConsented(now: now)
    }

    /// 唯一的初始化入口登记处：顺序由 `PrivacyInitStep.order` 决定（设备注册 → 推送 → 联盟 → 崩溃 → 微信）。
    /// 本任务各步骤都是空实现；SDK 的初始化调用只能写在 Core 的 PrivacyGate.swift 允许的位置，经这里登记。
    private static func registerInitSteps(on gate: PrivacyGate) {
        // TODO(APP-03): 设备注册（POST /v1/devices）；成功后上报本地同意记录（client_at = 点击时间）与推送 token。
        // 失败时抛错，由 PrivacyGate 按 1s、2s、4s…上限 60s 退避重试。
        gate.registerInitStep(name: PrivacyInitStep.deviceRegister) {}
        // TODO(APP-推送任务): MobPush 初始化与隐私授权接口（03 §3.5）。
        gate.registerInitStep(name: PrivacyInitStep.push) {}
        // TODO(APP-外跳任务): 百川等联盟 SDK（03 §3.5）。
        gate.registerInitStep(name: PrivacyInitStep.union) {}
        // TODO(APP-崩溃任务): Sentry（境内自建服务端，03 §3.5）。
        gate.registerInitStep(name: PrivacyInitStep.crash) {}
        // TODO(APP-05): 微信 OpenSDK（03 §3.5）。
        gate.registerInitStep(name: PrivacyInitStep.wechat) {}
    }

    // MARK: - 状态

    /// 给 Router 的隐私状态（EntryGuard）。
    var routerPrivacy: PrivacyState {
        switch state.decision {
        case .consented: .consented
        case .basicMode: .basicMode
        case .notDecided: .notDecided
        }
    }

    /// 首启弹窗或二次说明正在显示。
    var isPrompting: Bool {
        state.mustPrompt
    }

    // MARK: - 操作

    func agree() {
        let now = clock()
        gate.agree(now: now)
        gate.onConsented(now: now)
        publish(.agree)
    }

    func disagree() {
        gate.disagree(now: clock())
        publish(.disagree)
    }

    func stillDisagree() {
        gate.stillDisagree(now: clock())
        publish(.stillDisagree)
    }

    /// 基本模式点【开启完整功能】或需要同意的功能。
    func requestFullFunction() {
        gate.requestFullFunction(now: clock())
        publish(.requestFullFunction)
    }

    /// 隐私中心【撤回同意】（页面在 APP-12）。
    func withdraw() {
        gate.withdraw(now: clock())
        publish(.withdraw)
    }

    private func publish(_ action: Action) {
        let next = gate.state(now: clock())
        if next != state {
            state = next
            onChange?()
        }
        onAction?(action)
    }
}
