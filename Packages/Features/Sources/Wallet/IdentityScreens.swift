import CouliNetwork
import DesignSystem
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
                        .padding(CouliSpacing.s4)
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
                    Text(verbatim: texts.text("realname.unavailable"))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .accessibilityIdentifier("realname.unavailable")
                }
                CouliButton(texts.text("realname.submit"), isLoading: snapshot.showsSubmitting,
                            isEnabled: controller.submitEnabled && !gate.blocked, fillsWidth: true,
                            action: actions.submit)
                    .accessibilityFocused($submitFocused)
                    .accessibilityIdentifier("realname.submit")
            }
            .padding(CouliSpacing.s4)
            .frame(maxWidth: WalletLayout.maxContentWidth)
            .frame(maxWidth: .infinity)
            .background(CouliColor.backgroundSurface.ignoresSafeArea(edges: .bottom))
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
    }

    /// 设计稿 RealName：介绍卡（标题 + 说明）、字段卡、两条卡外浅底说明条。
    func form(_ snapshot: RealNameSnapshot, _ actions: RealNameActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                Text(verbatim: texts.text("realname.intro"))
                    .couliFont(.body, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                Text(verbatim: texts.text("realname.intro_desc"))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .couliCard()
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                if let error = snapshot.error {
                    NoticeBar(text: error.message(texts), noticeId: error.id, identifier: "realname.error")
                }
                identityField(RealNameController.fieldName, snapshot.name, snapshot, set: actions.name)
                identityField(RealNameController.fieldId, snapshot.idNo, snapshot, set: actions.idNo)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .couliCard()
            noteStrip("realname.note_fixed", icon: .info)
            noteStrip("realname.note_age", icon: .user)
        }
    }

    func noteStrip(_ key: String, icon: CouliIcon) -> some View {
        HStack(alignment: .top, spacing: CouliSpacing.s2) {
            CouliIconView(icon, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                .foregroundColor(CouliColor.textSecondary)
                .accessibilityHidden(true)
            Text(verbatim: texts.text(key))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CouliSpacing.s3)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous).fill(CouliColor.backgroundMuted)
        )
        .accessibilityElement(children: .combine)
    }

    /// 姓名 / 身份证号输入框（`name` 是契约字段名；文案键 realname.name / realname.id_no 与各自的 _placeholder）。
    func identityField(_ name: String, _ value: String, _ snapshot: RealNameSnapshot,
                       set: @escaping (String) -> Void) -> some View {
        let label = name == RealNameController.fieldName ? "realname.name" : "realname.id_no"
        let placeholder = label + "_placeholder"
        let hasError = snapshot.fieldErrors.contains(name)
        let errorText = hasError ? texts.text("error.20001") : nil
        return VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            Text(verbatim: texts.text(label))
                .couliFont(.footnote, weight: .couliSemibold)
                .foregroundColor(CouliColor.textSecondary)
            TextField(texts.text(placeholder), text: Binding(get: { value }, set: set))
                .textInputAutocapitalization(name == RealNameController.fieldId ? .characters : .never)
                .autocorrectionDisabled(true)
                .couliFont(.body)
                .padding(CouliSpacing.s3)
                .frame(minHeight: CouliHitTarget.minimum)
                .background(RoundedRectangle(cornerRadius: CouliRadius.button)
                    .stroke(hasError ? CouliColor.statusErrorText : CouliColor.borderControl))
                .disabled(!controller.available || snapshot.submitting)
                .accessibilityLabel(Text(verbatim: texts.text(label)))
                .accessibilityHint(Text(verbatim: errorText ?? ""))
                .accessibilityIdentifier("realname.field.\(name)")
            if let errorText {
                fieldErrorText(errorText, field: name)
            }
        }
    }

    /// 字段旁的错误提示（关联说明）：可访问焦点与滚动目标；出现后（或错误事件编号变化时）按 `FieldErrorCue` 定位一次。
    func fieldErrorText(_ text: String, field: String) -> some View {
        Text(verbatim: text)
            .couliFont(.footnote)
            .foregroundColor(CouliColor.statusErrorText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityFocused($focusedField, equals: field)
            .accessibilityIdentifier("realname.fieldError.\(field)")
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

    func consentSheet(_ snapshot: RealNameSnapshot, _ actions: RealNameActions) -> some View {
        CouliSheet(title: texts.text("realname.consent.title"), closeLabel: texts.text("realname.consent.cancel"),
                   onClose: actions.decline) {
            // 设计稿 RealNameConsent：三条带图标的说明 + 浅底正文块
            ForEach([("realname.consent.item1", CouliIcon.user), ("realname.consent.item2", .check),
                     ("realname.consent.item3", .info)], id: \.0) { key, icon in
                HStack(alignment: .top, spacing: CouliSpacing.s2) {
                    CouliIconView(icon, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .accessibilityHidden(true)
                    Text(verbatim: texts.text(key))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                Text(verbatim: texts.text("realname.consent.body_title"))
                    .couliFont(.footnote, weight: .couliSemibold)
                Text(verbatim: texts.text("realname.consent.body"))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(CouliSpacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous).fill(CouliColor.backgroundMuted)
            )
            CheckRow(title: texts.text("realname.consent.check"), checked: snapshot.consentChecked,
                     action: actions.toggleConsent, identifier: "realname.consent.check")
        } actions: {
            CouliButton(texts.text("realname.consent.ok"), isEnabled: snapshot.consentChecked, fillsWidth: true,
                        action: actions.agree)
                .accessibilityIdentifier("realname.consent.ok")
            CouliButton(texts.text("realname.consent.cancel"), kind: .secondary, fillsWidth: true,
                        action: actions.decline)
                .accessibilityIdentifier("realname.consent.cancel")
        }
        .accessibilityAction(.escape, actions.decline)
    }
}

/// 勾选行（读屏为勾选框：已选 / 未选，44pt 命中区）。
struct CheckRow: View {
    let title: String
    let checked: Bool
    let action: () -> Void
    let identifier: String

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                CheckMark(checked: checked)
                Text(verbatim: title)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
        .accessibilityAddTraits(checked ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// 勾选框（设计稿 LaborAgreement / RealNameConsent：未勾空心圆角方框，勾选品牌色实心 + 白勾）；读屏由按钮的 isSelected 表达。
struct CheckMark: View {
    let checked: Bool
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                .fill(checked ? CouliColor.brandPrimary : CouliColor.backgroundSurface)
            RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                .stroke(checked ? CouliColor.brandPrimary : CouliColor.borderControl, lineWidth: 1.5)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: size / 2, weight: .bold))
                    .foregroundColor(CouliColor.backgroundSurface)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
