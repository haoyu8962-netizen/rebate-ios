import DesignSystem
import SwiftUI

/// 价格区间半屏（设计稿 SearchFilterPrice）：最低价 – 最高价、按券后价筛选，单位元、【重置】【确定】。
/// 输入按元、最多两位小数，转整数分时不经浮点（SearchPriceInput）；不合法（0、超过上限、最低高于最高；BR-PRICE-15）
/// 在面板内提示，不发请求。
struct SearchPriceSheet: View {
    let texts: SearchTexts
    /// 草稿放在页面配置里（共性 17：界面重建后不丢）。
    @Binding var minText: String
    @Binding var maxText: String
    let onClose: () -> Void
    /// 返回 false = 执行器拒绝（不合法或限流中），面板保留。
    let onApply: (Int64?, Int64?) -> Bool
    @State private var invalid = false

    var body: some View {
        CouliSheet(
            title: texts.text(SearchKeys.filterPrice),
            closeLabel: texts.text(SearchKeys.sheetClose),
            onClose: onClose
        ) {
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s2) {
                field(texts.text(SearchKeys.sheetMin), text: $minText, id: "search.price.min")
                Text(verbatim: "\u{2013}")
                    .couliFont(.body)
                    .foregroundColor(CouliColor.textSecondary)
                    .frame(minHeight: CouliHitTarget.minimum)
                    .accessibilityHidden(true)
                field(texts.text(SearchKeys.sheetMax), text: $maxText, id: "search.price.max")
            }
            Text(verbatim: texts.text(SearchKeys.sheetNote))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if invalid {
                Text(verbatim: texts.text(SearchKeys.sheetInvalid))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.statusErrorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("search.price.invalid")
            }
        } actions: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CouliSpacing.s3) { buttons }
                VStack(spacing: CouliSpacing.s3) { buttons }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        CouliButton(texts.text(SearchKeys.sheetReset), kind: .secondary, fillsWidth: true) {
            minText = ""
            maxText = ""
            invalid = false
        }
        .accessibilityIdentifier("search.price.reset")
        CouliButton(texts.text(SearchKeys.sheetConfirm), kind: .primary, fillsWidth: true, action: confirm)
            .accessibilityIdentifier("search.price.confirm")
    }

    private func field(_ placeholder: String, text: Binding<String>, id: String) -> some View {
        TextField(text: text) {
            Text(verbatim: placeholder)
        }
        .keyboardType(.decimalPad)
        .couliFont(.body)
        .foregroundColor(CouliColor.textPrimary)
        .padding(.horizontal, CouliSpacing.s3)
        .frame(minWidth: CouliSpacing.s16 * 2, minHeight: CouliHitTarget.minimum)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .strokeBorder(CouliColor.borderControl, lineWidth: 1)
        )
        .accessibilityLabel(Text(verbatim: placeholder))
        .accessibilityIdentifier(id)
    }

    private func confirm() {
        guard let min = SearchPriceInput.fen(fromYuan: minText), let max = SearchPriceInput.fen(fromYuan: maxText),
              onApply(min, max)
        else {
            invalid = true
            return
        }
        invalid = false
    }
}
