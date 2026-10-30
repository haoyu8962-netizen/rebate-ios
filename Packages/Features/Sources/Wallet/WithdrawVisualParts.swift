import DesignSystem
import SwiftUI
import WalletCore

// 提现页（APP-09v-c，画板 Withdraw 一族）页面私有的小件：金额框、快捷档位、估算句、链接按钮、收款账号行、转圈、错误图标。
// 这里只管外观与测量；回调全部由调用方传入渲染时的值，不读可观察状态、不判断能不能提交（共性第 4、59、63、64 条）。

/// 提交被拒的错误显示在哪里（G-W13）：只按错误键挪位，不改 `SensitiveOutcome` 的分类与结局。
enum WithdrawErrorPlacement {
    private static let amountKeys: Set<String> = [
        "error.30301", "error.30303.below_min", "error.30303.not_multiple", "error.30303.above_max",
        "error.30303.above_method_max", "error.30303.net_too_small",
    ]

    /// 金额类错误在金额框下；白名单外仍在页顶。
    static func belowAmountBox(_ key: String) -> Bool {
        amountKeys.contains(key)
    }
}

/// 金额框（W38、W54）：视觉 56、「¥」17 次文字 + 输入 28/600 等宽。`muted`（待确认、提交中）灰底浅边；其余白底控件边
/// （WithdrawRealName 未实名时框也是白底，靠占位句说明）；有错误红边。
/// 文本绑定由调用方给（同一份 `WithdrawActions.amount`）；`placeholder` 只在未实名不可输入时给。外观不决定能否输入，能否输入只看 `editable`。
/// 输入框可折行：放不下时金额换行，聚焦与未聚焦都看得到完整金额（验收 6；单行框放不下时聚焦会裁掉开头）。框不随字号设最小宽，否则会把窄屏整页撑出屏幕。
struct WithdrawAmountBox: View {
    private let text: Binding<String>
    private let placeholder: String?
    private let label: String
    private let editable: Bool
    private let muted: Bool
    private let hasError: Bool
    @ScaledMetric private var inputSize: CGFloat
    /// 放不下时【全部提现】换到框下：判据只看字号、不看内容，输入过程中不会换版式（换版式会让输入框重建、键盘收起）。
    @ScaledMetric private var idealWidth: CGFloat
    /// 框内文字：过滤拒绝时金额没变、输入框不会自己退回去（实测框里留着被拒的字），所以框内文字单独记，每次输入后对回金额（`syncKey`）。
    @State private var shown: String
    @State private var edits = 0

    init(text: Binding<String>, placeholder: String?, label: String, editable: Bool, muted: Bool, hasError: Bool) {
        self.text = text
        _shown = State(initialValue: text.wrappedValue)
        self.placeholder = placeholder
        self.label = label
        self.editable = editable
        self.muted = muted
        self.hasError = hasError
        _inputSize = ScaledMetric(wrappedValue: CouliTextStyle.heading.baseSize,
                                  relativeTo: CouliTextStyle.heading.relativeTo)
        _idealWidth = ScaledMetric(wrappedValue: 160, relativeTo: CouliTextStyle.heading.relativeTo)
    }

    /// 同一条金额过滤：只把换行还原成单行框的写法（空白），接不接受仍由 `WithdrawActions.amount` 决定。
    private var input: Binding<String> {
        Binding(
            get: { shown },
            set: { value in
                shown = value
                text.wrappedValue = Self.singleLine(value)
                edits &+= 1
            }
        )
    }

    /// 金额变了（档位、【全部提现】、输入）或刚输入过（可能被拒）就对一次。
    private var syncKey: String {
        "\(edits)|\(text.wrappedValue)"
    }

    /// 可折行输入框的回车、粘贴会带换行；单行框里它们是空白。
    static func singleLine(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
    }

    private var border: Color {
        if hasError {
            return CouliColor.statusErrorText
        }
        return muted ? CouliColor.borderSubtle : CouliColor.borderControl
    }

