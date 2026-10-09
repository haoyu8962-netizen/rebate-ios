import CouliNetwork
import Foundation
import TradeJump

/// 一次淘宝授权（含 30104 恢复）的结局。
public enum TaobaoAuthOutcome {
    /// bindings 返回 active。
    case bound
    /// 用户在授权页 / SDK 里取消。
    case cancelled
    /// 授权失败（BR-ID-18）：本端执行不了下发的任何方式、授权步骤失败，或 30104 之后没有可换的方式。
    case failed
    /// 请求失败（bindings、auth-url 的其它业务码、42901、5xxxx、传输失败）：调用方按码处理，不能当成用户没授权（共性第 19 条）。
    case requestFailed(ApiResult)
    /// 已不属于当前授权（页面离开、世代变了）：什么都不做。
    case abandoned
}

/// 淘宝授权的执行与 30104 恢复（BR-ID-17 细则「凭证无效」「幂等键」、契约 30104 action；共性第 18 条）。购买流程的 AuthSheet 与授权管理页
/// 共用：
/// - 按下发的 auth_methods 取本端能执行的第一种（web_code 要有 auth_url；sdk_token 要百川支持换令牌），执行后用 state + 凭证调 bindings，
///   每次绑定尝试一个新的幂等键；
/// - bindings 返回 30104：重新调 auth-url 取新的 state 与方式列表，这是一次新的绑定尝试（新 state、新凭证、新幂等键）：
///   reason=credential_invalid → 这种方式记为失效，改用新列表里下一种本端可执行、没失效过的方式；reason=method_not_allowed → 只按新下发的
///   auth_methods 执行（仍排除已失效的方式）；没有 reason（state 过期或已用）→ 按新列表重新发起；最多恢复 `maxRecoveries` 次；
/// - 其它失败原样交给调用方（`requestFailed`）。每次等待之后复核 `alive`（离开、世代变了即 `abandoned`）。
@MainActor
public final class TaobaoAuthFlow {
    public static let maxRecoveries = 3
    public static let stateOrCredential = 30104
    public static let credentialInvalid = "credential_invalid"
    public static let methodNotAllowed = "method_not_allowed"

    private let calls: TradeCalls
    private let group: String
    private let webCode: WebCodeAuthorizer
    private let baichuan: BaichuanAdapter
    private let keyGenerator: () -> String
    private let alive: @MainActor () -> Bool
    private let installed: @MainActor (String) -> String
    /// 30104 恢复要再次拉起授权时，用户点【去授权】发出的授权许可仍有效（进过后台即撤销，共性第 31 条）。
    private let relaunchAllowed: @MainActor () -> Bool

    public init(
        calls: TradeCalls,
        group: String,
        webCode: WebCodeAuthorizer,
        baichuan: BaichuanAdapter,
        keyGenerator: @escaping () -> String,
        alive: @escaping @MainActor () -> Bool,
        installed: @escaping @MainActor (String) -> String,
        relaunchAllowed: @escaping @MainActor () -> Bool = { true }
    ) {
        self.relaunchAllowed = relaunchAllowed
        self.calls = calls
        self.group = group
        self.webCode = webCode
        self.baichuan = baichuan
        self.keyGenerator = keyGenerator
        self.alive = alive
        self.installed = installed
    }

    /// 本端能执行的方式（按本端能力，不看下发顺序）。
    private var supported: [String] {
        (webCode.available ? [AuthMethodPicker.webCode] : []) +
            (baichuan.supportsSdkToken ? [AuthMethodPicker.sdkToken] : [])
    }

    /// `data` 里本端此刻能执行的第一种方式（排除 `excluded`）；state、auth_url 不全也算不能执行。
    public func pick(platform: String, data: TradeObject, excluded: Set<String> = []) -> String? {
        let methods = TJSON.strings(data["auth_methods"]).filter { !excluded.contains($0) }
        guard let method = AuthMethodPicker.pick(platform: platform, authMethods: methods, supported: supported),
              TJSON.string(data["state"]) != nil,
              method != AuthMethodPicker.webCode || TJSON.string(data["auth_url"]) != nil
        else { return nil }
        return method
    }

