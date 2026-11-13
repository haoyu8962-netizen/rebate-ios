import DesignSystem
import Generated
import OrderCore
import SwiftUI
import UIKit

// APP-08v-a 订单列表的小部件（brief §2.1–§2.3）：带测量的文字、状态胶囊、单号 +【复制】排法、两列金额格。
// 测量只在有接收方（Debug 测试宿主）时上报，Release 没有接收方、不多画任何视图。

/// 令牌文字 + 测量（实际字号随系统字号缩放，与 `couliFont` 同一缩放曲线）。`probeID` 为 nil 时不量。
struct OrderProbedText: View {
    let text: String
    let style: CouliTextStyle
    var weight: Font.Weight = .regular
    var monospacedDigits = false
    var probeID: String?
    @ScaledMetric private var size: CGFloat

    init(_ text: String, style: CouliTextStyle, weight: Font.Weight = .regular, monospacedDigits: Bool = false,
         probeID: String? = nil) {
        self.text = text
        self.style = style
        self.weight = weight
        self.monospacedDigits = monospacedDigits
        self.probeID = probeID
        _size = ScaledMetric(wrappedValue: style.baseSize, relativeTo: style.relativeTo)
    }

    var body: some View {
        let label = Text(verbatim: text).couliFont(style, weight: weight, monospacedDigits: monospacedDigits)
        if let probeID {
            label.couliTextProbe(probeID, role: "text", text: text, fontSize: size, baseFontSize: style.baseSize)
        } else {
            label
        }
    }
}

extension View {
    /// 可选编号的测量（nil 不量）。
    @ViewBuilder
    func orderProbe(_ id: String?, role: String = "box") -> some View {
        if let id {
            couliProbe(id, role: role)
        } else {
            self
        }
    }
}

// MARK: - 状态胶囊

/// 状态胶囊的图标（纯视图映射，brief §2.2）：预估类钟表；INVALID / NO_REBATE / 未知用 i；CLAWED_BACK 警告三角；已结算圆圈对勾。
enum OrderStatusIcon {
    static func icon(_ status: DisplayStatus) -> CouliIcon {
        switch status {
        case .credited, .creditedPartClawed: .check
        case .clawedBack: .alert
        case .invalid, .noRebate, .unknown: .info
        default: .clock
        }
    }

    /// 已结算（CREDITED / CREDITED_PART_CLAWED）用松叶绿成功色，其余中性。
    static func settled(_ status: DisplayStatus) -> Bool {
        status == .credited || status == .creditedPartClawed
    }
}

/// 列表卡的状态胶囊：高 22（最小高，随字号增高）、左右 8、圆角满、12 字 + 14 图标；中性次要底 + 次文字，已结算成功底 + 成功字。
struct OrderStatusPill: View {
    let summary: OrderSummary
    let texts: OrderTexts
    let hidden: Bool
    let probe: String

    var body: some View {
        let status = summary.displayStatus
        let settled = OrderStatusIcon.settled(status)
        HStack(alignment: .center, spacing: CouliSpacing.s1) {
            CouliIconView(OrderStatusIcon.icon(status), size: CouliComponentMetric.iconSmall, relativeTo: .caption)
                .couliProbe(probe + ".icon", role: "icon")
            OrderProbedText(OrderStatusLine.label(summary, texts: texts, hidden: hidden), style: .caption,
                            probeID: probe + ".label")
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(settled ? CouliColor.statusSuccessText : CouliColor.textSecondary)
        .padding(.horizontal, CouliSpacing.s2)
        .frame(minHeight: CouliComponentMetric.tagMinHeight)
        .background(Capsule().fill(settled ? CouliColor.statusSuccessBackground : CouliColor.backgroundMuted))
        .couliProbe(probe, role: "pill")
    }
}

// MARK: - 单号 +【复制】

/// 列表卡右列的「订单号 {no}」+【复制】（brief §2.2）：单号 12 次文字等宽数字；自购单【复制】12 强调色紧随、命中区 44（不撑高行）；
/// 分享单只显示脱敏原样、没有【复制】。整卡读屏另由卡片给出，这里的文字不单独进读屏；【复制】是独立的第二个目标。
/// 单号任何字号、宽度都不在中间断（D10-1230 判据 1）：按顺序取第一种放得下的排法——
/// ① 一行「订单号 单号【复制】」；② 「订单号 单号」一行、【复制】换到下一行；③ 「订单号」/ 单号 / 【复制】各一行；
/// ④ 单号整段也放不下：「订单号 单号」一行在框内横向滚动（末端渐隐 + 滚动指示器，D10-1265）、【复制】在下一行。【复制】离开单号那一行时带描边（D10-1223 按钮口径）。
/// 测量：`.number` = 「订单号 + 单号」的实际排版框（横滑时是滚动内容里的文字框），`.copy.label` = 【复制】字，`.copy` = 命中区。
struct OrderListNumber: View {
    let summary: OrderSummary
    let texts: OrderTexts
    let probe: String
    let onCopy: (String) -> Void
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = CouliTextStyle.caption.baseSize

