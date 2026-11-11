import DesignSystem
import SwiftUI

/// 一个 BindPhone 导航实例（App 按 RouteDestination.id 建一份）：持有当前的页面执行器；会话换代时在同步出口作废旧执行器、按新身份重建
/// （APP-13a 共性第 6、36 条），出栈时作废。
@MainActor
public final class BindPhoneEntry: ObservableObject {
    public let id: UUID
    @Published public private(set) var controller: BindPhoneController
    private let make: (UUID) -> BindPhoneController

    public init(id: UUID, make: @escaping (UUID) -> BindPhoneController) {
        self.id = id
        self.make = make
        controller = make(id)
    }

    /// 会话 / 作用域 / 隐私 / 环境换代：旧实例作废（清空输入、倒计时、弹窗），换上按新身份建的实例。
    public func rebuild() {
        let wasVisible = controller.visible
        controller.invalidate()
        controller = make(id)
        if wasVisible {
            controller.appeared()
        }
    }

    /// 出栈（同步出口）。
    public func left() {
        controller.invalidate()
    }
}

/// 绑手机页（BindPhone / BindPhoneMerge 画板，含待确认卡 G07）。读屏顺序：返回 → 标题 → 说明 → 手机号 → 清除 → 验证码 → 获取验证码 →
/// 绑定；进入时焦点在标题。键盘弹起时底部【绑定】随键盘上移（safeAreaInset，共性第 7 条），内容区可滚动。
public struct BindPhoneScreen: View {
    @ObservedObject var entry: BindPhoneEntry
    let texts: LoginTexts

    public init(entry: BindPhoneEntry, texts: LoginTexts) {
        self.entry = entry
        self.texts = texts
    }

    public var body: some View {
        BindPhoneView(controller: entry.controller, texts: texts)
            .id(ObjectIdentifier(entry.controller))
    }
}

struct BindPhoneView: View {
    enum Field: Hashable {
        case phone
        case code
        case phoneError
        case codeError
        case title
    }

    @ObservedObject var controller: BindPhoneController
    let texts: LoginTexts
    @FocusState var focus: Field?
    @AccessibilityFocusState var a11y: Field?

    func text(_ key: String) -> String {
        texts.text(key)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: CouliSpacing.s3) {
                    infoBar
                    if let card = controller.pending {
                        BindPendingCardView(card: card, controller: controller, texts: texts)
                    }
                    formCard
                    if let notice = controller.notice {
                        Text(verbatim: notice.text)
                            .couliFont(.footnote)
                            .foregroundColor(CouliColor.statusErrorText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("bindPhone.notice")
                    }
                }
                .padding(.horizontal, CouliSpacing.s4)
                .padding(.top, CouliSpacing.s2)
                .padding(.bottom, CouliSpacing.s4)
                .frame(maxWidth: LoginView.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .couliDialog(isPresented: controller.dialog != nil) {
            dialog
        }
        .couliToast($controller.toast)
        .onAppear {
            controller.appeared()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                a11y = .title
            }
        }
        .onDisappear {
            controller.disappeared()
        }
        .onChange(of: controller.fieldEvent) { event in
            // 用回调给的新值（APP-12 共性第 38 条）：焦点移到对应字段的错误提示
            guard let event else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                a11y = event.field == "code" ? .codeError : .phoneError
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bindPhone.page")
    }

    // MARK: - 顶栏

    private var topBar: some View {
        ZStack {
            Text(verbatim: text(BindPhoneKeys.title))
                .couliFont(.body, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CouliHitTarget.minimum + CouliSpacing.s2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($a11y, equals: .title)
                .accessibilityIdentifier("bindPhone.title")
            HStack {
                Button(action: controller.back) {
                    CouliIconView(.back)
                        .foregroundColor(CouliColor.textPrimary)
                        .couliHitTarget()
                }
                .buttonStyle(CouliPlainButtonStyle())
                .accessibilityLabel(Text(verbatim: text(LoginKeys.back)))
                .accessibilityIdentifier("bindPhone.back")
                Spacer()
            }
        }
        .padding(.horizontal, CouliSpacing.s1)
        .frame(minHeight: CouliHitTarget.minimum)
        .loginTopBarChrome()
    }

    private var infoBar: some View {
        HStack(alignment: .top, spacing: CouliSpacing.s2) {
            CouliIconView(.info, size: CouliComponentMetric.iconMedium)
                .foregroundColor(CouliColor.textSecondary)
            Text(verbatim: text(BindPhoneKeys.info))
                .couliFont(.body)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CouliSpacing.s3)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous).fill(CouliColor.backgroundMuted)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bindPhone.info")
    }

    private var bottomBar: some View {
        CouliButton(
            text(BindPhoneKeys.submit),
            isLoading: controller.submitting || controller.pendingBusy,
            isEnabled: controller.canSubmit,
            fillsWidth: true,
            action: {
                focus = nil
                controller.submit()
            }
        )
        .accessibilityIdentifier("bindPhone.submit")
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.top, CouliSpacing.s3)
        .padding(.bottom, CouliSpacing.s3)
        .frame(maxWidth: LoginView.maxContentWidth)
        .frame(maxWidth: .infinity)
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
    }

    // MARK: - 弹窗

    private var dialog: CouliDialog {
        switch controller.dialog {
        case let .merge(_, phone, id):
            CouliDialog(
                title: text(BindPhoneKeys.mergeTitle),
                centeredTitle: true,
                primary: CouliDialogAction(text(BindPhoneKeys.mergeOK)) { controller.confirmMerge(dialogId: id) },
                secondary: CouliDialogAction(text(BindPhoneKeys.mergeCancel)) { controller.cancelMerge(dialogId: id) }
            ) {
                BindMergeBody(message: controller.mergeBody(), into: text(BindPhoneKeys.mergeInto),
                              account: texts.format(BindPhoneKeys.mergeAccount, ["phone": phone]))
            }
        case let .risk(titleKey, id):
            CouliDialog(
                title: text(titleKey),
                primary: CouliDialogAction(text(BindPhoneKeys.riskOK)) { controller.dismissDialog(dialogId: id) },
                secondary: CouliDialogAction(text(BindPhoneKeys.appeal)) { controller.appeal(dialogId: id) }
            )
        case let .abandon(_, id):
            CouliDialog(
                title: text(BindPhoneKeys.pendingAbandon),
                message: text(BindPhoneKeys.pendingAbandonConfirm),
                primary: CouliDialogAction(text(BindPhoneKeys.pendingAbandonOK)) {
                    controller.confirmAbandon(dialogId: id)
                },
                secondary: CouliDialogAction(text(BindPhoneKeys.pendingAbandonCancel)) {
                    controller.dismissDialog(dialogId: id)
                }
            )
        case .none:
            CouliDialog(title: "", primary: CouliDialogAction("") {})
        }
    }
}
