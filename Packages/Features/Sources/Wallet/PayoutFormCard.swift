import DesignSystem
import Foundation
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
            RecordText(texts.text("payout.intro"), style: .footnote, color: CouliColor.textSecondary,
                       probe: "payout.intro")
                .padding(.horizontal, CouliSpacing.s1)
            methodGroup(form.method, error: errors.contains(PayoutAccountForm.payoutMethod) ? flowState : nil,
                        editable: editable, actions)
                .frame(maxWidth: .infinity, alignment: .leading)
                .couliCard(padding: 0)
                .walletProbe("payout.methodCard", role: "card")
            VStack(alignment: .leading, spacing: WalletFieldMetric.fieldGap) {
                if bank {
                    field("payout.card_no", "payout.card_no_placeholder", \.cardNo, PayoutAccountForm.cardNo,
                          errors, flowState, editable: editable, keyboard: .numberPad, set: actions.card)
                    field("payout.bank_name", "payout.bank_name_placeholder", \.bankName,
                          PayoutAccountForm.bankName, errors, flowState, editable: editable, set: actions.bank)
                } else {
                    field("payout.alipay_account", "payout.alipay_placeholder", \.alipayLogonId,
                          PayoutAccountForm.alipayLogonId, errors, flowState, editable: editable,
                          keyboard: .emailAddress, set: actions.logon)
                }
                field("payout.payee", "payout.payee_placeholder", \.payeeName, PayoutAccountForm.payeeName,
                      errors, flowState, editable: editable, note: texts.text("payout.payee_note"),
                      set: actions.payee)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .couliCard()
            .walletProbe("payout.formCard", role: "card")
            WalletInfoStrip(text: texts.text(bank ? "payout.bank_note" : "payout.step_up_note"),
                            probe: "payout.saveNote")
        }
    }

    func methodGroup(_ method: String, error: FlowState?, editable: Bool, _ actions: PayoutActions) -> some View {
        let errorText = error.map { texts.text($0.fieldErrorKey ?? "error.20001") }
        return VStack(alignment: .leading, spacing: 0) {
            RecordText(texts.text("payout.method"), style: .footnote, color: CouliColor.textSecondary,
                       probe: "payout.method.label")
                .padding(.top, CouliSpacing.s3)
            // 两项展开写，不用 ForEach：保守写法，这里没有崩溃记录（见 consentSheet 的说明）
            methodRow(WalletJSON.alipay, method, "payout.alipay", errorText, editable: editable, actions)
            RecordDivider()
                .walletProbe("payout.method.divider", role: "divider")
            methodRow(WalletJSON.bankCard, method, "payout.bank", errorText, editable: editable, actions)
            if let errorText {
                fieldErrorText(errorText, field: PayoutAccountForm.payoutMethod)
                    .padding(.bottom, CouliSpacing.s3)
            }
        }
        .padding(.horizontal, CouliSpacing.s4)
    }

    // swiftlint:disable:next function_parameter_count
    private func methodRow(_ value: String, _ method: String, _ key: String, _ errorText: String?, editable: Bool,
                           _ actions: PayoutActions) -> some View {
        let selected = method == value
        let probe = value == WalletJSON.alipay ? "payout.method.alipay" : "payout.method.bank"
        return Button {
            actions.method(value)
        } label: {
            HStack(alignment: .center, spacing: CouliSpacing.s3) {
                RadioMark(selected: selected)
                    .walletProbe(probe + ".radio", role: "radio")
                VStack(alignment: .leading, spacing: 2) {
                    RecordText(texts.text(key), style: .body, weight: selected ? .couliSemibold : .regular,
                               color: CouliColor.textPrimary, probe: probe + ".title")
                    RecordText(texts.text(key + "_desc"), style: .caption, color: CouliColor.textSecondary,
                               probe: probe + ".desc")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .walletProbe(probe, role: "row")
            .padding(.vertical, CouliSpacing.s3)
            .frame(minHeight: CouliHitTarget.minimum)
            .contentShape(Rectangle())
            .walletProbe(probe + ".hit", role: "hit")
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
        .disabled(!editable)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(Text(verbatim: errorText ?? ""))
        .accessibilityIdentifier(probe)
    }

    // swiftlint:disable function_parameter_count
    /// `path`：表单里的这一格。框内文字对回时读执行器当前值，不读这次渲染的快照（`WalletInputField`）。
    func field(_ labelKey: String, _ placeholderKey: String, _ path: KeyPath<PayoutForm, String>, _ name: String,
               _ errors: Set<String>, _ flowState: FlowState, editable: Bool, keyboard: UIKeyboardType = .default,
               note: String? = nil, set: @escaping (String) -> Void) -> some View {
        let form = controller.state.form
        let submitted = submitError(flowState, form).flatMap { $0.field == name ? $0.notice : nil }
        let hasError = errors.contains(name) || submitted != nil
        let errorText = submitted?.message(texts) ?? (hasError ? texts.text(flowState.fieldErrors.contains(name)
                ? (flowState.fieldErrorKey ?? "error.20001") : "error.20001") : nil)
        return VStack(alignment: .leading, spacing: WalletFieldMetric.gap) {
            WalletFieldLabel(text: texts.text(labelKey), probe: "payout.field.\(name).label")
            WalletInputField(
                placeholder: texts.text(placeholderKey), label: texts.text(labelKey),
                identifier: "payout.field.\(name)", probe: "payout.field.\(name).box", value: form[keyPath: path],
                current: { [controller] in controller.state.form[keyPath: path] }, keyboard: keyboard,
                hasError: hasError, hint: errorText ?? "", set: set,
                reveal: { revealInput(name) }
            )
            .autocorrectionDisabled(true)
            .disabled(!editable)
            .id(WalletFieldMetric.anchor(name))
            if let errorText {
                fieldErrorText(errorText, field: name)
            }
            if let note {
                RecordText(note, style: .caption, color: CouliColor.textSecondary, probe: "payout.payeeNote")
            }
        }
    }

    // swiftlint:enable function_parameter_count

    /// 焦点字段滚到可视区中部：键盘升起后底栏上移，否则字段留在底栏后面（下一个字段中部也露出来，不用先滚动）。
    func revealInput(_ name: String) {
        scrollRequest = FieldScrollRequest(event: UUID().uuidString, anchor: WalletFieldMetric.anchor(name))
    }

    /// 字段旁的错误提示：可访问焦点与滚动目标（`payout.err.<字段>`）；出现后（或错误事件编号变化时）按 `FieldErrorCue` 定位一次。
    func fieldErrorText(_ text: String, field: String) -> some View {
        // 字段错误共用样式（W50 / W82）：16 三角 + 14 红字；读屏与定位仍在文字上
        HStack(alignment: .top, spacing: CouliSpacing.s1) {
            WalletErrorIcon(probe: "payout.fieldError.\(field).icon")
            RecordText(text, style: .footnote, color: CouliColor.statusErrorText,
                       probe: "payout.fieldError.\(field).text")
                .accessibilityFocused($focusedField, equals: field)
                .accessibilityIdentifier("payout.fieldError.\(field)")
        }
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
