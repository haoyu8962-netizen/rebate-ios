import CouliNetwork
import DesignSystem
import Foundation
import SwiftUI
import WalletCore

/// 实名页的回调（渲染时取出表单身份与单独同意半屏实例，共性第 59、63 条，APP-11 第 17、28 条）。
@MainActor
public struct RealNameActions {
    public let name: (String) -> Void
    public let idNo: (String) -> Void
    public let submit: () -> Void
    public let toggleConsent: () -> Void
    public let agree: () -> Void
    public let decline: () -> Void
    public let recheck: () -> Void

    public static func make(_ controller: RealNameController, _ snapshot: RealNameSnapshot) -> RealNameActions {
        let owner = snapshot.owner
        let consent = snapshot.consentId ?? -1
        return RealNameActions(
            name: { [weak controller] in controller?.onNameChange($0, owner: owner) },
            idNo: { [weak controller] in controller?.onIdChange($0, owner: owner) },
            submit: { [weak controller] in controller?.submit(owner: owner) },
            toggleConsent: { [weak controller] in controller?.toggleConsent(consent: consent, owner: owner) },
            agree: { [weak controller] in controller?.agreeAndSubmit(consent: consent, owner: owner) },
            decline: { [weak controller] in controller?.declineConsent(consent: consent) },
            recheck: { [weak controller] in controller?.recheckIdentity() }
        )
    }
}

/// 实名认证（RealName 路由；设计稿 RealName、RealNameConsent）：单独同意默认不勾选、点遮罩不关闭，关闭后焦点回到【提交认证】。
/// Release 里【提交认证】置灰并显示「实名认证暂未开放」（G01）。
public struct RealNameScreen: View {
    @ObservedObject var controller: RealNameController
    @ObservedObject var gate: RetryAfterGate
    @ObservedObject var context: WalletPageContext
    @AccessibilityFocusState var submitFocused: Bool
    @State var toast: CouliToastMessage?
    /// 字段错误的首错定位（同收款账号页 R1-11，共性第 24、74、79 条，iOS R2-06）：首个错误字段的错误提示是读屏焦点与滚动目标。
    @AccessibilityFocusState var focusedField: String?
    @State var errorCue = FieldErrorCue()
    @State var scrollRequest: FieldScrollRequest?

    public init(controller: RealNameController, context: WalletPageContext) {
        self.controller = controller
        gate = controller.gate
        self.context = context
    }

    var texts: WalletTexts {
        context.texts
    }

    /// 错误条的滚动目标。
    private static let errorAnchor = "realname.errorBar"

