import DesignSystem
import SwiftUI
import WalletCore

// 收款账号 / 实名 / 劳务协议（APP-09v-e）共用的小件。只管外观与测量；回调全部由调用方传入渲染时的值，不判断能不能保存（共性第 4、59、63 条）。

/// 收款账号保存被拒的错误显示在哪里、什么语气（G-W13、G-W22）：只按错误键挪位换色，不改 `SensitiveOutcome` 的分类与结局。
enum PayoutErrorPlacement {
    /// 该错误挂在哪个字段下；白名单外返回 nil，仍在页顶。
    static func field(_ key: String, method: String) -> String? {
        switch key {
        case "error.30307": PayoutAccountForm.payeeName
        case "error.30308": method == WalletJSON.bankCard ? PayoutAccountForm.cardNo : PayoutAccountForm.alipayLogonId
        default: nil
        }
    }

    static func tone(_ key: String) -> NoticeTone {
        if key.hasPrefix("error.30303.payout_account_") {
            return .warning
        }
        return key == "error.40901" ? .neutral : .error
    }
}

/// 表单输入框（W72 / W90）：视觉 48、圆角 12、字 17。敏感输入不进测量（只报框）。
///
/// 框内文字单独记：`Binding(get:set:)` 的 `set` 被过滤拒绝时绑定值没变，SwiftUI 不写回，被拒的字留在框里（显示与提交不一致）。
/// 每次输入后把框内文字对回**当前值**（`current` 读执行器，不读渲染快照：c 组评审 S2-1 的竞态）。写入仍只走调用方给的 `set`。
struct WalletInputField: View {
    let placeholder: String
    let label: String
    let identifier: String
    let probe: String
    let value: String
    let current: () -> String
    var keyboard = UIKeyboardType.default
    var capitalization = TextInputAutocapitalization.never
    let hasError: Bool
    let hint: String
    let set: (String) -> Void
    /// 获得焦点、键盘落定后调用（滚到可见处）。
    let reveal: () -> Void
    @State private var shown: String
    @State private var edits = 0
    @FocusState private var focused: Bool

    /// 等键盘升起动画结束，可视区才是最终高度。
    private static let keyboardSettleNanos: UInt64 = 350_000_000

    init(placeholder: String, label: String, identifier: String, probe: String, value: String,
         current: @escaping () -> String, keyboard: UIKeyboardType = .default,
         capitalization: TextInputAutocapitalization = .never, hasError: Bool, hint: String,
         set: @escaping (String) -> Void, reveal: @escaping () -> Void) {
        self.placeholder = placeholder
        self.label = label
        self.identifier = identifier
        self.probe = probe
        self.value = value
        self.current = current
        self.keyboard = keyboard
        self.capitalization = capitalization
        self.hasError = hasError
        self.hint = hint
        self.set = set
        self.reveal = reveal
        _shown = State(initialValue: value)
    }

    private var input: Binding<String> {
        Binding(
            get: { shown },
            set: { text in
                shown = text
                set(text)
                edits &+= 1
            }
        )
    }

    /// 值变了或刚输入过（可能被拒）就对一次。只在内存里当任务编号，不外传。
    private var syncKey: String {
        "\(edits)|\(value)"
    }

    var body: some View {
        // 占位句按稿用次文字色（系统缺省太浅，W72）
        TextField("", text: input, prompt: Text(verbatim: placeholder).foregroundColor(CouliColor.textSecondary))
            .keyboardType(keyboard)
            .textInputAutocapitalization(capitalization)
            .focused($focused)
            .couliFont(.body)
            .padding(.horizontal, CouliSpacing.s3)
            .padding(.vertical, CouliSpacing.s2)
            .frame(maxWidth: .infinity, minHeight: WalletFieldMetric.boxHeight)
            .background(
                // 框内边距也算输入框（点在字之外同样获得焦点）；手势放在底板上，不盖住输入框自己的长按菜单
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .fill(CouliColor.backgroundSurface)
                    .onTapGesture { focused = true }
            )
            .overlay(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .strokeBorder(hasError ? CouliColor.statusErrorText : CouliColor.borderControl,
                                  lineWidth: CouliComponentMetric.controlBorderWidth)
                    .allowsHitTesting(false)
            )
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityHint(Text(verbatim: hint))
            .accessibilityIdentifier(identifier)
            .walletProbe(probe, role: "field")
            .task(id: syncKey) {
                let now = current()
                if shown != now {
                    shown = now
                }
            }
            .task(id: focused) {
                guard focused else { return }
                try? await Task.sleep(nanoseconds: Self.keyboardSettleNanos)
                if !Task.isCancelled {
                    reveal()
                }
            }
    }
}