    var body: some View {
        let number = OrderNumberDisplay.view(summary)
        if let raw = number.text {
            let text = texts.format(OrderKeys.orderNo, ["no": raw])
            let range = text.range(of: raw)
            let prefix = range.map { String(text[..<$0.lowerBound]) } ?? ""
            let rest = range.map { String(text[$0.lowerBound...]) } ?? text
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: CouliSpacing.s2) {
                    line(text).probedNumber(probe, text: text, size: size)
                    if number.copyable {
                        copyInline(raw)
                    }
                }
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    line(text).probedNumber(probe, text: text, size: size)
                    if number.copyable {
                        copyBoxed(raw)
                    }
                }
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    // 两行按令牌行高（12 → 18）排，同多行正文
                    VStack(alignment: .leading, spacing: 0) {
                        line(prefix.trimmingCharacters(in: .whitespaces)).couliLineBox(.caption)
                        line(rest).couliLineBox(.caption)
                    }
                    .probedNumber(probe, text: text, size: size)
                    if number.copyable {
                        copyBoxed(raw)
                    }
                }
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    CouliDigitsScroller(probe: probe + ".number") {
                        line(text).probedNumber(probe, text: text, size: size)
                    }
                    // 单号由整卡一项读出；横滑条本身不进读屏（否则多出一个空名称的停留点，NUM-WRAP r2 S2-1）
                    .accessibilityHidden(true)
                    if number.copyable {
                        copyBoxed(raw)
                    }
                }
            }
            .foregroundColor(CouliColor.textSecondary)
        }
    }

    /// 一行不折的文字（单号整段）。
    private func line(_ value: String) -> some View {
        Text(verbatim: value).couliFont(.caption, monospacedDigits: true)
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
    }

    private func copyLabel() -> some View {
        OrderProbedText(texts.text(OrderKeys.copy), style: .caption, probeID: probe + ".copy.label")
            .foregroundColor(CouliColor.brandEmphasis)
            .fixedSize()
            .accessibilityHidden(true)
    }

    /// 紧跟单号的【复制】：视觉是字，命中区 44 居中盖住字、不参与行高。
    private func copyInline(_ raw: String) -> some View {
        copyLabel()
            .overlay { copyButton(raw) }
    }

    /// 换到下一行的【复制】：描边按钮（D10-1223），命中区 = 按钮框（≥ 44）。
    private func copyBoxed(_ raw: String) -> some View {
        Button {
            onCopy(raw)
        } label: {
            copyLabel()
                .couliTextButtonOutline(true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .couliProbe(probe + ".copy", role: "hit")
        .accessibilityLabel(Text(verbatim: copySpoken(raw)))
        .accessibilityIdentifier("order.copy")
    }

    /// 【复制】读「复制订单号 {本行完整单号}」（FU-IOS-A11Y-05，D10-1248 ⑨：列表与详情同读完整单号，同屏各行能区分）。
    private func copySpoken(_ raw: String) -> String {
        texts.format(OrderKeys.copySpoken, ["no": raw])
    }

    private func copyButton(_ raw: String) -> some View {
        Button {
            onCopy(raw)
        } label: {
            Color.clear
                .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .couliProbe(probe + ".copy", role: "hit")
        .accessibilityLabel(Text(verbatim: copySpoken(raw)))
        .accessibilityIdentifier("order.copy")
    }
}

private extension View {
    /// 单号测量：框 = 「订单号 + 单号」的实际排版框。
    func probedNumber(_ probe: String, text: String, size: CGFloat) -> some View {
        couliTextProbe(probe + ".number", role: "text", text: text, fontSize: size,
                       baseFontSize: CouliTextStyle.caption.baseSize)
    }
}
