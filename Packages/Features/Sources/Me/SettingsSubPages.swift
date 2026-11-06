import ClientCore
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

/// 修改昵称（设计稿 SettingsNickname、SettingsNicknameSaved、SettingsNicknameSensitive、SettingsNicknameLimit）：白卡内 标签 → 输入框（框内计数
/// 「n/16」、清除，读屏「清除昵称」）→ 错误 → 说明句，【保存】在底部固定栏（G-S09）。字段错误即时播报一次、焦点移到错误提示、错误说明关联到输入框、
/// 保留输入（APP-05b 第 6 条，APP-09 第 24 条）。没有头像上传入口。
struct NicknameView: View {
    @ObservedObject var controller: NicknameController
    @ObservedObject var gate: RetryAfterGate
    @AccessibilityFocusState private var errorFocused: Bool
    @FocusState private var inputFocused: Bool
    @State private var announced = 0

    var texts: MeTexts {
        controller.deps.texts
    }

    var body: some View {
        let state = controller.state
        let actions = NicknameActions.make(controller, state)
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    card(state, actions)
                        .padding(.top, CouliSpacing.s2)
                        .padding([.horizontal, .bottom], CouliSpacing.s4)
                        .meContentWidth()
                }
                saveBar(state, actions, safeBottom: proxy.safeAreaInsets.bottom)
            }
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

    private func card(_ state: NicknameState, _ actions: NicknameActions) -> some View {
        let error = state.error.map { $0.message(texts) }
        return VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            // 可见标签不单独成读屏项：名称在输入框上（APP-12v K6：accessibilityHidden 在 XCUI 树里还在）
            MeText(texts.text("nickname.label"), style: .body, weight: .couliSemibold, probe: "nickname.label")
                .foregroundColor(CouliColor.textPrimary)
                .accessibilityRepresentation { EmptyView() }
            field(state, actions, error: error)
            if let error {
                errorRow(error)
            }
            MeText(texts.text("nickname.hint"), style: .caption, probe: "nickname.hint")
                .foregroundColor(CouliColor.textSecondary)
                .accessibilityIdentifier("nickname.hint")
        }
        .couliCard()
        .meProbe("nickname.card", role: "card")
    }

    private func field(_ state: NicknameState, _ actions: NicknameActions, error: String?) -> some View {
        let counter = texts.format("nickname.counter", ["n": String(state.check.length)])
        return HStack(spacing: CouliSpacing.s2) {
            TextField(
                texts.text("nickname.label"),
                text: Binding(get: { state.input }, set: { actions.input($0) })
            )
            .couliFont(.body)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .focused($inputFocused)
            .accessibilityLabel(Text(verbatim: texts.text("nickname.label")))
            .accessibilityHint(Text(verbatim: error ?? ""))
            .accessibilityIdentifier("nickname.input")
            Text(verbatim: counter)
                .couliFont(.caption, monospacedDigits: true)
                .foregroundColor(state.check.length > NicknameInput.max ? CouliColor.statusErrorText
                    : CouliColor.textSecondary)
                .fixedSize()
                .couliTextNaturalProbe("nickname.counter", role: "text", text: counter, style: .caption)
                .accessibilityRepresentation { EmptyView() }
                // 只有文字变、框不变时测量桥读到的是上一帧的文字（F-IOS-63 同类）：换实例重报
                .id(counter)
            if state.input.isEmpty {
                // 没有清除按钮时计数离框右 12
                Color.clear.frame(width: CouliSpacing.s1)
            } else {
                clearButton(actions)
            }
        }
        .padding(.leading, CouliSpacing.s3)
        .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .strokeBorder(borderColor(error: error), lineWidth: borderWidth(error: error))
        )
        .meProbe("nickname.field", role: "field")
    }

    /// 普通 `border.control` 1、错误 `status.error.text` 2（错误优先）；输入中 `border.active` 2。
    private func borderColor(error: String?) -> Color {
        if error != nil {
            return CouliColor.statusErrorText
        }
        return inputFocused ? CouliColor.borderActive : CouliColor.borderControl
    }

    private func borderWidth(error: String?) -> CGFloat {
        error != nil || inputFocused ? CouliSpacing.s1 / 2 : CouliComponentMetric.controlBorderWidth
    }

    private func clearButton(_ actions: NicknameActions) -> some View {
        Button {
            actions.clear()
        } label: {
            CouliIconView(.close, size: CouliComponentMetric.iconInline, relativeTo: .footnote)
                .foregroundColor(CouliColor.textSecondary)
                .meProbe("nickname.clear.icon", role: "icon")
                .couliHitTarget()
                .meProbe("nickname.clear.hit", role: "hit")
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small, ringInside: true))
        .accessibilityLabel(Text(verbatim: texts.text("nickname.clear")))
        .accessibilityIdentifier("nickname.clear")
    }

    private func errorRow(_ error: String) -> some View {
        HStack(alignment: .top, spacing: CouliSpacing.s1) {
            CouliIconView(.alert, size: CouliComponentMetric.iconInline, relativeTo: .footnote)
                .foregroundColor(CouliColor.statusErrorText)
                .padding(.top, 1)
                .meProbe("nickname.error.icon", role: "icon")
                .accessibilityHidden(true)
            MeText(error, style: .footnote, probe: "nickname.error")
                .foregroundColor(CouliColor.statusErrorText)
                .accessibilityFocused($errorFocused)
                .accessibilityIdentifier("nickname.error")
        }
    }

    /// 底部固定白底栏：内边距 12 / 16，下方是安全区（没有安全区或键盘弹起时另留 12），底色铺到屏底。
    private func saveBar(_ state: NicknameState, _ actions: NicknameActions, safeBottom: CGFloat) -> some View {
        VStack(spacing: 0) {
            SettingsDivider(probe: "nickname.bar.line")
            CouliButton(
                texts.text("nickname.save"), isLoading: state.saving,
                isEnabled: state.check.saveEnabled && !state.saving && !gate.blocked, fillsWidth: true,
                labelProbeID: "nickname.save.label", action: actions.save
            )
            .meProbe("nickname.save.button", role: "button")
            .accessibilityIdentifier("nickname.save")
            .padding(.horizontal, CouliSpacing.s4)
            .meContentWidth()
            .padding(.top, CouliSpacing.s3)
            .padding(.bottom, inputFocused ? CouliSpacing.s3 : max(0, CouliSpacing.s3 - safeBottom))
        }
        .background(CouliColor.backgroundSurface)
        .meProbe("nickname.bar", role: "bar")
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

/// 通知设置（设计稿 NotifySettings、NotifySettingsOn、NotifySettingsNotAsked；G02）：系统通知已拒绝 → 警告条 perm.push.denied_forever +【去设置】；
/// iOS 从未申请（not_asked）→ 中性条、不给按钮（G-S14：系统设置里还没有本 App 的开关，【去设置】走不通）；「服务类推送」开关（Release 不显示开关行）
/// 与说明句。
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
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                systemBar(state, actions)
                serviceCard(state, actions)
                if let error = state.error {
                    MeNoticeBar(text: error.message(texts), noticeId: error.id, retryTitle: texts.text("me.retry"),
                                retryEnabled: !gate.blocked, retry: actions.retry, identifier: "notify.error")
                }
            }
            .padding(.top, CouliSpacing.s2)
            .padding([.horizontal, .bottom], CouliSpacing.s4)
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

    /// 系统状态三种画法：已开启、还没查到不画；not_asked 中性条；其余非 granted 警告条 + 去设置（只跳系统设置，不申请）。
    @ViewBuilder
    private func systemBar(_ state: NotifySettingsState, _ actions: NotifyActions) -> some View {
        if let status = state.systemStatus, status != PermissionStatusRaw.granted {
            if status == PermissionStatusRaw.notAsked {
                SettingsNoticeBar(
                    icon: .info, iconColor: CouliColor.textSecondary, background: CouliColor.backgroundMuted,
                    probe: "notify.neutral"
                ) {
                    MeText(texts.text("notify.not_asked"), style: .footnote, probe: "notify.neutral.text")
                        .foregroundColor(CouliColor.textPrimary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("notify.neutral")
            } else {
                SettingsNoticeBar(
                    icon: .alert, iconColor: CouliColor.statusWarningText,
                    background: CouliColor.statusWarningBackground, probe: "notify.bar"
                ) {
                    VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                        MeText(texts.text("perm.push.denied_forever"), style: .footnote, probe: "notify.bar.text")
                            .foregroundColor(CouliColor.statusWarningText)
                        SettingsTextLink(title: texts.text("perm.go_settings"), color: CouliColor.statusWarningText,
                                         probe: "notify.goSettings.link", hitProbe: "notify.goSettings.hit",
                                         action: actions.goSettings)
                            .accessibilityIdentifier("notify.goSettings")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("notify.bar")
            }
        }
    }

    /// 服务卡：内边距 12 / 16、纵向 4；开关一行、说明句通栏在下（S21）。Release（G02）不显示开关行，只留说明句。
    private func serviceCard(_ state: NotifySettingsState, _ actions: NotifyActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            if controller.hasSwitch, let service = state.service {
                MeSwitchRow(
                    title: texts.text("notify.service"), isOn: service,
                    enabled: !state.switching && !gate.blocked, texts: texts, identifier: "notify.switch",
                    style: .settings, probe: "notify.switch", controlProbe: "notify.switch.control",
                    onChange: actions.toggle
                )
            }
            Text(verbatim: texts.text("notify.service_desc"))
                .couliFont(.caption)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .couliTextNaturalProbe("notify.desc", role: "text", text: texts.text("notify.service_desc"),
                                       style: .caption)
                .accessibilityIdentifier("notify.desc")
        }
        .padding(.vertical, CouliSpacing.s3)
        .padding(.horizontal, CouliSpacing.s4)
        .couliCard(padding: 0)
        .meProbe("notify.card", role: "card")
    }
}
