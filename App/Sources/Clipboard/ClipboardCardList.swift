import Clipboard
import DesignSystem
import ProductSearch
import SwiftUI

/// 多卡弹层（G09，没有专稿）：底部半屏「识别到的商品」，按搜索卡样式列出；点卡片或购买按钮都以这张卡为种子打开详情（A03 同口径）；
/// 行内 error_code 的那条置灰、写该码文案（30132 另给【用商品名搜索】，5xxxx 带 trace6）。42901 共享禁用期内卡片、购买按钮、
/// 【用商品名搜索】一并置灰（执行层 openCard / searchByName 另拦，共性第 31 条）。平台购买状态与搜索卡同一映射（`cardMapping`，R3-01）。
struct ClipboardCardList: View {
    @ObservedObject var clipboard: AppClipboard
    let id: Int64
    let rows: [ParseRow]
    let traceId: String?

    var body: some View {
        CouliSheet(
            title: ClipboardDraftTexts.text("clipboard.card_list.title"),
            closeLabel: ClipboardDraftTexts.text("clipboard.card_list.close"),
            onClose: { clipboard.dismissResult(id) },
            content: {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if let card = row.card {
                        let mapping = clipboard.cardMapping(card)
                        ProductCard(mapping.data, onBuy: { clipboard.openCard(id, card: card) }, image: {
                            ProductRemoteImage(url: ProductImageSource.url(card["image"]))
                        })
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !clipboard.blocked {
                                clipboard.openCard(id, card: card)
                            }
                        }
                        .disabled(clipboard.blocked)
                        .opacity(clipboard.blocked ? 0.5 : 1)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("clipboard.card.\(index)")
                    } else {
                        errorRow(row, index: index)
                    }
                }
            }, actions: {
                EmptyView()
            }
        )
        .accessibilityIdentifier("clipboard.cardList")
    }

    private func errorRow(_ row: ParseRow, index: Int) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            if let raw = row.hitRaw {
                Text(verbatim: raw)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(verbatim: AppClipboard.rowText(row, traceId: traceId))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
            if row.errorCode == ParseResultAction.unrecognized {
                Button {
                    clipboard.searchByName(id, prefill: ClipboardText.searchPrefill(row.hitRaw))
                } label: {
                    Text(verbatim: ClipboardDraftTexts.text("clipboard.search_by_name"))
                        .couliFont(.footnote, weight: .couliSemibold)
                        .foregroundColor(CouliColor.textLink)
                        .frame(minHeight: CouliHitTarget.minimum, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(clipboard.blocked)
            }
        }
        .padding(CouliSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(CouliColor.backgroundMuted)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clipboard.cardError.\(index)")
    }
}

extension AppClipboard {
    /// 多卡弹层商品卡的展示映射（R3-01，共性第 32 条，APP-06a 共性第 31 条）：与搜索卡同一映射——先 ProductCardMapper.map，再按本平台的
    /// 购买状态 applyPurchaseStatus（not_launched 隐藏返利金额、预估返后及其读屏金额，按钮置灰「{平台}返利即将开放」；maintenance 按钮置灰
    /// 「稍后再试」）。每次现取状态；配置变化经 `purchaseRevision` 发布重画。单卡结果打开的详情页由 ProductDetailController 用同一来源。
    func cardMapping(_ card: [String: Any], texts: (String) -> String = AppSearchTexts().text) -> ProductCardMapping {
        var mapping = ProductCardMapper.map(card, texts: texts)
        let platform = card["platform"] as? String ?? ""
        mapping.data = ProductCardMapper.applyPurchaseStatus(
            mapping.data, statusRaw: purchaseSource?.purchaseStatus(platform: platform), texts: texts
        )
        return mapping
    }
}

extension View {
    /// 多卡弹层盖在整个导航栈上：发起页仍是当前页时显示（结果绑定发起页）。
    func clipboardCardSheet(_ clipboard: AppClipboard) -> some View {
        modifier(ClipboardCardSheet(clipboard: clipboard))
    }
}

private struct ClipboardCardSheet: ViewModifier {
    @ObservedObject var clipboard: AppClipboard

    private struct Listing {
        let id: Int64
        let rows: [ParseRow]
        let traceId: String?
    }

    private var list: Listing? {
        guard let result = clipboard.result, result.origin == clipboard.currentOrigin(),
              case let .cardList(rows, traceId) = result.kind
        else { return nil }
        return Listing(id: result.id, rows: rows, traceId: traceId)
    }

    func body(content: Content) -> some View {
        let list = list
        content.couliSheet(
            isPresented: list != nil,
            dismissOnScrim: { list.map { clipboard.dismissResult($0.id) } },
            sheet: {
                if let list {
                    ClipboardCardList(clipboard: clipboard, id: list.id, rows: list.rows, traceId: list.traceId)
                }
            }
        )
    }
}
