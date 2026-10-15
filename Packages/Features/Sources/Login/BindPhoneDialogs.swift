import DesignSystem
import SwiftUI

/// BindPhoneMerge 弹窗正文：说明句 + 浅底信息块（并入图标、「并入到」、「手机号账号 138****5678」）。
struct BindMergeBody: View {
    let message: String
    let into: String
    let account: String

    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            Text(verbatim: message)
                .couliFont(.body)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bindPhone.merge.body")
            HStack(spacing: CouliSpacing.s3) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 20))
                    .foregroundColor(CouliColor.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: into)
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                    Text(verbatim: account)
                        .couliFont(.body, weight: .couliSemibold, monospacedDigits: true)
                        .foregroundColor(CouliColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }
            .padding(CouliSpacing.s3)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .fill(CouliColor.backgroundMuted)
            )
        }
    }
}

/// 待确认卡（G07，版式照 PhoneChangePendingConfirm）：警示条（标题 + 说明）、摘要（提交的手机号、提交时间）、【放弃上一次提交】
/// 【确认上一次提交】、底部说明。回调携带渲染时的原键（APP-09 共性第 4、14 条）。
struct BindPendingCardView: View {
    let card: BindPendingCard
    @ObservedObject var controller: BindPhoneController
    let texts: LoginTexts

    var body: some View {
        let key = card.key
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                CouliIconView(.alert, size: CouliGuideMetric.iconMedium)
                    .foregroundColor(CouliColor.statusWarningText)
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    Text(verbatim: texts.text(BindPhoneKeys.pendingTitle))
                        .couliFont(.body, weight: .couliSemibold)
                    Text(verbatim: texts.format(BindPhoneKeys.pendingDesc, ["phone": card.maskedPhone]))
                        .couliFont(.body, monospacedDigits: true)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(CouliColor.statusWarningText)
                Spacer(minLength: 0)
            }
            .padding(CouliSpacing.s3)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .fill(CouliColor.statusWarningText.opacity(0.1))
            )
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
            VStack(spacing: CouliSpacing.s1) {
                summaryRow(texts.text(BindPhoneKeys.pendingPhoneLabel), card.maskedPhone)
                summaryRow(texts.text(BindPhoneKeys.pendingTimeLabel), Self.time(card.submittedAtMillis))
            }
            .padding(CouliSpacing.s3)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .fill(CouliColor.backgroundMuted)
            )
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CouliSpacing.s3) { buttons(key) }
                VStack(spacing: CouliSpacing.s3) { buttons(key) }
            }
            if let notice = controller.pendingNotice {
                Text(verbatim: notice.text)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.statusErrorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("bindPhone.pendingNotice")
            }
            Text(verbatim: texts.text(BindPhoneKeys.pendingHint))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .couliCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bindPhone.pending")
    }

    @ViewBuilder private func buttons(_ key: String) -> some View {
        CouliButton(
            texts.text(BindPhoneKeys.pendingAbandon), kind: .secondary,
            isEnabled: controller.pendingActionsEnabled, fillsWidth: true,
            action: { controller.askAbandon(key: key) }
        )
        .accessibilityIdentifier("bindPhone.pending.abandon")
        CouliButton(
            texts.text(BindPhoneKeys.pendingAction), isLoading: controller.pendingBusy,
            isEnabled: controller.pendingActionsEnabled, fillsWidth: true,
            action: { controller.confirmPending(key: key) }
        )
        .accessibilityIdentifier("bindPhone.pending.confirm")
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: CouliSpacing.s3) {
            Text(verbatim: label)
                .foregroundColor(CouliColor.textSecondary)
            Spacer(minLength: CouliSpacing.s2)
            Text(verbatim: value)
                .foregroundColor(CouliColor.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .couliFont(.body, monospacedDigits: true)
        .accessibilityElement(children: .combine)
    }

    /// 提交时间（本机时区，MM-dd HH:mm，同设计稿）。
    static func time(_ millis: Int64) -> String {
        guard millis > 0 else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }
}