enum WalletFieldMetric {
    static let boxHeight: CGFloat = 48
    static let gap = CouliSpacing.s2
    static let fieldGap = CouliSpacing.s4
    /// 焦点输入框的滚动目标。
    static func anchor(_ name: String) -> String {
        "wallet.input.\(name)"
    }
}

/// 字段标签（W72）：14 次文字。
struct WalletFieldLabel: View {
    let text: String
    let probe: String

    var body: some View {
        RecordText(text, style: .footnote, color: CouliColor.textSecondary, probe: probe)
    }
}

/// 卡外 INFO 条（W74 / W77 / W91）：`background.muted`、圆角 12、内边距 12、20 次文字色图标 + 14 主文字，读屏一项。
struct WalletInfoStrip: View {
    let text: String
    var icon = CouliIcon.info
    let probe: String

    var body: some View {
        HStack(alignment: .top, spacing: CouliSpacing.s2) {
            CouliIconView(icon, size: CouliGuideMetric.iconMedium, relativeTo: .footnote)
                .foregroundColor(CouliColor.textSecondary)
                .walletProbe(probe + ".icon", role: "icon")
                .accessibilityHidden(true)
            RecordText(text, style: .footnote, color: CouliColor.textPrimary, probe: probe + ".text")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CouliSpacing.s3)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous).fill(CouliColor.backgroundMuted)
        )
        .walletProbe(probe, role: "notice")
        .accessibilityElement(children: .combine)
    }
}

/// 单选圈（W71）：外径 24；选中 7 品牌描边 + 白心；未选 1 控件边。读屏由按钮的 isSelected 表达。
struct RadioMark: View {
    let selected: Bool
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 24

    var body: some View {
        Circle()
            .fill(CouliColor.backgroundSurface)
            .overlay(
                Circle().strokeBorder(selected ? CouliColor.brandPrimary : CouliColor.borderControl,
                                      lineWidth: selected ? size * 7 / 24 : CouliComponentMetric.controlBorderWidth)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 勾选行（W94 / W100）：圆 18 + 14 主文字；视觉行不被命中区撑高，命中 ≥ 44 按布局占位。读屏为勾选框（已选 / 未选），`spoken` 给时读它（劳务带版本号）。
struct CheckRow: View {
    let title: String
    var spoken: String?
    let checked: Bool
    let action: () -> Void
    let identifier: String
    let probe: String

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: CouliSpacing.s3) {
                CheckMark(checked: checked)
                    .walletProbe(probe + ".mark", role: "check")
                    .padding(.top, 1.5)
                RecordText(title, style: .footnote, color: CouliColor.textPrimary, probe: probe + ".text")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .walletProbe(probe, role: "row")
            .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum)
            .contentShape(Rectangle())
            .walletProbe(probe + ".hit", role: "hit")
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
        .accessibilityLabel(Text(verbatim: spoken ?? title))
        .accessibilityAddTraits(checked ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// 圆形勾选（设计稿 RealNameConsent-v2 / LaborAgreement-v2：未勾 1.5 控件边空心圆，勾选品牌色实心 + 白勾）。
struct CheckMark: View {
    let checked: Bool
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().fill(checked ? CouliColor.brandPrimary : CouliColor.backgroundSurface)
            Circle().strokeBorder(checked ? CouliColor.brandPrimary : CouliColor.borderControl, lineWidth: 1.5)
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
