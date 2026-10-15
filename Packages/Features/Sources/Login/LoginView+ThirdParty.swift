import DesignSystem
import SwiftUI

/// 登录页的第三方登录（APP-05b；Login 画板「其他登录方式」）。
extension LoginViewModel {
    /// 此刻显示的第三方按钮（按适配器可用性，受限登录同样显示，iOS R2-01；正式微信恒不可用 → 不显示）。
    public var providers: [String] {
        config.oauth?.visibleProviders(restricted: config.restricted) ?? []
    }

    /// 这个 provider 处于 42901 禁用期。
    public func oauthLimited(_ provider: String) -> Bool {
        config.oauth?.rateLimited(provider, now: now) ?? false
    }

    var oauthLimitedAny: Bool {
        providers.contains { oauthLimited($0) }
    }

    /// 第三方按钮可点：没有进行中的登录、发码，也不在该 provider 的禁用期。
    public func oauthEnabled(_ provider: String) -> Bool {
        oauthProvider == nil && !sending && !submitting && !oauthLimited(provider)
    }

    /// 点第三方按钮：未勾选协议先弹确认框（与短信登录同一确认框，BR-ID-04），同意后记下时刻再发起。
    public func startOAuth(_ provider: String) {
        guard config.oauth != nil, oauthEnabled(provider) else { return }
        withAgreement { [weak self] in
            self?.runOAuth(provider)
        }
    }

    func runOAuth(_ provider: String) {
        guard let oauth = config.oauth, oauthProvider == nil else { return }
        oauthProvider = provider
        let consent = agreement.consentAtMillis
        let restricted = config.restricted
        Task { @MainActor [weak self] in
            let outcome = await oauth.start(provider: provider, consentAtMillis: consent, restricted: restricted)
            guard let self else { return }
            oauthProvider = nil
            handleOAuth(outcome)
        }
    }

    func providerName(_ provider: String) -> String {
        text(LoginKeys.providerName(provider))
    }

    func handleOAuth(_ outcome: OAuthOutcome) {
        let vars = ["provider_name": providerName(outcome.provider), "trace6": outcome.trace6]
        switch outcome.stateRaw {
        case LoginOutcome.loggedIn:
            ticker?.cancel()
            ticker = nil
            config.onLoggedIn(LoginOutcome(LoginOutcome.loggedIn))
        case OAuthOutcome.cancelled, LoginOutcome.stale, LoginOutcome.busy, LoginOutcome.agreementRequired:
            break
        case OAuthLoginErrorAction.riskBlocked:
            dialog = .oauthBlocked(outcome.textKey ?? "error.44001")
        case OAuthLoginErrorAction.forceUpdate:
            ticker?.cancel()
            ticker = nil
            config.onForceUpdate(outcome.textKey)
        case OAuthLoginErrorAction.retryAfter, OAuthOutcome.rateLimited:
            now = service.now
            startTicking()
            toastText(config.texts.format(outcome.textKey ?? "error.42901", vars))
        default:
            // reauthorize（20004）、provider_unavailable（50305，保留其他方式）、unavailable（未装 / 不可用）、5xxxx 附 trace6：
            // 只提示，不自动重试
            toastText(config.texts.format(outcome.textKey ?? LoginKeys.generic, vars))
        }
    }

    private func toastText(_ message: String) {
        if !message.isEmpty {
            toast = CouliToastMessage(message)
        }
    }
}

/// 第三方登录区：分隔线「其他登录方式」、微信圆形描边按钮（下方短名「微信」，读屏「微信登录」）、【通过 Apple 登录】黑底按钮。
/// 读屏顺序在邀请码入口之后、登录遇到问题之前（A11yFocusLogin）。
struct ThirdPartyArea: View {
    @ObservedObject var model: LoginViewModel

    var body: some View {
        VStack(spacing: CouliSpacing.s3) {
            HStack(spacing: CouliSpacing.s3) {
                Rectangle().fill(CouliColor.borderSubtle).frame(height: 1).accessibilityHidden(true)
                Text(verbatim: model.text(LoginKeys.otherMethods))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Rectangle().fill(CouliColor.borderSubtle).frame(height: 1).accessibilityHidden(true)
            }
            if model.providers.contains(OAuthProvider.wechat) {
                wechatButton
            }
            if model.providers.contains(OAuthProvider.apple) {
                appleButton
            }
        }
        .padding(.top, CouliSpacing.s2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("login.thirdParty")
    }

    private var wechatButton: some View {
        let enabled = model.oauthEnabled(OAuthProvider.wechat)
        return Button {
            model.startOAuth(OAuthProvider.wechat)
        } label: {
            VStack(spacing: CouliSpacing.s1) {
                ZStack {
                    Circle().fill(CouliColor.backgroundSurface)
                    Circle().strokeBorder(CouliColor.borderSubtle)
                    if model.oauthProvider == OAuthProvider.wechat {
                        ProgressView().progressViewStyle(.circular)
                    } else {
                        // 图形不随字号放大（与品牌方块同口径）；微信品牌图形未提供，用设计系统的 chat 线性图标（rule-gaps iOS I09）
                        Image(systemName: "bubble.left")
                            .font(.system(size: 20))
                            .foregroundColor(CouliColor.textSecondary)
                    }
                }
                .frame(width: 48, height: 48)
                Text(verbatim: model.text(LoginKeys.wechatShort))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
            }
            .frame(minWidth: 64, minHeight: CouliHitTarget.minimum)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(CouliPlainButtonStyle())
        .disabled(!enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: model.text(LoginKeys.wechat)))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("login.wechat")
    }

    private var appleButton: some View {
        let enabled = model.oauthEnabled(OAuthProvider.apple)
        return Button {
            model.startOAuth(OAuthProvider.apple)
        } label: {
            HStack(spacing: CouliSpacing.s2) {
                if model.oauthProvider == OAuthProvider.apple {
                    ProgressView().progressViewStyle(.circular).tint(CouliColor.textInverse)
                } else {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(verbatim: model.text(LoginKeys.apple))
                    .couliFont(.body, weight: .couliSemibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(CouliColor.textInverse)
            .padding(.horizontal, CouliSpacing.s5)
            .frame(maxWidth: .infinity, minHeight: CouliComponentMetric.buttonMinHeight)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .fill(CouliColor.textPrimary.opacity(enabled ? 1 : 0.5))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(CouliPlainButtonStyle())
        .disabled(!enabled)
        .accessibilityIdentifier("login.apple")
    }
}
