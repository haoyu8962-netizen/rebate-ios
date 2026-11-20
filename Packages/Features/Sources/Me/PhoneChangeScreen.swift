import CouliNetwork
import DesignSystem
import MeCore
import SwiftUI

/// 换手机号子页（设置 → 账号与安全 → 手机号；页内子页，不注册路由，G22）：两步（验证当前手机号 → 验证新手机号）+ Done + 待确认 + 弹窗。
/// 写法照设置子页（昵称 / 通知）：白卡、底部固定主按钮栏（键盘弹起时主按钮随栏上移、保持可见），ScrollView 承载 320 宽 / AX5。读屏：
/// 验证码框是一次性验证码输入（`.oneTimeCode` + 数字键盘，读「验证码，已输入 n 位，共 6 位」）；「已发送」礼貌播报、20002 / 20003 与
/// 待确认卡出现打断播报（`state.announce` 每条一次）；放弃确认是标准弹窗（点遮罩不关）。10003 面板由 App 套在设置页外层（Features 之间不依赖）。
struct PhoneChangeView: View {
    @ObservedObject var controller: PhoneChangeController
    @State private var announced = 0
    @FocusState private var focus: PhoneChangeField?
    @Environment(\.phoneChangeNumberField) private var numberField

    var texts: MeTexts {
        controller.texts
    }

    var body: some View {
        let state = controller.state
        let actions = PhoneChangeActions.make(controller, state)
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                        content(state, actions)
                    }
                    .padding(.top, CouliSpacing.s2)
                    .padding([.horizontal, .bottom], CouliSpacing.s4)
                    .meContentWidth()
                }
                bottomBar(state, actions, safeBottom: proxy.safeAreaInsets.bottom)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phoneChange.page")
        .couliDialog(isPresented: state.dialog != nil) {
            dialog(state.dialog ?? .unavailable(id: 0), actions)
        }
        .onChange(of: state.announce?.id) { id in
            // 读执行器此刻的状态（iOS 16 的 onChange 捕获的是上一次渲染的 state）
            guard let id, id != announced, let notice = controller.state.announce else { return }
            announced = id
            MeAnnounce.post(notice.message(texts), assertive: notice.assertive)
        }
    }

    @ViewBuilder
    private func content(_ state: PhoneChangeState, _ actions: PhoneChangeActions) -> some View {
        switch state.step {
        case .step1:
            step1(state, actions)
        case .step2:
            step2(state, actions)
        case .done:
            done(state)
        case .pending:
            if let card = state.pending {
                PhoneChangePendingView(card: card, state: state, actions: actions, texts: texts,
                                       enabled: controller.pendingActionsEnabled)
            }
        }
    }

    // MARK: - 第 1 步

    private func step1(_ state: PhoneChangeState, _ actions: PhoneChangeActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            MeText(texts.text("phone_change.intro"), style: .footnote, probe: "phoneChange.intro")
                .foregroundColor(CouliColor.textSecondary)
            VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                MeText(texts.text("phone_change.step1"), style: .body, weight: .couliSemibold,
                       probe: "phoneChange.step1")
                    .foregroundColor(CouliColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                MeText(texts.text("phone_change.current_hint"), style: .footnote, probe: "phoneChange.currentHint")
                    .foregroundColor(CouliColor.textSecondary)
                codeRow(code: state.oldCode, error: state.oldError, field: .oldCode, onChange: actions.oldCode,
                        send: sendButton(left: Int(state.oldResendLeftSec), sending: state.oldSending,
                                         enabled: controller.oldCodeSendEnabled, action: actions.requestOldCode))
                errorRow(state.oldError, id: "phoneChange.oldError")
            }
            .couliCard()
            Button(action: actions.oldUnavailable) {
                Text(verbatim: texts.text("phone_change.old_unavailable"))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textLink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: CouliHitTarget.minimum)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("phoneChange.oldUnavailable")
        }
    }

    // MARK: - 第 2 步

    private func step2(_ state: PhoneChangeState, _ actions: PhoneChangeActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                MeText(texts.text("phone_change.step2"), style: .body, weight: .couliSemibold,
                       probe: "phoneChange.step2")
                    .foregroundColor(CouliColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                phoneField(state, actions)
                errorRow(state.phoneError, id: "phoneChange.phoneError")
                MeText(texts.text("phone_change.new_hint"), style: .caption, probe: "phoneChange.newHint")
                    .foregroundColor(CouliColor.textSecondary)
                codeRow(code: state.newCode, error: state.codeError, field: .newCode, onChange: actions.newCode,
                        send: sendButton(left: state.newResendLeftSec, sending: state.newSending,
                                         enabled: controller.newCodeSendEnabled, action: actions.requestNewCode))
                errorRow(state.codeError, id: "phoneChange.codeError")
            }
            .couliCard()
            errorRow(state.notice, id: "phoneChange.notice")
            MeText(texts.text("phone_change.submit_hint"), style: .caption, probe: "phoneChange.submitHint")
                .foregroundColor(CouliColor.textSecondary)
        }
    }

    /// 新号输入框：用 App 注入的共用手机号组件（Login PhoneNumberField，电话键盘、读屏「新手机号 +86」、错误描边，全 App 只写一处，
    /// D10-1223）；没注入（视觉替身等）时退回普通单行框。
    @ViewBuilder
    private func phoneField(_ state: PhoneChangeState, _ actions: PhoneChangeActions) -> some View {
        let error = state.phoneError.map { $0.message(texts) }
        let phone = Binding(get: { state.newPhone }, set: { actions.newPhone($0) })
        if let numberField {
            numberField(PhoneChangeNumberInput(
                text: phone, focus: $focus, label: texts.text("phone_change.new_label"),
                placeholder: texts.text("phone_change.new_label"), hint: error ?? "", error: error != nil,
                locked: state.submitting, identifier: "phoneChange.newPhone", onClear: { actions.newPhone("") }
            ))
        } else {
            TextField(texts.text("phone_change.new_label"), text: phone)
                .couliFont(.body, monospacedDigits: true)
                .focused($focus, equals: .newPhone)
                .accessibilityLabel(Text(verbatim: texts.text("phone_change.new_label")))
                .accessibilityHint(Text(verbatim: error ?? ""))
                .accessibilityIdentifier("phoneChange.newPhone")
                .padding(.horizontal, CouliSpacing.s3)
                .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum)
                .background(fieldBorder(error: error != nil, focused: focus == .newPhone))
        }
    }

    private func codeRow(code: String, error: MeNotice?, field: PhoneChangeField, onChange: @escaping (String) -> Void,
                         send: some View) -> some View {
        let spoken = texts.format("step_up.code_spoken", ["n": String(code.count)])
        let message = error.map { $0.message(texts) }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: CouliSpacing.s2) {
                codeField(code, field: field, spoken: spoken, error: message, onChange: onChange)
                send
            }
            VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                codeField(code, field: field, spoken: spoken, error: message, onChange: onChange)
                send
            }
        }
    }

    private func codeField(_ code: String, field: PhoneChangeField, spoken: String, error: String?,
                           onChange: @escaping (String) -> Void) -> some View {
        TextField(texts.text("bind_phone.code.placeholder"), text: Binding(get: { code }, set: onChange))
            .couliFont(.body, monospacedDigits: true)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused($focus, equals: field)
            .accessibilityLabel(Text(verbatim: texts.text("step_up.code_label")))
            .accessibilityValue(Text(verbatim: spoken))
            .accessibilityHint(Text(verbatim: error ?? ""))
            .accessibilityIdentifier(field == .oldCode ? "phoneChange.oldCode" : "phoneChange.newCode")
            .padding(.horizontal, CouliSpacing.s3)
            .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum)
            .background(fieldBorder(error: error != nil, focused: focus == field))
    }

    // MARK: - 底部主按钮栏（键盘弹起时随栏上移）

    @ViewBuilder
    private func bottomBar(_ state: PhoneChangeState, _ actions: PhoneChangeActions, safeBottom: CGFloat) -> some View {
        if let primary = primary(state, actions) {
            VStack(spacing: 0) {
                SettingsDivider(probe: "phoneChange.bar.line")
                CouliButton(primary.title, isLoading: primary.loading, isEnabled: primary.enabled, fillsWidth: true,
                            action: primary.action)
                    .accessibilityIdentifier("phoneChange.primary")
                    .padding(.horizontal, CouliSpacing.s4)
                    .meContentWidth()
                    .padding(.top, CouliSpacing.s3)
                    .padding(.bottom, focus != nil ? CouliSpacing.s3 : max(0, CouliSpacing.s3 - safeBottom))
            }
            .background(CouliColor.backgroundSurface)
        }
    }
}

