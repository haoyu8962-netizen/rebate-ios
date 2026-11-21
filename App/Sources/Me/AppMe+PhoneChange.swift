import Combine
import CouliNetwork
import Foundation
import Login
import Me
import MeCore
import SwiftUI
import Wallet
import WalletCore

/// APP-13a-2 换手机号的 App 接线（D10-2203）：
/// - 入口闸（⑤）：Release 判据 `PhoneChangeEntry.sinceIOS` 非 nil 且本端版本不低于它（与 `availableRoutes` 同一个 `versionAtLeast`）；
///   B1-20b 部署前 since 为 nil，Release 恒关。Debug / Staging 有覆盖（启动参数或测试赋值）用覆盖，缺省同 Release（关）；
/// - 依赖（①②）：换号子页经 `AppPhoneChangePorts` 拿钱包二次验证依赖（与提现 / 收款 / 注销面板同一份 WalletDeps）与绑手机端口
///   （BindPhoneService 适配：phoneGate、bind 截止时间、未决通知、成功结算与 BindPhone 页同一份）。
extension AppMe {
    /// 换号子页要的钱包二次验证依赖与绑手机端口。CouliApp.makeAccount 在 `login.connect(wallet:)` 之后调。
    func connect(wallet: AppWallet) {
        guard let login else { return }
        phoneChangeLink = AppPhoneChangePorts(wallet: wallet, login: login)
        #if DEBUG
        if DebugFakeMe.shared.options["phone_change"] == "on" {
            phoneChangeOverride = true
        }
        #endif
    }

    /// Release 判据（与路由 since 同一道闸）。
    static func phoneChangeReleaseAvailable(appVersion: String) -> Bool {
        guard let since = PhoneChangeEntry.sinceIOS else { return false }
        let version = appVersion.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        return versionAtLeast(version, since)
    }

    /// MeEnv：Debug 有覆盖用覆盖，否则同 Release 判据。
    func phoneChangeAvailable() -> Bool {
        #if DEBUG
        if let phoneChangeOverride {
            return phoneChangeOverride
        }
        #endif
        return Self.phoneChangeReleaseAvailable(appVersion: AppRouting.appVersion)
    }

    func phoneChangePorts() -> PhoneChangePorts? {
        phoneChangeLink
    }

    /// 换号 10003 面板订阅的发码 / 验证闸门（与其余面板同一份）。
    func phoneChangeGates() -> WalletGates? {
        phoneChangeLink?.stepUpDeps().gates
    }
}

/// 换号子页的外部依赖（App 侧适配）：钱包二次验证依赖 + BindPhoneService 适配成 MeCore 的 `PhoneBindPort`。只在主线程使用。
@MainActor
final class AppPhoneChangePorts: PhoneChangePorts, PhoneBindPort {
    private let wallet: AppWallet
    private let login: AppLogin
    private let service: BindPhoneService

    init(wallet: AppWallet, login: AppLogin) {
        self.wallet = wallet
        self.login = login
        service = login.bind
    }

    func stepUpDeps() -> WalletDeps {
        wallet.deps
    }

    func walletOwner() -> WalletOwner {
        wallet.currentOwner()
    }

    var bind: PhoneBindPort {
        self
    }

    // MARK: - PhoneBindPort

    private static func mine(_ owner: BindPhoneOwner) -> PhoneBindOwner {
        PhoneBindOwner(request: owner.request, scope: owner.scope)
    }

    private static func theirs(_ owner: PhoneBindOwner) -> BindPhoneOwner {
        BindPhoneOwner(request: owner.request, scope: owner.scope)
    }

    private static func kind(_ kind: BindSettledKind) -> PhoneBindSettledKind {
        switch kind {
        case .done: .done
        case .ended: .ended
        case .abandoned: .abandoned
        case .pending: .pending
        case .other: .other
        }
    }

    private static func arrival(_ arrival: BindChangeArrival) -> PhoneBindArrival {
        PhoneBindArrival(result: arrival.result, kind: kind(arrival.kind), gated: arrival.gated,
                         notified: arrival.notified)
    }