    var body: some View {
        HStack(spacing: CouliSpacing.s2) {
            RecordText(PriceTerms.yuanSign, style: .body, color: CouliColor.textSecondary, singleLine: true,
                       probe: "withdraw.amount.sign")
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                if let placeholder, text.wrappedValue.isEmpty {
                    RecordText(placeholder, style: .body, color: CouliColor.textSecondary)
                        .accessibilityHidden(true)
                }
                TextField("", text: input, axis: .vertical)
                    .lineLimit(1...)
                    .keyboardType(.decimalPad)
                    .font(Font.system(size: inputSize, weight: .couliSemibold).monospacedDigit())
                    .foregroundColor(CouliColor.textPrimary)
                    .disabled(!editable)
                    .accessibilityLabel(Text(verbatim: label))
                    .accessibilityIdentifier("withdraw.input")
                    .couliTextProbe("withdraw.amount.input", role: "input", text: text.wrappedValue,
                                    fontSize: inputSize, baseFontSize: CouliTextStyle.heading.baseSize)
                    .task(id: syncKey) { shown = text.wrappedValue }
            }
        }
        .padding(.horizontal, CouliSpacing.s3)
        .padding(.vertical, CouliSpacing.s2)
        .frame(idealWidth: idealWidth, maxWidth: .infinity, minHeight: CouliHitTarget.minimum + CouliSpacing.s3)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .fill(muted ? CouliColor.backgroundMuted : CouliColor.backgroundSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .strokeBorder(border, lineWidth: CouliComponentMetric.controlBorderWidth)
        )
        .walletProbe("withdraw.amount.box", role: "field")
    }
}

/// 文字链接按钮：字（测量 `.label`）的框就是视觉（`probe`），命中区 ≥ 44 且按布局占位、不与邻控件重叠（`.hit`）。
/// 【全部提现】（W39）、「提现规则」（W53）、「查看提现记录 ›」（W57）。
struct WithdrawLinkButton: View {
    let title: String
    let probe: String
    var weight = Font.Weight.couliMedium
    var inset = CouliSpacing.s2
    var chevron = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        let ink = isEnabled ? CouliColor.textLink : CouliColor.textSecondary
        Button(action: action) {
            HStack(spacing: CouliSpacing.s1) {
                RecordText(title, style: .footnote, weight: weight, color: ink, probe: probe + ".label")
                if chevron {
                    CouliIconView(.chevron, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                        .foregroundColor(ink)
                }
            }
            .walletProbe(probe, role: "link")
            .padding(.horizontal, inset)
            .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
            .contentShape(Rectangle())
            .walletProbe(probe + ".hit", role: "hit")
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
        .disabled(!isEnabled)
        .accessibilityLabel(Text(verbatim: title))
    }
}

/// 快捷档位胶囊（W41）：视觉 32、全圆角、浅边、14 等宽；命中 ≥ 44 按布局占位，视觉不被撑高；只填金额，不带选中语义。
struct WithdrawQuickChip: View {
    let fen: Int64
    let spoken: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        let probe = "withdraw.quick.\(fen)"
        Button(action: action) {
            RecordText(WalletMoney.text(fen), style: .footnote,
                       color: isEnabled ? CouliColor.textPrimary : CouliColor.textSecondary,
                       monospacedDigits: true, singleLine: true, probe: probe + ".label")
                .padding(.horizontal, CouliSpacing.s4)
                .frame(minHeight: WithdrawMetric.chipHeight)
                .background(Capsule().fill(isEnabled ? CouliColor.backgroundSurface : CouliColor.backgroundMuted))
                .overlay(
                    Capsule().strokeBorder(CouliColor.borderSubtle, lineWidth: CouliComponentMetric.controlBorderWidth)
                )
                .walletProbe(probe, role: "chip")
                .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
                .contentShape(Rectangle())
                .walletProbe(probe + ".hit", role: "hit")
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
        .disabled(!isEnabled)
        .accessibilityLabel(Text(verbatim: spoken))
        .accessibilityIdentifier(probe)
    }
}

enum WithdrawMetric {
    static let chipHeight: CGFloat = 32
    static let spinner: CGFloat = 16
    static let estimateRowMinHeight: CGFloat = 25.5
}

/// 估算句（W42）：14 字里到账金额片段 17/600，整句一个文字节点（读屏读完整句）。金额只取服务端字段，这里只找位置、不计算。
struct WithdrawEstimateText: View {
    let line: String
    let net: String
    @ScaledMetric private var size: CGFloat
    @ScaledMetric private var amountSize: CGFloat

