import AuthenticationServices
import Foundation
import UIKit

/// 第三方 SDK 交回的授权凭证（openapi OauthCredential：只在内存，不落盘、不进日志；只上送规定字段，BR-ID-04 细则）。
public enum OAuthCredential: Sendable, Equatable {
    /// 微信授权 code（loginByWechat.code）。
    case wechat(code: String)
    /// Apple 的 identity token 与 authorization code（loginByApple.identity_token / authorization_code）。
    case apple(identityToken: String, authorizationCode: String)

    /// 登录请求体里的凭证字段（不含 attempt_id、legal_versions、consent_at）。
    var fields: [String: String] {
        switch self {
        case let .wechat(code):
            ["code": code]
        case let .apple(identityToken, authorizationCode):
            ["identity_token": identityToken, "authorization_code": authorizationCode]
        }
    }

    /// 日志与调试只能用这个（凭证一律不出现）。
    public var redacted: String {
        switch self {
        case .wechat: "wechat(code: <redacted>)"
        case .apple: "apple(identity_token: <redacted>, authorization_code: <redacted>)"
        }
    }
}

/// 一次授权的结局。
public enum OAuthAuthorization: Sendable, Equatable {
    case credential(OAuthCredential)
    /// 用户在第三方界面里取消（静默，回到登录页）。
    case cancelled
    /// 拉起失败或第三方返回错误（提示重新授权）。
    case failed
    /// 适配器不可用（没有 SDK / AppID、entitlement 未配置、未安装）。
    case unavailable
}

/// 第三方登录适配层（任务书 §2.2）：每个 provider 一个实现。正式微信恒不可用；Apple 用系统框架 AuthenticationServices。
/// Debug 假适配器只在 App target 的调试编译单元里（Release 不编译）。只在主线程使用。
@MainActor
public protocol ThirdPartyAuthorizer: AnyObject {
    /// openapi LoginProvider（wechat / apple）。
    var provider: String { get }
    /// 适配器已允许启用（正式微信恒 false，rule-gaps BUTTONS）。
    var available: Bool { get }
    /// 本机是否已安装第三方 App；nil = 未知（iOS 没有微信查询项时一律未知，APP-12 I04 同口径；Apple 不需要安装，恒 true）。
    var installed: Bool? { get }
    /// 拉起授权：`nonce` 是 createOauthAttempt 返回的 nonce（Apple 原样放进请求，TODO(N-29) ATTEMPT-INTEGRATION）。
    func authorize(nonce: String) async -> OAuthAuthorization
    /// 离页、超时、换会话：结束这次等待（能收起的系统界面收起），之后的回调只丢弃。
    func abort()
}

/// 正式微信适配器（无 SDK、无 AppID，任务书 §2.2「不可用」实现）：恒不可用，按钮不显示；本机是否安装一律未知（不调 canOpenURL、
/// 不读应用列表，Info.plist 没有 LSApplicationQueriesSchemes，APP-12 I04 同口径）。微信 SDK 接入后另起任务。TODO(N-29) WECHAT-QUERY。
@MainActor
public final class UnavailableWechatAuthorizer: ThirdPartyAuthorizer {
    public let provider = OAuthProvider.wechat
    public let available = false
    public let installed: Bool? = nil

    public init() {}

    public func authorize(nonce _: String) async -> OAuthAuthorization {
        .unavailable
    }

    public func abort() {}
}

/// Sign in with Apple（ASAuthorizationAppleIDProvider；BR-ID-04 默认值 iOS SIWA）：
/// - 不申请邮箱与姓名（requestedScopes 为空，BR-ID-04 细则「只上送授权凭证」）；nonce 原样放进请求（服务端核对 attempt 的 nonce）；
/// - identity token 与 authorization code 只在内存交回执行器，不落盘、不进日志；
/// - `enabled` 是 entitlement 的开关：Team ID 与 com.apple.developer.applesignin 都还没给（rule-gaps iOS I01），App 侧恒传 false，
///   按钮不显示；负责人给齐后改开关即可，不改流程。
@MainActor
public final class AppleSignInAuthorizer: NSObject, ThirdPartyAuthorizer {
    public let provider = OAuthProvider.apple
    public let available: Bool
    public let installed: Bool? = true
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<OAuthAuthorization, Never>?

    public init(enabled: Bool) {
        available = enabled
    }

    public func authorize(nonce: String) async -> OAuthAuthorization {
        guard available else { return .unavailable }
        abort()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        request.nonce = nonce
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    public func abort() {
        controller?.cancel()
        controller = nil
        finish(.cancelled)
    }

    private func finish(_ result: OAuthAuthorization) {
        let pending = continuation
        continuation = nil
        controller = nil
        pending?.resume(returning: result)
    }

    nonisolated static func credential(_ authorization: ASAuthorization) -> OAuthAuthorization {
        guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
              let token = apple.identityToken.flatMap({ String(data: $0, encoding: .utf8) }), !token.isEmpty,
              let code = apple.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }), !code.isEmpty
        else {
            return .failed
        }
        return .credential(.apple(identityToken: token, authorizationCode: code))
    }
}

extension AppleSignInAuthorizer: ASAuthorizationControllerDelegate {
    public nonisolated func authorizationController(
        controller _: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let result = Self.credential(authorization)
        MainActor.assumeIsolated { finish(result) }
    }

    public nonisolated func authorizationController(
        controller _: ASAuthorizationController, didCompleteWithError error: any Error
    ) {
        let cancelled = (error as? ASAuthorizationError)?.code == .canceled
        MainActor.assumeIsolated { finish(cancelled ? .cancelled : .failed) }
    }
}

extension AppleSignInAuthorizer: ASAuthorizationControllerPresentationContextProviding {
    public nonisolated func presentationAnchor(for _: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