    public var body: some View {
        let snapshot = controller.state
        let actions = RealNameActions.make(controller, snapshot)
        WalletPageScaffold(
            title: texts.text("realname.title"), backLabel: texts.text("wallet.back"), onBack: context.onBack,
            identifier: "realname.page"
        ) {
            ScrollViewReader { proxy in
                ScrollView {
                    form(snapshot, actions)
                        .padding(.top, CouliSpacing.s2)
                        .padding([.horizontal, .bottom], CouliSpacing.s4)
                        .frame(maxWidth: WalletLayout.maxContentWidth)
                        .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: scrollRequest) { request in
                    guard let request else { return }
                    withAnimation { proxy.scrollTo(request.anchor, anchor: .center) }
                }
            }
        } bottom: {
            VStack(spacing: CouliSpacing.s2) {
                if snapshot.showsRecheck {
                    CouliButton(texts.text("wallet.retry"), kind: .text, action: actions.recheck)
                }
                if !controller.available {
                    RecordText(texts.text("realname.unavailable"), style: .footnote, color: CouliColor.textSecondary,
                               probe: "realname.unavailable")
                        .accessibilityIdentifier("realname.unavailable")
                }
                CouliButton(texts.text("realname.submit"), isLoading: snapshot.showsSubmitting,
                            isEnabled: controller.submitEnabled && !gate.blocked, fillsWidth: true,
                            action: actions.submit)
                    .accessibilityFocused($submitFocused)
                    .walletProbe("realname.submit", role: "button")
                    .accessibilityIdentifier("realname.submit")
            }
            .padding([.top, .bottom], CouliSpacing.s3)
            .padding(.horizontal, CouliSpacing.s4)
            .frame(maxWidth: WalletLayout.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .couliSheet(isPresented: snapshot.consentId != nil, dismissOnScrim: nil, restoreFocusTo: $submitFocused) {
            consentSheet(snapshot, actions)
        }
        .couliToast($toast)
        .onChange(of: snapshot.done) { value in
            guard let value else { return }
            toast = value.toast(texts)
            controller.consumeDone(value.id)
        }
        .onChange(of: snapshot.fieldErrorId) { id in
            errorCue.arm(event: "F\(id)", errors: controller.state.fieldErrors, order: FieldErrorCue.realNameOrder)
        }
        .onChange(of: snapshot.error?.id) { id in
            // 错误条在输入卡下（W92），大字号时落在首屏外：出错滚到它，看得到提交结果（只滚动，错误内容与提交流程不变）
            guard let id else { return }
            scrollRequest = FieldScrollRequest(event: "E\(id)", anchor: Self.errorAnchor)
        }
    }

    /// 设计稿 RealName：头部说明卡、字段卡、错误条（表单下方，读屏在字段之后，W92）、两条卡外浅底说明条。
    func form(_ snapshot: RealNameSnapshot, _ actions: RealNameActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            header
            VStack(alignment: .leading, spacing: WalletFieldMetric.fieldGap) {
                identityField(RealNameController.fieldName, snapshot.name, read: { [controller] in
                    controller.state.name
                }, snapshot, set: actions.name)
                identityField(RealNameController.fieldId, snapshot.idNo, read: { [controller] in
                    controller.state.idNo
                }, snapshot, set: actions.idNo)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .couliCard()
            .walletProbe("realname.formCard", role: "card")
            if let error = snapshot.error {
                NoticeBar(text: error.message(texts), noticeId: error.id, identifier: "realname.error", tone: .error)
                    .id(Self.errorAnchor)
            }
            WalletInfoStrip(text: texts.text("realname.note_fixed"), probe: "realname.note.fixed")
            WalletInfoStrip(text: texts.text("realname.note_age"), icon: .user, probe: "realname.note.age")
        }
    }

    /// 头部说明卡（W89）：40 方块 + 24 盾牌、标题 17/600、说明 14。
    var header: some View {
        HStack(alignment: .top, spacing: CouliSpacing.s3) {
            RealNameBadge()
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                RecordText(texts.text("realname.intro"), style: .body, weight: .couliSemibold,
                           color: CouliColor.textPrimary, probe: "realname.title")
                RecordText(texts.text("realname.intro_desc"), style: .footnote, color: CouliColor.textSecondary,
                           probe: "realname.desc")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .couliCard()
        .walletProbe("realname.header", role: "card")
    }

    /// 姓名 / 身份证号输入框（`name` 是契约字段名；文案键 realname.name / realname.id_no 与各自的 _placeholder）。
    /// `read` 取执行器当前值（`WalletInputField`）。
    func identityField(_ name: String, _ value: String, read: @escaping () -> String, _ snapshot: RealNameSnapshot,
                       set: @escaping (String) -> Void) -> some View {
        let label = name == RealNameController.fieldName ? "realname.name" : "realname.id_no"
        let placeholder = label + "_placeholder"
        let hasError = snapshot.fieldErrors.contains(name)
        let errorText = hasError ? texts.text("error.20001") : nil
        return VStack(alignment: .leading, spacing: WalletFieldMetric.gap) {
            WalletFieldLabel(text: texts.text(label), probe: "realname.field.\(name).label")
            WalletInputField(
                placeholder: texts.text(placeholder), label: texts.text(label),
                identifier: "realname.field.\(name)", probe: "realname.field.\(name).box", value: value, current: read,
                capitalization: name == RealNameController.fieldId ? .characters : .never, hasError: hasError,
                hint: errorText ?? "", set: set,
                reveal: {
                    scrollRequest = FieldScrollRequest(event: UUID().uuidString,
                                                       anchor: WalletFieldMetric.anchor(name))
                }
            )
            .autocorrectionDisabled(true)
            .disabled(!controller.available || snapshot.submitting)
            .id(WalletFieldMetric.anchor(name))
            if let errorText {
                fieldErrorText(errorText, field: name)
            }
        }
    }

    /// 字段旁的错误提示（关联说明，W82 同款 16 三角 + 14 红字）：可访问焦点与滚动目标；出现后（或错误事件编号变化时）按 `FieldErrorCue` 定位一次。
    func fieldErrorText(_ text: String, field: String) -> some View {
        HStack(alignment: .top, spacing: CouliSpacing.s1) {
            WalletErrorIcon(probe: "realname.fieldError.\(field).icon")
            RecordText(text, style: .footnote, color: CouliColor.statusErrorText, probe: "realname.fieldError.\(field)")
                .accessibilityFocused($focusedField, equals: field)
                .accessibilityIdentifier("realname.fieldError.\(field)")
        }
        .id(FieldScrollRequest.anchor(field))
        .task(id: errorCue.event) { await locate(field, text: text) }
    }

    /// 首个错误字段的错误视图已出现：滚动到它、移读屏焦点，并按事件编号播报一次（重绘不重复，保留输入）。
    func locate(_ field: String, text: String) async {
        guard let event = errorCue.appeared(field) else { return }
        scrollRequest = FieldScrollRequest(event: event, anchor: FieldScrollRequest.anchor(field))
        // 等滚动落定再移焦点（大字号下首错可能在屏外）
        try? await Task.sleep(nanoseconds: 300_000_000)
        focusedField = field
        WalletAnnounce.post(text, assertive: true)
    }

    /// 单独同意半屏（W93）。底版这里会崩：`AsyncRenderer` 线程求值 `ForEach` 内容闭包，Swift 6 隔离检查 SIGTRAP（Debug、模拟器、iOS 26.5，底版 32/32）。
    /// 现版 0/32，但把 `ForEach` 放回现版也是 0/80：去掉 `ForEach` 不是修好崩溃的原因，真正起作用的改动未定位。
    /// 这里不用 `ForEach` 只是保守写法（字面守卫锁定），不要当成已证实的修法。
    func consentSheet(_ snapshot: RealNameSnapshot, _ actions: RealNameActions) -> some View {
        CouliSheet(title: texts.text("realname.consent.title"), closeLabel: texts.text("realname.consent.cancel"),
                   titleStyle: .title, showsClose: false, probeID: "consent", topPadding: CouliSpacing.s5,
                   onClose: actions.decline) {
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                consentItem(1, "realname.consent.item1", .user)
                consentItem(2, "realname.consent.item2", .shieldCheck)
                consentItem(3, "realname.consent.item3", .info)
                consentBody
            }
            CheckRow(title: texts.text("realname.consent.check"), checked: snapshot.consentChecked,
                     action: actions.toggleConsent, identifier: "realname.consent.check", probe: "consent.check")
        } actions: {
            CouliButton(texts.text("realname.consent.ok"), isEnabled: snapshot.consentChecked, fillsWidth: true,
                        action: actions.agree)
                .walletProbe("consent.ok", role: "button")
                .accessibilityIdentifier("realname.consent.ok")
            CouliButton(texts.text("realname.consent.cancel"), kind: .secondary, fillsWidth: true, weight: .couliMedium,
                        action: actions.decline)
                .walletProbe("consent.cancel", role: "button")
                .accessibilityIdentifier("realname.consent.cancel")
        }
        .accessibilityAction(.escape, actions.decline)
    }

    /// 要点（W93）：20 次文字色图标 + 17 主文字。
    private func consentItem(_ index: Int, _ key: String, _ icon: CouliIcon) -> some View {
        HStack(alignment: .top, spacing: CouliSpacing.s3) {
            CouliIconView(icon, size: CouliGuideMetric.iconMedium, relativeTo: .body)
                .foregroundColor(CouliColor.textSecondary)
                .walletProbe("consent.item.\(index).icon", role: "icon")
                .accessibilityHidden(true)
            RecordText(texts.text(key), style: .body, color: CouliColor.textPrimary, probe: "consent.item.\(index)")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var consentBody: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            RecordText(texts.text("realname.consent.body_title"), style: .footnote, weight: .couliMedium,
                       color: CouliColor.textPrimary, probe: "consent.body.title")
            RecordText(texts.text("realname.consent.body"), style: .footnote, color: CouliColor.textSecondary,
                       probe: "consent.body.text")
        }
        .padding(CouliSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous).fill(CouliColor.backgroundMuted)
        )
    }
}

/// 实名头部方块（W89）：40 `brand.subtle` 圆角 12 + 24 盾牌，随字号缩放。
struct RealNameBadge: View {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 40

    var body: some View {
        CouliIconView(.shieldCheck, size: 24, relativeTo: .body)
            .foregroundColor(CouliColor.brandEmphasis)
            .walletProbe("realname.badge.icon", role: "icon")
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .fill(CouliColor.brandSubtle))
            .walletProbe("realname.badge", role: "badge")
            .accessibilityHidden(true)
    }
}
