import CouliNetwork
import Foundation

/// 换手机号的写请求原始结果（APP-13a-2，D10-2203 ①）：换号页在「我的」Core，结局按「更换」分支自己落地（10003 → 面板原键原体重放、确认
/// 10003 → 面板沿用原键、30411 不并号等）；这里只给共享结算之后的原始结果。`notified`：随后有一条共享未决通知。
public struct BindChangeArrival: Sendable {
    public let result: ApiResult
    public let kind: BindSettledKind
    public let gated: Bool
    public let notified: Bool
}

/// 一次更换提交的原键、原体、展示摘要与 X-Step-Up-Token（10003 后原键原体重放时原样再给一次，只换 token）。
public struct BindChangeRequest: Sendable {
    public let key: String
    public let body: String
    public let summary: String
    public let stepUpToken: String?

    public init(key: String, body: String, summary: String, stepUpToken: String?) {
        self.key = key
        self.body = body
        self.summary = summary
        self.stepUpToken = stepUpToken
    }
}

/// 绑手机服务的「更换」入口（APP-13a-2）：与首次绑定共用同一份 phoneGate、在途登记、共享结算（成功 → recordBindSucceeded + onBound：
/// 清全部 action 的 token、刷新「我的」、守卫重算）与未决通知（共性第 8、9、18 条）；结局分类沿用 `BindOutcomes.map` 的共享结局
/// （键的去向与首次绑定同一写法，D10-2165 ① 现状）。首次绑定的 `submit` / `confirm` / `abandon` 一行不动（不带 token、确认不预先 step-up）。
public extension BindPhoneService {
    /// 更换提交：原键原体（每次点击由换号页生成新键；10003 后沿用原键原体重放），带第 1 步 / 面板的 X-Step-Up-Token。
    func submitChange(
        _ owner: BindPhoneOwner, _ request: BindChangeRequest, completion: @escaping (BindChangeArrival) -> Void
    ) {
        let call = ApiCall(
            operationId: Self.operationId, body: request.body, idempotencyKey: request.key,
            stepUpToken: request.stepUpToken, summary: request.summary
        )
        runChange(owner, phase: .submit, completion: completion) { [client] probe in
            await client.send(call, isValid: { true }, sendAllowed: probe.allowed, expected: owner.request)
        }
    }

    /// 更换的【确认上一次提交】：原键原体（网络层取未决记录）；面板验证后带新 token。
    func confirmChange(
        _ owner: BindPhoneOwner, key: String, stepUpToken: String?, completion: @escaping (BindChangeArrival) -> Void
    ) {
        runChange(owner, phase: .confirm, completion: completion) { [client] probe in
            guard let account = owner.account else { return .localReject(reason: LocalRejectReason.sessionChanged) }
            return await client.confirmPending(
                operationId: Self.operationId, stepUpToken: stepUpToken,
                target: PendingTarget(account: account, key: key, expected: owner.request, sendAllowed: probe.allowed)
            )
        }
    }

    /// 更换的【确定放弃】：作废原键（action 取原操作的 stepUp = phone_change）。
    func abandonChange(_ owner: BindPhoneOwner, key: String, completion: @escaping (BindChangeArrival) -> Void) {
        runChange(owner, phase: .abandon, completion: completion) { [client] probe in
            guard let account = owner.account else { return .localReject(reason: LocalRejectReason.sessionChanged) }
            return await client.abandonPending(
                operationId: Self.operationId,
                target: PendingTarget(account: account, key: key, expected: owner.request, sendAllowed: probe.allowed)
            )
        }
    }

    /// 与首次绑定的 `run` 同一顺序：固定身份核对 → 在途登记 → phoneGate 发送前检查 → 发送（离页不取消）→ 共享结算 → 交页面 → 未决通知。
    private func runChange(
        _ owner: BindPhoneOwner, phase: BindOutcomes.Phase, completion: @escaping (BindChangeArrival) -> Void,
        send: @escaping @Sendable (SendProbe) async -> ApiResult
    ) {
        guard isCurrent(owner), let account = owner.account else {
            completion(Self.unsent(LocalRejectReason.sessionChanged, gated: false))
            return
        }
        // 本进程还有没结论的绑手机写请求（G63）：不发第二个，按「同一操作已有未决键」交页面重读记录
        guard !writing.contains(account) else {
            completion(Self.unsent(LocalRejectReason.pendingKeyUnresolved, gated: false))
            return
        }
        isolateGate(owner)
        guard !writeGated(owner) else {
            completion(Self.unsent(LocalRejectReason.sendBlocked, gated: true))
            return
        }
        writing.insert(account)
        let probe = gate.probe()
        Task { @MainActor [weak self] in
            let result = await send(probe)
            guard let self else { return }
            writing.remove(account)
            let gated = probe.gated(result)
            let (_, kind) = BindOutcomes.map(result, phase: phase, gated: gated)
            settle(owner, result: result, kind: kind)
            completion(BindChangeArrival(result: result, kind: kind, gated: gated, notified: true))
            notifyPending(owner, account: account, kind)
        }
    }

    private static func unsent(_ reason: String, gated: Bool) -> BindChangeArrival {
        BindChangeArrival(result: .localReject(reason: reason), kind: .other, gated: gated, notified: false)
    }
}
