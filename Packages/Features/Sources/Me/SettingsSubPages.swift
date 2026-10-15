import CouliNetwork
import DesignSystem
import MeCore
import SwiftUI

/// 修改昵称子页的回调（渲染时取出执行器与版本，共性第 6、59 条）。
@MainActor
public struct NicknameActions {
    public let input: (String) -> Void
    public let clear: () -> Void
    public let save: () -> Void

    public static func make(_ controller: NicknameController, _ state: NicknameState) -> NicknameActions {
        let version = state.version
        return NicknameActions(
            input: { [weak controller] text in controller?.input(text) },
            clear: { [weak controller] in controller?.clear() },
            save: { [weak controller] in controller?.save(version: version) }
        )
    }
}

/// 修改昵称（设计稿 SettingsNickname、SettingsNicknameSaved、SettingsNicknameSensitive、SettingsNicknameLimit）：预填当前昵称、清除按钮（读屏
/// 「清除昵称」）、计数「n/16」、说明句、【保存】。字段错误即时播报一次、焦点移到错误提示、错误说明关联到输入框、保留输入（APP-05b 第 6 条，
/// APP-09 第 24 条）。没有头像上传入口。
struct NicknameView: View {
    @ObservedObject var controller: NicknameController
    @ObservedObject var gate: RetryAfterGate
    @AccessibilityFocusState private var errorFocused: Bool
    @State private var announced = 0

    var texts: MeTexts {
        controller.deps.texts
    }

    var body: some View {
        let state = controller.state
        let actions = NicknameActions.make(controller, state)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                    field(state, actions)
                    Text(verbatim: texts.text("nickname.hint"))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("nickname.hint")
                }
                .padding(CouliSpacing.s4)
                .meContentWidth()
            }
            CouliButton(
                texts.text("nickname.save"), isLoading: state.saving,
                isEnabled: state.check.saveEnabled && !state.saving && !gate.blocked, fillsWidth: true,
                action: actions.save
            )
            .padding(CouliSpacing.s4)
            .meContentWidth()
            .accessibilityIdentifier("nickname.save")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nickname.page")
        .onChange(of: state.errorEvent) { event in
            // 统一错误事件（服务端字段错误与本地校验错误同一流程，R2-04）：每个事件播报一次，错误节点布局完成后再移焦点
            // 读执行器此刻的状态：iOS 16 的 onChange 闭包捕获的是上一次渲染的 `state`（那时错误还没出现）
            guard event != announced, let error = controller.state.error else { return }
            announced = event
            MeAnnounce.post(error.message(texts), assertive: true)
            Task { @MainActor in
                await Task.yield()
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard announced == event, controller.state.errorEvent == event,
                      controller.state.error != nil else { return }
                errorFocused = true
                MeAnnounceProbe.focused?("nickname.error")
            }
        }
    }

    private func field(_ state: NicknameState, _ actions: NicknameActions) -> some View {
        let error = state.error.map { $0.message(texts) }
        return VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            HStack(spacing: CouliSpacing.s2) {
                TextField(
                    texts.text("nickname.label"),
                    text: Binding(get: { state.input }, set: { actions.input($0) })
                )
                .couliFont(.body)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .accessibilityLabel(Text(verbatim: texts.text("nickname.label")))
                .accessibilityHint(Text(verbatim: error ?? ""))
                .accessibilityIdentifier("nickname.input")
                if !state.input.isEmpty {
                    Button {
                        actions.clear()
                    } label: {
                        CouliIconView(.close, size: CouliGuideMetric.iconInline, relativeTo: .body)
                            .foregroundColor(CouliColor.textSecondary)
                            .couliHitTarget()
                    }
                    .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
                    .accessibilityLabel(Text(verbatim: texts.text("nickname.clear")))
                    .accessibilityIdentifier("nickname.clear")
                }
                Text(verbatim: texts.format("nickname.counter", ["n": String(state.check.length)]))
                    .couliFont(.footnote, monospacedDigits: true)
                    .foregroundColor(state.check.length > NicknameInput.max ? CouliColor.statusWarningText
                        : CouliColor.textSecondary)
                    .accessibilityIdentifier("nickname.counter")
            }
            .padding(.horizontal, CouliSpacing.s3)
            .frame(minHeight: CouliHitTarget.minimum)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .stroke(error == nil ? CouliColor.borderSubtle : CouliColor.statusWarningText, lineWidth: 1)
            )
            if let error {
                Text(verbatim: error)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.statusWarningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($errorFocused)
                    .accessibilityIdentifier("nickname.error")
            }
        }
    }
}

/// 通知设置子页的回调。
@MainActor
public struct NotifyActions {
    public let toggle: (Bool) -> Void
    public let goSettings: () -> Void
    public let retry: () -> Void

    public static func make(_ controller: NotifySettingsController, _ state: NotifySettingsState) -> NotifyActions {
        let version = state.version
        return NotifyActions(
            toggle: { [weak controller] on in controller?.toggle(on, version: version) },
            goSettings: { [weak controller] in controller?.goSettings() },
            retry: { [weak controller] in controller?.load() }
        )
    }
}

/// 通知设置（设计稿 NotifySettings、NotifySettingsOn；G02）：系统通知未开启 → 提示条 perm.push.denied_forever +【去设置】；「服务类推送」开关
/// （Release 不显示开关行）与说明句。
struct NotifySettingsView: View {
    @ObservedObject var controller: NotifySettingsController
    @ObservedObject var gate: RetryAfterGate
    @Environment(\.scenePhase) private var scenePhase

    var texts: MeTexts {
        controller.deps.texts
    }

    var body: some View {
        let state = controller.state
        let actions = NotifyActions.make(controller, state)
        ScrollView {
            VStack(alignment: .leading, spacing: CouliSpacing.s4) {
                if state.systemGranted == false {
                    HStack(alignment: .center, spacing: CouliSpacing.s3) {
                        Text(verbatim: texts.text("perm.push.denied_forever"))
                            .couliFont(.footnote)
                            .foregroundColor(CouliColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CouliButton(texts.text("perm.go_settings"), kind: .secondary, size: .compact,
                                    action: actions.goSettings)
                            .fixedSize()
                            .accessibilityIdentifier("notify.goSettings")
                    }
                    .padding(CouliSpacing.s3)
                    .background(
                        RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                            .fill(CouliColor.statusWarningText.opacity(0.1))
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("notify.bar")
                }
                MeGroup {
                    if controller.hasSwitch, let service = state.service {
                        MeSwitchRow(
                            title: texts.text("notify.service"), subtitle: texts.text("notify.service_desc"),
                            isOn: service, enabled: !state.switching && !gate.blocked, texts: texts,
                            identifier: "notify.switch", onChange: actions.toggle
                        )
                    } else {
                        // Release（G02）：不显示开关行，只留说明句
                        Text(verbatim: texts.text("notify.service_desc"))
                            .couliFont(.footnote)
                            .foregroundColor(CouliColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(CouliSpacing.s4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("notify.desc")
                    }
                }
                if let error = state.error {
                    MeNoticeBar(text: error.message(texts), noticeId: error.id, retryTitle: texts.text("me.retry"),
                                retryEnabled: !gate.blocked, retry: actions.retry, identifier: "notify.error")
                }
            }
            .padding(CouliSpacing.s4)
            .meContentWidth()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notify.page")
        .meToast(state.toast, texts: texts) { controller.consumeToast($0) }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                controller.refreshSystem()
            }
        }
    }
}
