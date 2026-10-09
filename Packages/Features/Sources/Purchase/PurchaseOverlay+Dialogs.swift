import DesignSystem
import ProductSearch
import SwiftUI
import Trade

// MARK: - 居中弹窗（ProductPriceChanged(+RebateGone) / ProductRebateGone / 券失效、ProductAuthDeclined / ProductAuthFailed、

// ProductAuthUnavailable、授权结果查不到、ProductJumpSdkFailed、错误提示）

extension PurchaseOverlay {
    @ViewBuilder var dialog: some View {
        switch state.dialog {
        case let .confirmPrice(oldFen, newFen, rebateGone, coupon):
            DialogCard(title: text.text(coupon ? PurchaseKeys.couponGoneTitle : PurchaseKeys.priceChangedTitle)) {
                priceBox(oldFen: oldFen, newFen: newFen)
                if rebateGone {
                    NoticeBox(
                        title: text.text(PurchaseKeys.rebateGoneLine),
                        message: text.text(PurchaseKeys.rebateGoneNote)
                    )
                }
                bodyText(text.text(PurchaseKeys.priceAsk))
            } buttons: {
                twoButtons(
                    secondary: (text.text(PurchaseKeys.cancel), controller.dismissDialog),
                    primary: (text.text(PurchaseKeys.continueBuy), controller.confirm)
                )
            }
            .accessibilityIdentifier("purchase.priceChanged")
        case let .confirmRebateGone(priceFen, oldFen):
            DialogCard(title: text.text(PurchaseKeys.rebateGoneTitle)) {
                bodyText(rebateGoneBody(newFen: priceFen, oldFen: oldFen))
            } buttons: {
                twoButtons(
                    secondary: (text.text(PurchaseKeys.cancel), controller.dismissDialog),
                    primary: (text.text(PurchaseKeys.continueBuy), controller.confirm)
                )
            }
            .accessibilityIdentifier("purchase.rebateGone")
        case let .authDeclined(platform, failed):
            DialogCard(
                title: text.text(failed ? PurchaseKeys.authFailedTitle : PurchaseKeys.authDeclinedTitle),
                icon: failed ? .alert : nil
            ) {
                bodyText(text.text(
                    failed ? PurchaseKeys.authFailedBody : PurchaseKeys.authDeclinedBody,
                    platform: platform
                ))
            } buttons: {
                CouliButton(text.text(PurchaseKeys.retry), isEnabled: !state.rateLimited, fillsWidth: true) {
                    controller.retryPurchase()
                }
                .accessibilityIdentifier("purchase.auth.retry")
                CouliButton(text.text(PurchaseKeys.buyNoRebate), kind: .secondary, isEnabled: !state.rateLimited,
                            fillsWidth: true) {
                    controller.buyWithoutRebate()
                }
                .accessibilityIdentifier("purchase.auth.noRebate")
            }
            .accessibilityIdentifier(failed ? "purchase.authFailed" : "purchase.authDeclined")
        case let .authCheckFailed(platform, textKey, traceId, _):
            DialogCard(title: text.withTrace(textKey ?? PurchaseKeys.timeout, platform: platform, traceId: traceId),
                       icon: .alert) {
                EmptyView()
            } buttons: {
                // 42901 Retry-After 期间【重试】置灰（共性第 19 条；执行层也拦下）
                CouliButton(text.text(PurchaseKeys.retry), isEnabled: !state.rateLimited, fillsWidth: true) {
                    controller.recheckAuth()
                }
                .accessibilityIdentifier("purchase.authCheck.retry")
                CouliButton(text.text(PurchaseKeys.cancel), kind: .secondary, fillsWidth: true) {
                    controller.dismissDialog()
                }
            }
            .accessibilityIdentifier("purchase.authCheckFailed")
        case let .authUnavailable(textKey):
            DialogCard(title: text.text(textKey ?? "error.30101.auth_unavailable", platform: platform), icon: .info) {
                bodyText(text.text(PurchaseKeys.authUnavailableBody))
            } buttons: {
                CouliButton(text.text(PurchaseKeys.ok), fillsWidth: true) { controller.dismissDialog() }
            }
            .accessibilityIdentifier("purchase.authUnavailable")
        case .sdkFailed:
            DialogCard(title: text.text(PurchaseKeys.sdkFailedTitle), icon: .alert) {
                bodyText(text.text(PurchaseKeys.sdkFailedBody))
            } buttons: {
                CouliButton(text.text(PurchaseKeys.ok), fillsWidth: true) { controller.dismissDialog() }
            }
            .accessibilityIdentifier("purchase.sdkFailed")
        case let .notice(textKey, traceId, noRebate, contact, retry):
            DialogCard(
                title: text.withTrace(textKey ?? SearchErrorText.genericKey, platform: platform, traceId: traceId),
                icon: .info
            ) {
                EmptyView()
            } buttons: {
                if retry {
                    CouliButton(text.text(PurchaseKeys.retry), isEnabled: !state.rateLimited, fillsWidth: true) {
                        controller.retryPurchase()
                    }
                }
                if noRebate {
                    CouliButton(text.text(PurchaseKeys.buyNoRebate), kind: retry ? .secondary : .primary,
                                isEnabled: !state.rateLimited, fillsWidth: true) {
                        controller.buyWithoutRebate()
                    }
                    .accessibilityIdentifier("purchase.notice.noRebate")
                }
                if contact {
                    CouliButton(text.text(PurchaseKeys.contact), kind: .secondary, fillsWidth: true) {
                        controller.contactService()
                    }
                }
                CouliButton(text.text(PurchaseKeys.cancel), kind: .text, fillsWidth: true) { controller.dismissDialog()
                }
            }
            .accessibilityIdentifier("purchase.notice")
        default:
            EmptyView()
        }
    }