    init(line: String, net: String) {
        self.line = line
        self.net = net
        _size = ScaledMetric(wrappedValue: CouliTextStyle.footnote.baseSize,
                             relativeTo: CouliTextStyle.footnote.relativeTo)
        _amountSize = ScaledMetric(wrappedValue: CouliTextStyle.body.baseSize,
                                   relativeTo: CouliTextStyle.body.relativeTo)
    }

    private var parts: (before: String, after: String) {
        guard let range = line.range(of: net) else { return (line, "") }
        return (String(line[..<range.lowerBound]), String(line[range.upperBound...]))
    }

    private var naturalWidth: CGFloat {
        RecordMeasure.width(parts.before, size: size, weight: .regular, monospacedDigits: true)
            + RecordMeasure.width(line.contains(net) ? net : "", size: amountSize, weight: .couliSemibold,
                                  monospacedDigits: true)
            + RecordMeasure.width(parts.after, size: size, weight: .regular, monospacedDigits: true)
    }

    var body: some View {
        let plain = Font.system(size: size).monospacedDigit()
        let strong = Font.system(size: amountSize, weight: .couliSemibold).monospacedDigit()
        let body = Text(verbatim: parts.before).font(plain)
            + Text(verbatim: line.contains(net) ? net : "").font(strong)
            + Text(verbatim: parts.after).font(plain)
        body
            .foregroundColor(CouliColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .couliTextProbe("withdraw.estimate", role: "text", text: line, fontSize: size,
                            baseFontSize: CouliTextStyle.footnote.baseSize, naturalWidth: naturalWidth)
            .couliTextProbe("withdraw.estimate.net", role: "amount", text: net, fontSize: amountSize,
                            baseFontSize: CouliTextStyle.body.baseSize)
            .accessibilityIdentifier("withdraw.estimate")
    }
}

/// 收款账号行（W51）：白卡、左标签、账号靠右 + 20 ›；读屏一项「标签，账号」。
struct WithdrawPayoutRow: View {
    let label: String
    let value: String
    let spoken: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: CouliSpacing.s1) {
                CouliFlowLayout(horizontalSpacing: CouliSpacing.s3, verticalSpacing: CouliSpacing.s1) {
                    RecordText(label, style: .footnote, color: CouliColor.textSecondary, probe: "withdraw.payout.label")
                    RecordText(value, style: .footnote, color: CouliColor.textPrimary, monospacedDigits: true,
                               probe: "withdraw.payout.value")
                        .couliFlowPushTrailing(.inlineOnly)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: label + PriceTerms.spokenPause + spoken))
                CouliIconView(.chevron, size: CouliGuideMetric.iconMedium, relativeTo: .footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .walletProbe("withdraw.payout.chevron", role: "icon")
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum, alignment: .leading)
            .padding(.vertical, CouliSpacing.s1)
            .padding(.horizontal, CouliSpacing.s4)
            .contentShape(Rectangle())
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.card))
        .couliCard(padding: 0)
        .walletProbe("withdraw.payout", role: "row")
        .accessibilityIdentifier("withdraw.payout")
    }
}

/// 16 转圈（W43 计算中、W58 待确认忙碌）。
struct WalletSpinner: View {
    let probe: String

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            .scaleEffect(WithdrawMetric.spinner / 20)
            .frame(width: WithdrawMetric.spinner, height: WithdrawMetric.spinner)
            .walletProbe(probe, role: "spinner")
            .accessibilityHidden(true)
    }
}

/// 字段错误的 16 三角（W50 / W82，提现页与收款账号页同一件）。
struct WalletErrorIcon: View {
    let probe: String

    var body: some View {
        CouliIconView(.alert, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
            .foregroundColor(CouliColor.statusErrorText)
            .walletProbe(probe, role: "icon")
            .padding(.top, 2)
            .accessibilityHidden(true)
    }
}

/// 待确认卡与引导框共用的警告提示块（W46、W56、W59）：圆角 12、内边距 12、20 图标 + 警告字色。
struct WalletWarningBlock<Content: View>: View {
    let iconProbe: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: CouliSpacing.s2) {
            CouliIconView(.alert, size: CouliGuideMetric.iconMedium, relativeTo: .footnote)
                .walletProbe(iconProbe, role: "icon")
                .accessibilityHidden(true)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundColor(CouliColor.statusWarningText)
        .padding(CouliSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .fill(CouliColor.statusWarningBackground)
        )
    }
}