    func identity() -> PhoneBindOwner {
        Self.mine(service.identity())
    }

    func isCurrent(_ owner: PhoneBindOwner) -> Bool {
        service.isCurrent(Self.theirs(owner))
    }

    func writeGated(_ owner: PhoneBindOwner) -> Bool {
        service.writeGated(Self.theirs(owner))
    }

    var writeGate: RetryAfterGate {
        service.gate
    }

    /// 绑定状态的更新世代（绑定成功——首次或更换、本页或别处——时推进）：流程 token 的失效世代（共性第 39 条）。
    func tokenEpoch() -> UInt64 {
        service.store.epoch
    }

    func scopeStill(_ owner: PhoneBindOwner) -> @Sendable () -> Bool {
        let fixed = owner.scope
        let client = login.client
        return { client.isolatedSessionScope == fixed }
    }

    /// 会话状态同步出口（AppRouting.sessionStateChanged → AppLogin.sessionVersion）：同步调用（@Published 在赋值前发出，此刻网络层已是
    /// 新会话），换代后旧子页在这里作废（不等 AppMe.syncIdentity 的下一拍）。
    func observeSession(_ listener: @escaping @MainActor () -> Void) -> () -> Void {
        let watch = login.$sessionVersion.dropFirst().sink { _ in
            MainActor.assumeIsolated { listener() }
        }
        return { watch.cancel() }
    }

    func subscribe(_ listener: @escaping @MainActor (PhoneBindSettled) -> Void) -> () -> Void {
        service.subscribe { event in
            listener(PhoneBindSettled(
                account: event.account, kind: Self.kind(event.kind), owner: Self.mine(event.owner)
            ))
        }
    }

    func pendingStatus(_ owner: PhoneBindOwner) async -> PendingLookup {
        await service.pendingStatus(Self.theirs(owner))
    }

    func smsRemainingSec(_ owner: PhoneBindOwner, phone: String) -> Int {
        service.smsRemainingSec(Self.theirs(owner), phone: phone, now: service.clock())
    }

    func smsSending(_ owner: PhoneBindOwner, phone: String) -> Bool {
        service.smsSending(Self.theirs(owner), phone: phone)
    }

    func sendCode(_ owner: PhoneBindOwner, phone: String, completion: @escaping @MainActor (PhoneBindSms) -> Void) {
        service.sendCode(Self.theirs(owner), phone: phone) { result in
            let mapped: PhoneBindSms = switch result {
            case .sent: .sent
            case .rateLimited: .rateLimited
            case .silent: .silent
            case let .field(_, textKey): .field(textKey: textKey)
            case let .risk(titleKey): .risk(titleKey: titleKey)
            case let .navigate(route): .navigate(route: route)
            case let .notice(textKey, trace6): .notice(textKey: textKey, trace6: trace6)
            }
            completion(mapped)
        }
    }

    func submitChange(
        _ owner: PhoneBindOwner, _ submission: PhoneChangeSubmission, stepUpToken: String?,
        completion: @escaping @MainActor (PhoneBindArrival) -> Void
    ) {
        let request = BindChangeRequest(
            key: submission.key, body: submission.body, summary: submission.summary, stepUpToken: stepUpToken
        )
        service.submitChange(Self.theirs(owner), request) { completion(Self.arrival($0)) }
    }

    func confirmChange(
        _ owner: PhoneBindOwner, key: String, stepUpToken: String?,
        completion: @escaping @MainActor (PhoneBindArrival) -> Void
    ) {
        service.confirmChange(Self.theirs(owner), key: key, stepUpToken: stepUpToken) { completion(Self.arrival($0)) }
    }

    func abandonChange(
        _ owner: PhoneBindOwner, key: String, completion: @escaping @MainActor (PhoneBindArrival) -> Void
    ) {
        service.abandonChange(Self.theirs(owner), key: key) { completion(Self.arrival($0)) }
    }
}

// MARK: - 设置页 + 换号 10003 面板