    public func run(platform: String, initial: TradeObject) async -> TaobaoAuthOutcome {
        var data = initial
        var invalid: Set<String> = []
        var recoveries = 0
        while true {
            // 30104 之后再次拉起授权：许可已撤销（进过后台）就不自动再拉起，按授权失败交用户重试（共性第 31 条）
            if recoveries > 0, !relaunchAllowed() {
                return .failed
            }
            switch await attempt(platform: platform, data: data, invalid: invalid) {
            case let .done(outcome):
                return outcome
            case let .recover(method, credentialInvalid):
                // 30104：重新取授权上下文，一次新的绑定尝试（BR-ID-17 细则、契约 30104 action）
                recoveries += 1
                if recoveries > Self.maxRecoveries {
                    return .failed
                }
                if credentialInvalid {
                    invalid.insert(method)
                }
                let refreshed = await authUrl(platform: platform)
                guard alive() else { return .abandoned }
                guard case let .success(next, _, _) = refreshed, let object = TJSON.parse(next) else {
                    return .requestFailed(refreshed)
                }
                data = object
            }
        }
    }

    private enum Attempt {
        case done(TaobaoAuthOutcome)
        /// bindings 返回 30104：换授权上下文重来（`credentialInvalid` 时这种方式记为失效）。
        case recover(method: String, credentialInvalid: Bool)
    }

    /// 一次绑定尝试：按方式授权 → bindings。
    private func attempt(platform: String, data: TradeObject, invalid: Set<String>) async -> Attempt {
        guard alive() else { return .done(.abandoned) }
        guard let method = pick(platform: platform, data: data, excluded: invalid),
              let state = TJSON.string(data["state"])
        else { return .done(.failed) }
        let step = await authorize(method, authUrl: TJSON.string(data["auth_url"]) ?? "", state: state)
        guard alive() else { return .done(.abandoned) }
        let credential: AuthCredential
        switch step {
        case let .credential(value): credential = value
        case .cancelled: return .done(.cancelled)
        case .failed: return .done(.failed)
        }
        let result = await bind(platform: platform, state: state, credential: credential)
        guard alive() else { return .done(.abandoned) }
        if case let .success(body, _, _) = result {
            return .done(TJSON.string(TJSON.parse(body)?["status"]) == TradeConstants.active ? .bound : .failed)
        }
        guard case let .failure(code, _, failData, _, _, _) = result, code == Self.stateOrCredential else {
            return .done(.requestFailed(result))
        }
        let reason = TJSON.string(TJSON.parse(failData)?["reason"])
        return .recover(method: method, credentialInvalid: reason == Self.credentialInvalid)
    }

    private func authorize(_ method: String, authUrl: String, state: String) async -> AuthStepResult {
        if method == AuthMethodPicker.webCode {
            return await webCode.authorize(authUrl: authUrl, state: state)
        }
        switch await baichuan.authorize() {
        case let .token(token, expiresIn): return .credential(.sdkToken(accessToken: token, expiresIn: expiresIn))
        case .cancelled: return .cancelled
        case .failed: return .failed
        }
    }

    /// bindings：每次绑定尝试一个新的幂等键（BR-ID-17 细则「幂等键」）。
    private func bind(platform: String, state: String, credential: AuthCredential) async -> ApiResult {
        let call = ApiCall(
            operationId: TradeOperations.bindUnion, pathParams: ["platform": platform],
            body: bindBody(state: state, credential: credential), idempotencyKey: keyGenerator()
        )
        return await calls.send(call, group: group)
    }

    /// auth-url：重新取 state 与方式列表。
    public func authUrl(platform: String) async -> ApiResult {
        let call = ApiCall(
            operationId: TradeOperations.getUnionAuthUrl, pathParams: ["platform": platform],
            query: "installed=" + installed(platform)
        )
        return await calls.send(call, group: group)
    }
}
