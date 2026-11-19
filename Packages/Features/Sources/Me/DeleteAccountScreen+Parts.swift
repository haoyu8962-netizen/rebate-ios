import CouliNetwork
import DesignSystem
import MeCore
import SwiftUI
import WalletCore

/// 注销页的共用件（读取失败块、卡片、正文、页内提示）。
extension DeleteAccountBody {
    // MARK: - 共用件

    /// 写请求的提示文字（G26）：字典里没有这个键（表外码）时回落到服务端 msg；msg 也空时用统一兜底句。
    func flowMessage(_ notice: Notice, _ state: DeletionSnapshot) -> String {
        if !texts.has(notice.key), let msg = state.serverMsg[notice.key],
           !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return msg
        }
        let text = notice.message(texts)
        return text.isEmpty ? texts.text("error.50001") : text
    }

    func failure(_ title: String, _ error: Notice?, retryEnabled: Bool, actions: DeleteAccountActions,
                 id: String) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            bodyText(title)
            if let error {
                errorLine(error.message(texts), id: error.id, identifier: id + ".error")
            }
            CouliButton(texts.text("wallet.retry"), kind: .secondary, size: .compact, isEnabled: retryEnabled,
                        action: actions.retry)
                .accessibilityIdentifier(id + ".retry")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(id)
    }

    func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            content()
        }
        .padding(CouliSpacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
            .fill(CouliColor.backgroundSurface))
    }

    func bodyText(_ text: String, secondary: Bool = false, weight: Font.Weight = .regular) -> some View {
        Text(verbatim: text)
            .couliFont(secondary ? .footnote : .body, weight: weight)
            .foregroundColor(secondary ? CouliColor.textSecondary : CouliColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 页内提示：出现时播报一次（错误 assertive，其余 polite）。
    func errorLine(_ text: String, id: Int, identifier: String, assertive: Bool = true) -> some View {
        Text(verbatim: text)
            .couliFont(.footnote)
            .foregroundColor(CouliColor.statusErrorText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
            .task(id: id) { MeAnnounce.post(text, assertive: assertive) }
    }
}