/// 设置页（Settings 路由视图）：换号子页的 10003 面板在 Features/Wallet，Feature 之间不依赖，由 App 套上（同注销页）；挂在背景层上，
/// 子页出现 / 关闭不改设置页本体的视图身份。面板随子页执行器重建换成新的。
struct SettingsRouteContent: View {
    @ObservedObject var host: MePageHost<SettingsController>
    let gates: WalletGates?

    var body: some View {
        SettingsScreen(host: host)
            .environment(\.phoneChangeNumberField, Self.numberField)
            .background(PhoneChangeStepUpLayer(settings: host.controller, gates: gates).id(host.serial))
    }

    /// 换号第 2 步的新号输入框：Login 的共用手机号组件（同 BindPhone 页用法：「+86」前缀、读屏标签、清除按钮、错误描边与说明，
    /// 电话键盘全 App 只写一处，BindPhoneLayoutTests）。
    static let numberField: @MainActor @Sendable (PhoneChangeNumberInput) -> AnyView = { input in
        var config = PhoneNumberInput<PhoneChangeField?>.Config()
        config.prefix = LoginDraftTexts.text(LoginKeys.phonePrefix)
        config.placeholder = input.placeholder
        config.label = input.label
        config.clearLabel = LoginDraftTexts.text(LoginKeys.phoneClear)
        config.identifier = input.identifier
        config.hint = input.hint
        config.error = input.error
        config.locked = input.locked
        config.showsClear = input.showsClear
        return AnyView(PhoneNumberInput(
            text: input.text, focus: input.focus, focusValue: input.focusValue, config: config, onClear: input.onClear
        ))
    }
}

private struct PhoneChangeStepUpLayer: View {
    @ObservedObject var settings: SettingsController
    let gates: WalletGates?

    var body: some View {
        if let phoneChange = settings.phoneChange, let stepUp = phoneChange.stepUp, let gates {
            PhoneChangeStepUpAnchor(
                phoneChange: phoneChange, stepUp: stepUp, smsGate: gates.sms, verifyGate: gates.verify
            )
        }
    }
}

/// 设置页只在换子页时发变化；说明行的号在换号子页的 state 里，这里直接观察子页执行器，号一变半屏跟着重绘
/// （FU-IOS-PHONECHANGE-STEPUP-TITLE，D10-2281）。
private struct PhoneChangeStepUpAnchor: View {
    @ObservedObject var phoneChange: PhoneChangeController
    let stepUp: StepUpController
    @ObservedObject var smsGate: RetryAfterGate
    @ObservedObject var verifyGate: RetryAfterGate

    private var texts: PhoneChangePanelTexts {
        PhoneChangePanelTexts(maskedPhone: phoneChange.state.panelMaskedPhone)
    }

    var body: some View {
        Color.clear
            .walletStepUpSheet(stepUp, texts: texts, smsBlocked: smsGate.blocked, verifyBlocked: verifyGate.blocked)
    }
}

/// 换号 10003 面板的文案表（FU-IOS-PHONECHANGE-STEPUP-TITLE，D10-2281）：其余键原样转给 AccountDraftTexts（标题
/// step_up.title.phone_change 在那里）；说明行 step_up.summary.phone_change 填打开面板时固定的脱敏新号，没有号码时 has 为 false、
/// 面板不显示说明行。
struct PhoneChangePanelTexts: WalletTexts {
    static let summaryKey = "step_up.summary.phone_change"

    let maskedPhone: String?
    private let base = AccountDraftTexts()

    init(maskedPhone: String?) {
        self.maskedPhone = maskedPhone.flatMap { $0.isEmpty ? nil : $0 }
    }

    func text(_ key: String) -> String {
        guard key == Self.summaryKey, let maskedPhone else { return base.text(key) }
        return base.format(key, ["phone": maskedPhone])
    }

    func format(_ key: String, _ vars: [String: String]) -> String {
        guard key == Self.summaryKey, let maskedPhone else { return base.format(key, vars) }
        return base.format(key, vars.merging(["phone": maskedPhone]) { given, _ in given })
    }

    func has(_ key: String) -> Bool {
        key == Self.summaryKey ? maskedPhone != nil && base.has(key) : base.has(key)
    }
}
