import Generated
import MeCore
import WalletCore

/// 「我的」类页面的文案来源（BR-TEXT-12）：契约字典 → MeDraftTexts（G35）→ 已有草稿表（LoginDraftTexts 的 settings.logout.*、cs.appeal_entry；
/// WalletDraftTexts 的提现状态标题 withdrawal_status.*，G16 复用 APP-09）。已有的键不重复建。
struct AppMeTexts: MeTexts {
    private let wallet = WalletDraftTexts()

    private func raw(_ key: String) -> String? {
        if let text = MeDraftTexts.raw(key) {
            return text
        }
        if let text = LoginDraftTexts.drafts[key] {
            return text
        }
        return wallet.has(key) ? wallet.text(key) : nil
    }

    func text(_ key: String) -> String {
        guard let raw = raw(key) else { return DefaultTexts.fallback(key) ?? "" }
        return MeDraftTexts.fill(raw, key: key, vars: [:])
    }

    func format(_ key: String, _ vars: [String: String]) -> String {
        MeDraftTexts.fill(raw(key) ?? "", key: key, vars: vars)
    }
}
