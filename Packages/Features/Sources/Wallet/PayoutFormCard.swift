import DesignSystem
import SwiftUI
import WalletCore

/// 收款账号表单（G12–G14）：单选「支付宝 / 本人借记卡」（各带说明）、字段、提示、字段错误（20001 data.fields 与本地校验；收款方式组的
/// 错误显示在组内、关联到两个选项，共性第 24、36 条）。
extension PayoutAccountScreen {
    func formCard(_ snapshot: PayoutSnapshot, _ flowState: FlowState, _ actions: PayoutActions) -> some View {
        let form = snapshot.form
        let errors = Set(snapshot.localErrors + flowState.fieldErrors)
        let editable = flowState.phase == .editing && flowState.pending == nil
        let bank = form.method == WalletJSON.bankCard
        // 设计稿 PayoutAccount / PayoutAccountBank：说明在卡外；收款方式一张卡；字段一张卡；保存说明为卡外浅底条
        return VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            Text(verbatim: texts.text("payout.intro"))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, CouliSpacing.s1)
            methodGroup(form.method, error: errors.contains(PayoutAccountForm.payoutMethod) ? flowState : nil,
                        editable: editable, actions)
                .frame(maxWidth: .infinity, alignment: .leading)
                .couliCard()
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                if bank {
                    field("payout.card_no", "payout.card_no_placeholder", form.cardNo, PayoutAccountForm.cardNo,
                          errors, flowState, editable: editable, keyboard: .numberPad, set: actions.card)
                    field("payout.bank_name", "payout.bank_name_placeholder", form.bankName,
                          PayoutAccountForm.bankName, errors, flowState, editable: editable, set: actions.bank)
                } else {
                    field("payout.alipay_account", "payout.alipay_placeholder", form.alipayLogonId,
                          PayoutAccountForm.alipayLogonId, errors, flowState, editable: editable,
                          keyboard: .emailAddress, set: actions.logon)
                }
                field("payout.payee", "payout.payee_placeholder", form.payeeName, PayoutAccountForm.payeeName,
                      errors, flowState, editable: editable, set: actions.payee)
                Text(verbatim: texts.text("payout.payee_note"))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .couliCard()
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                CouliIconView(.info, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: texts.text(bank ? "payout.bank_note" : "payout.step_up_note"))
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
    }

    func methodGroup(_ method: String, error: FlowState?, editable: Bool, _ actions: PayoutActions) -> some View {
        let errorText = error.map { texts.text($0.fieldErrorKey ?? "error.20001") }
        return VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            Text(verbatim: texts.text("payout.method"))
                .couliFont(.footnote, weight: .couliSemibold)
                .foregroundColor(CouliColor.textSecondary)
            ForEach([WalletJSON.alipay, WalletJSON.bankCard], id: \.self) { value in
                let key = value == WalletJSON.alipay ? "payout.alipay" : "payout.bank"
                if value == WalletJSON.bankCard {
                    Divider()
                }
                Button {
                    actions.method(value)
                } label: {
                    HStack(alignment: .top, spacing: CouliSpacing.s2) {
                        RadioMark(selected: method == value)
                        VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                            Text(verbatim: texts.text(key))
                                .couliFont(.body)
                                .foregroundColor(CouliColor.textPrimary)
                            Text(verbatim: texts.text(key + "_desc"))
                                .couliFont(.footnote)
                                .foregroundColor(CouliColor.textSecondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
                .disabled(!editable)
                .accessibilityAddTraits(method == value ? [.isSelected, .isButton] : .isButton)
                .accessibilityHint(Text(verbatim: errorText ?? ""))
                .accessibilityIdentifier(value == WalletJSON.alipay ? "payout.method.alipay" : "payout.method.bank")
            }
            if let errorText {
                fieldErrorText(errorText, field: PayoutAccountForm.payoutMethod)
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    func field(_ labelKey: String, _ placeholderKey: String, _ value: String, _ name: String, _ errors: Set<String>,
               _ flowState: FlowState, editable: Bool, keyboard: UIKeyboardType = .default,
               set: @escaping (String) -> Void) -> some View {
        let hasError = errors.contains(name)
        let errorText = hasError ? texts.text(flowState.fieldErrors.contains(name)
            ? (flowState.fieldErrorKey ?? "error.20001") : "error.20001") : nil
        return VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            Text(verbatim: texts.text(labelKey))
                .couliFont(.footnote, weight: .couliSemibold)
                .foregroundColor(CouliColor.textSecondary)
            TextField(texts.text(placeholderKey), text: Binding(get: { value }, set: set))
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .couliFont(.body)
                .padding(CouliSpacing.s3)
                .frame(minHeight: CouliHitTarget.minimum)
                .background(RoundedRectangle(cornerRadius: CouliRadius.button)
                    .stroke(hasError ? CouliColor.statusErrorText : CouliColor.borderControl))
                .disabled(!editable)
                .accessibilityLabel(Text(verbatim: texts.text(labelKey)))
                .accessibilityHint(Text(verbatim: errorText ?? ""))
                .accessibilityIdentifier("payout.field.\(name)")
            if let errorText {
                fieldErrorText(errorText, field: name)
            }
        }
    }

    /// 字段旁的错误提示：可访问焦点与滚动目标（`payout.err.<字段>`）；出现后（或错误事件编号变化时）按 `FieldErrorCue` 定位一次。
    func fieldErrorText(_ text: String, field: String) -> some View {
        Text(verbatim: text)
            .couliFont(.footnote)
            .foregroundColor(CouliColor.statusErrorText)
            .accessibilityFocused($focusedField, equals: field)
            .accessibilityIdentifier("payout.fieldError.\(field)")
            .id(FieldScrollRequest.anchor(field))
            .task(id: errorCue.event) { await locate(field, text: text) }
    }

    /// 首个错误字段的错误视图已出现：滚动到它、移读屏焦点，并按事件编号播报一次（重绘不重复）。
    func locate(_ field: String, text: String) async {
        guard let event = errorCue.appeared(field) else { return }
        scrollRequest = FieldScrollRequest(event: event, anchor: FieldScrollRequest.anchor(field))
        // 等滚动落定再移焦点（大字号下首错可能在屏外）
        try? await Task.sleep(nanoseconds: 300_000_000)
        focusedField = field
        WalletAnnounce.post(text, assertive: true)
    }
}

/// 一次滚到错误字段的请求（同一字段的新错误事件也要再滚一次，所以带事件编号）。
struct FieldScrollRequest: Equatable {
    let event: String
    let anchor: String

    static func anchor(_ field: String) -> String {
        "payout.err.\(field)"
    }
}

/// 单选圆点（设计稿 PayoutAccount：未选空心圆、选中品牌色实心圆 + 白点）；读屏由按钮的 isSelected 表达。
struct RadioMark: View {
    let selected: Bool
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle()
                .stroke(selected ? CouliColor.brandPrimary : CouliColor.borderControl, lineWidth: 1.5)
            if selected {
                Circle().fill(CouliColor.brandPrimary)
                Circle().fill(CouliColor.backgroundSurface).frame(width: size / 3, height: size / 3)
            }
        }
        .frame(width: size, height: size)
        .padding(.top, 1)
        .accessibilityHidden(true)
    }
}
