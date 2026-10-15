import CouliNetwork
import Foundation
import Session

/// 第三方登录的按钮判定与错误换算（从 OAuthLoginService.swift 拆出）。
public extension OAuthLoginService {
    /// 登录页可以显示的第三方按钮（BR-ID-04 细则；任务书 §2.2）：微信按「已安装（未知照常显示）且适配器可用」；Apple 只在 iOS 且适配器
    /// 可用（entitlement 开关）。次序：微信、Apple（设计稿 Login）。受限登录（从强更页进入）照样按适配器可用性显示：仅第三方身份的已有账号
    /// 要能登进 deletion_only 去注销（BR-ID-01；iOS R2-01、共性第 28 条），受限只隐藏邀请码等业务输入（登录页另做），协议校验与
    /// deletion_only 分流不变。`restricted` 保留在签名里，表明这是经过考虑的取舍。
    func visibleProviders(restricted _: Bool) -> [String] {
        var result: [String] = []
        if let wechat = authorizers[OAuthProvider.wechat], ThirdPartyButtons.wechatVisible(
            platform: ThirdPartyButtons.ios, installed: wechat.installed ?? true, adapterAvailable: wechat.available
        ) {
            result.append(OAuthProvider.wechat)
        }
        if let apple = authorizers[OAuthProvider.apple], apple.available,
           ThirdPartyButtons.appleVisible(platform: ThirdPartyButtons.ios) {
            result.append(OAuthProvider.apple)
        }
        return result
    }

    /// 这个 provider 处于 42901 禁用期（Retry-After；按钮置灰）。
    func rateLimited(_ provider: String, now: Int64) -> Bool {
        now < (limits[provider] ?? 0)
    }
}

extension OAuthLoginService {
    // MARK: - 走 APP-05a 登录后计划的分支（iOS R2-01）

    /// 受限会话（deletion_only，含受限登录取得的），或 full 会话但按 APP-05a 计划要进强更页（强更低于；正常会话不绕过强更，
    /// rule-gaps iOS I21）：都沿用 APP-05a 的登录后计划，不走第三方 full 会话的暂缓 / 引导 / 查手机号。
    func usesLoginPlan(scope: String?) -> Bool {
        if scope == Session.SessionScope.deletionOnly {
            return true
        }
        let plan = AfterLogin.plan(
            response: ["session_scope": scope ?? Session.SessionScope.full], state: login.planState()
        )
        return plan.contains(AfterLoginAction.enterForceUpdate)
    }

    /// 按 APP-05a 的登录后计划执行（强更、复查受限会话、丢弃 / 保留待办）；受限登录页的邀请结果不提示。full 新号先记「未绑手机」。
    func planned(
        _ data: [String: Any], provider: String, attempt: AttemptOwner, generation: UInt64, route: OAuthRouteResult
    ) async -> OAuthOutcome {
        let scope = (data["tokens"] as? [String: Any])?["session_scope"] as? String
        if scope != Session.SessionScope.deletionOnly, route.routeRaw == OAuthLoginRoute.bindPhoneGuide {
            phone.store.record(false, generation: generation)
        }
        let outcome = await login.loggedIn(data, attempt: attempt, restricted: restrictedAttempt)
        return OAuthOutcome(outcome.stateRaw, provider: provider, textKey: outcome.textKey, route: route.routeRaw)
    }

    // MARK: - 老用户查手机号

    /// 第三方老用户：手机号状态未知（不当已绑，共性第 2、13 条）。查 getMe：查清（已绑 / 未绑）→ 按完成前置恢复（还缺手机号时进绑手机页）；
    /// 失败 → 解除暂缓、只恢复（登录级照常打开，手机号级按未验证保留，共性第 14 条）；会话已变 → 只解除暂缓。
    func resolveExistingUser(generation: UInt64) {
        let host = host
        let client = login.client
        phone.query { outcome in
            switch outcome {
            case .bound:
                host.releasePendingHold(.prerequisiteDone, session: generation)
            case .failed:
                host.releasePendingHold(.resumeOnly, session: generation)
            case .stale:
                guard client.sessionGeneration == generation else {
                    host.dropPendingHold(session: generation)
                    return
                }
                // 同世代且仍是 full（查询被同会话的另一次取代）才按查清释放；同世代但作用域已变 deletion_only（编排补充，鸿蒙 RC-01）：
                // 发起时的归属已失效，不释放、不解除暂缓（受限会话的待办归 APP-05a 计划）
                if client.isolatedSessionScope == Session.SessionScope.full {
                    host.releasePendingHold(.prerequisiteDone, session: generation)
                }
            }
        }
    }

    // MARK: - 错误

    func errorOutcome(provider: String, code: Int, effect: ErrorEffect, traceId: String?) -> OAuthOutcome {
        let mapped = OAuthLoginErrorAction.ofEffect(code: code, effect: effect)
        if mapped.actionRaw == OAuthLoginErrorAction.retryAfter {
            limits[provider] = max(limits[provider] ?? 0, login.now + mapped.disableMillis)
        }
        return OAuthOutcome(
            mapped.actionRaw, provider: provider, textKey: mapped.textKey,
            trace6: mapped.showTrace6 == true ? LoginService.trace6(traceId) : ""
        )
    }

    static func otherOutcome(_ result: ApiResult, provider: String) -> OAuthOutcome {
        let other = LoginService.otherFailure(result)
        return OAuthOutcome(other.stateRaw, provider: provider, textKey: other.textKey, trace6: other.trace6)
    }

    /// 适配器不可用的提示：微信用契约 login.wechat_unavailable；Apple 用 error.50305（{provider_name} 由页面填）。
    static func unavailableKey(_ provider: String) -> String {
        provider == OAuthProvider.wechat ? "login.wechat_unavailable" : "error.50305"
    }
}