/// 底部固定栏的主按钮（第 1 步【下一步】、第 2 步【提交】、Done【完成】；待确认没有）。
struct PhoneChangePrimary {
    let title: String
    let loading: Bool
    let enabled: Bool
    let action: () -> Void
}

/// 子页里的输入焦点（新号输入框由 App 注入时也用它，底部栏据此判断键盘是否弹起）。
public enum PhoneChangeField: Hashable {
    case oldCode, newPhone, newCode
}

/// App 注入新号输入框时拿到的参数（Features 之间不依赖：共用手机号组件在 Features/Login，由 App 套进来）。
@MainActor
public struct PhoneChangeNumberInput {
    public let text: Binding<String>
    public let focus: FocusState<PhoneChangeField?>.Binding
    public let label: String
    public let placeholder: String
    public let hint: String
    public let error: Bool
    public let locked: Bool
    public let identifier: String
    public let onClear: () -> Void

    /// 新号框的焦点值；清除按钮只在聚焦且非空时出现（同 BindPhone 页）。
    public var focusValue: PhoneChangeField? {
        .newPhone
    }

    public var showsClear: Bool {
        focus.wrappedValue == .newPhone && !text.wrappedValue.isEmpty && !locked
    }
}

/// 新号输入框的构造（App 给；nil = 用子页自带的普通单行框）。
public extension EnvironmentValues {
    @Entry var phoneChangeNumberField: (@MainActor @Sendable (PhoneChangeNumberInput) -> AnyView)?
}