    /// 新价的口径（共性第 21、30、37、45、47 条）：改价、券失效后券额未知，补齐前「现在」不带口径词；补齐后按实际券额给
    /// 「券后 / 售价（拼单券后 / 拼单价）」。
    var nowPriceText: String {
        text.nowLine(state.card ?? [:])
    }

    /// 返利归零弹窗正文（BR-PRICE-13；共性第 45、47 条），见 `PurchaseText.rebateGoneBody`。
    func rebateGoneBody(newFen: Int64?, oldFen: Int64?) -> String {
        text.rebateGoneBody(
            newFen: newFen, oldFen: oldFen, before: controller.cardBeforeResponse, after: state.card ?? [:]
        )
    }

    func priceBox(oldFen: Int64?, newFen: Int64?) -> some View {
        let beforeText = text.beforeLine(controller.cardBeforeResponse)
        let nowText = nowPriceText
        return VStack(spacing: CouliSpacing.s2) {
            PriceRow(
                label: beforeText,
                amount: oldFen.map { CouliFormat.money(fen: $0) } ?? "",
                spoken: oldFen.map { CouliFormat.moneySpoken(fen: $0) } ?? "",
                emphasized: false
            )
            PriceRow(
                label: nowText,
                amount: newFen.map { CouliFormat.money(fen: $0) } ?? "",
                spoken: newFen.map { CouliFormat.moneySpoken(fen: $0) } ?? "",
                emphasized: true
            )
        }
        .padding(CouliSpacing.s3)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous).fill(CouliColor.backgroundMuted)
        )
    }

    func bodyText(_ value: String) -> some View {
        Text(verbatim: value)
            .couliFont(.footnote)
            .foregroundColor(CouliColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 次按钮在前、主按钮在后并排；放不下或辅助字号档（≈200% 起）时竖排、主按钮在上（不把按钮文字折成两行）。
    @ViewBuilder
    func twoButtons(
        secondary: (String, () -> Void), primary: (String, () -> Void)
    ) -> some View {
        let stacked = VStack(spacing: CouliSpacing.s3) {
            CouliButton(primary.0, fillsWidth: true, action: primary.1)
                .accessibilityIdentifier("purchase.dialog.continue")
            CouliButton(secondary.0, kind: .secondary, fillsWidth: true, action: secondary.1)
                .accessibilityIdentifier("purchase.dialog.cancel")
        }
        if dynamicTypeSize >= .accessibility1 {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CouliSpacing.s3) {
                    CouliButton(secondary.0, kind: .secondary, fillsWidth: true, action: secondary.1)
                        .accessibilityIdentifier("purchase.dialog.cancel")
                    CouliButton(primary.0, fillsWidth: true, action: primary.1)
                        .accessibilityIdentifier("purchase.dialog.continue")
                }
                stacked
            }
        }
    }
}
