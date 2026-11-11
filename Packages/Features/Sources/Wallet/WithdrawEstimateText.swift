import DesignSystem
import SwiftUI
import WalletCore

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
        // 金额段整段换行；金额独占一行也放不下时（D10-1265 ①）：前后文字照常折行、金额单独一行框内横滑（带截断提示）
        CouliWholeDigits(minimumWidth: digitsWidth) {
            body
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .couliTextProbe("withdraw.estimate", role: "text", text: line, fontSize: size,
                                baseFontSize: CouliTextStyle.footnote.baseSize, naturalWidth: naturalWidth)
                .couliTextProbe("withdraw.estimate.net", role: "amount", text: net, fontSize: amountSize,
                                baseFontSize: CouliTextStyle.body.baseSize)
        } overflow: {
            overflowLayout(plain: plain, strong: strong)
        }
        .accessibilityIdentifier("withdraw.estimate")
    }

    /// 金额独占一行仍放不下：前段 / 金额（单独一行横滑）/ 后段；读屏仍读整句一项。
    @ViewBuilder
    private func overflowLayout(plain: Font, strong: Font) -> some View {
        if line.contains(net) {
            VStack(alignment: .leading, spacing: 0) {
                if !parts.before.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(verbatim: parts.before.trimmingCharacters(in: .whitespaces)).font(plain)
                        .fixedSize(horizontal: false, vertical: true)
                }
                CouliDigitsScroller(probe: "withdraw.estimate.net") {
                    Text(verbatim: net).font(strong)
                        .couliTextProbe("withdraw.estimate.net", role: "amount", text: net, fontSize: amountSize,
                                        baseFontSize: CouliTextStyle.body.baseSize)
                }
                if !parts.after.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(verbatim: parts.after.trimmingCharacters(in: .whitespaces)).font(plain)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundColor(CouliColor.textPrimary)
            .couliTextProbe("withdraw.estimate", role: "text", text: line, fontSize: size,
                            baseFontSize: CouliTextStyle.footnote.baseSize, naturalWidth: naturalWidth)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: line))
        } else {
            CouliDigitsScroller(probe: "withdraw.estimate.net") {
                Text(verbatim: line).font(plain)
                    .foregroundColor(CouliColor.textPrimary)
                    .couliTextProbe("withdraw.estimate", role: "text", text: line, fontSize: size,
                                    baseFontSize: CouliTextStyle.footnote.baseSize, naturalWidth: naturalWidth)
            }
        }
    }

    /// 句中最宽的数字段（到账金额按 17/600，其余按 14）。
    private var digitsWidth: CGFloat {
        max(CouliDigitRuns.widest(line.contains(net) ? net : "", size: amountSize, weight: .semibold),
            CouliDigitRuns.widest(parts.before, size: size), CouliDigitRuns.widest(parts.after, size: size))
    }
}
