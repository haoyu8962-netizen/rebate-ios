import DesignSystem
import Foundation
import MeCore
import SwiftUI

/// 换号待确认卡（PhoneChangePending*）：pending_confirm.title + pending_confirm.phone_change.desc（{phone} 本机脱敏的新号）、摘要（提交的
/// 新号 + 提交时间，标签沿用 bind_phone.pending.phone_label / time_label）、【放弃上一次提交】【确认上一次提交】（在途或 phoneGate 禁用期
/// 内都置灰）、卡内提示（retry_later / cannot_confirm / abandon_busy），下方「结果确认前不能再次更换手机号」。表单不显示（置灰）。
/// 卡片出现由执行器的 `announce` 打断播报一次（alert）。
struct PhoneChangePendingView: View {
    let card: PhoneChangePendingCard
    let state: PhoneChangeState
    let actions: PhoneChangeActions
    let texts: MeTexts
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                CouliIconView(.alert, size: CouliComponentMetric.iconMedium)
                    .foregroundColor(CouliColor.statusWarningText)
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    MeText(texts.text("pending_confirm.title"), style: .body, weight: .couliSemibold,
                           probe: "phoneChange.pending.title")
                    let phone = card.submittedPhoneDigits ?? ""
                    MeText(texts.format("pending_confirm.phone_change.desc", ["phone": phone]),
                           style: .body, monospacedDigits: true, probe: "phoneChange.pending.desc")
                }
                .foregroundColor(CouliColor.statusWarningText)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                summaryRow(texts.text("bind_phone.pending.phone_label"), card.submittedPhoneDigits ?? "")
                summaryRow(texts.text("bind_phone.pending.time_label"), Self.time(card.submittedAtMillis))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CouliSpacing.s3) { buttons }
                VStack(spacing: CouliSpacing.s3) { buttons }
            }
            if let notice = state.pendingNotice {
                MeText(notice.message(texts), style: .footnote, probe: "phoneChange.pendingNotice")
                    .foregroundColor(CouliColor.statusErrorText)
                    .accessibilityIdentifier("phoneChange.pendingNotice")
            }
            MeText(texts.text("phone_change.pending.no_repeat"), style: .footnote, probe: "phoneChange.pending.note")
                .foregroundColor(CouliColor.textSecondary)
        }
        .couliCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phoneChange.pending")
    }

    @ViewBuilder private var buttons: some View {
        CouliButton(texts.text("pending_confirm.abandon"), kind: .secondary, isEnabled: enabled, fillsWidth: true,
                    action: actions.askAbandon)
            .accessibilityIdentifier("phoneChange.pending.abandon")
        CouliButton(texts.text("pending_confirm.phone_change.action"), isLoading: state.pendingBusy,
                    isEnabled: enabled, fillsWidth: true, action: actions.confirmPending)
            .accessibilityIdentifier("phoneChange.pending.confirm")
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(verbatim: label).foregroundColor(CouliColor.textSecondary)
                Spacer(minLength: CouliSpacing.s3)
                Text(verbatim: value).foregroundColor(CouliColor.textPrimary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: label).foregroundColor(CouliColor.textSecondary)
                Text(verbatim: value).foregroundColor(CouliColor.textPrimary)
            }
        }
        .couliFont(.body, monospacedDigits: true)
        .accessibilityElement(children: .combine)
    }

    /// 提交时间（本机时区，MM-dd HH:mm，同 BindPhone 待确认卡）。
    static func time(_ millis: Int64) -> String {
        guard millis > 0 else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }
}
