import DesignSystem
import SwiftUI
import WalletCore

/// 一张单的显示素材（收起行与展开卡共用；文字全部取字典 / 纯规则，视图只切展示）。
struct RecordFace {
    let item: Withdrawal
    let display: WithdrawalDisplay
    /// `WithdrawalText.render` 的全部行（G08：原因与退回句之间分号连接）。
    let lines: [String]
    let title: String
    let status: String
    let channel: String
    let spokenChannel: String

    @MainActor
    init(item: Withdrawal, texts: WalletTexts, slaText: String?, now: Int64) {
        self.item = item
        display = WithdrawalText.of(item, slaText: slaText, texts: texts)
        lines = WithdrawalText.render(display, texts: texts, money: WalletMoney.text)
        title = texts.format("withdraw_records.item", ["amount": WalletMoney.text(item.amountFen)])
        status = texts.text(display.titleKey)
        let account = item.payoutChannelName + " " + item.maskedAccount
        let date = CouliFormat.timeListPast(epochMillis: item.createdAtMillis, nowEpochMillis: now)
        channel = texts.format("withdraw_records.channel_line", ["date": date, "account": account])
        spokenChannel = WalletAnnounce.masked(channel, texts: texts)
    }

    /// 读屏：金额、状态、时间账号（`full` 时再加完整副文案）。
    @MainActor
    func spoken(full: Bool, texts: WalletTexts) -> String {
        var parts = [title, status, spokenChannel]
        if full {
            parts += lines.map { WalletAnnounce.masked($0, texts: texts) }
        }
        return parts.joined(separator: PriceTerms.spokenPause)
    }

    /// 状态块各行（W24）：第一行 17 主文字；第一行若是「原因；退回句」，在字典连接符处切成原因 17 + 退回句 14 次文字两行（只切展示，
    /// 文本不改）；其余各行 12 次文字。未知状态没有行。
    func statusLines(texts: WalletTexts) -> [RecordStatusLine] {
        guard let first = lines.first else { return [] }
        var out: [RecordStatusLine] = []
        let reason = display.subLines.first {
            $0.key.hasPrefix("withdraw_reject_reason.") || $0.key.hasPrefix("withdraw_fail_reason.")
        }.map { $0.render(texts, money: WalletMoney.text) }
        let join = texts.text("withdrawal.draft.join")
        if let reason, first.hasPrefix(reason + join), first.count > reason.count + join.count {
            out.append(RecordStatusLine(text: reason, style: .body, primary: true))
            out.append(RecordStatusLine(text: String(first.dropFirst(reason.count + join.count)), style: .footnote,
                                        primary: false))
        } else {
            out.append(RecordStatusLine(text: first, style: .body, primary: true))
        }
        out += lines.dropFirst().map { RecordStatusLine(text: $0, style: .caption, primary: false) }
        return out
    }
}

struct RecordStatusLine {
    let text: String
    let style: CouliTextStyle
    let primary: Bool
}

/// 收起行（W21、W22）：左「提现 ¥x」17/600 + 时间 · 渠道 + 脱敏账号 12 次文字 + 副文案首句 14 主文字；右状态胶囊（与金额同行，放不下换到
/// 金额下方）+ 20 向下箭头。整行一个目标（展开），读屏读金额、状态、时间账号与完整副文案，展开状态在 value 里。
/// 测量：`records.row.<id>`（`card` = 所在月卡）、`.amount` / `.channel` / `.line` / `.pill*` / `.arrow`。
struct RecordRow: View {
    let face: RecordFace
    let card: String
    let texts: WalletTexts
    let actions: RecordsActions

    var body: some View {
        let id = face.item.withdrawalId
        let probe = "records.row.\(id)"
        Button {
            actions.toggle(id)
        } label: {
            HStack(alignment: .center, spacing: CouliSpacing.s3) {
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s1) {
                        RecordText(face.title, style: .body, weight: .couliSemibold, color: CouliColor.textPrimary,
                                   monospacedDigits: true, probe: probe + ".amount")
                        RecordStatusPill(status: face.item.status, title: face.status, probe: probe + ".pill")
                            .couliFlowPushTrailing(.inlineOnly)
                    }
                    RecordText(face.channel, style: .caption, color: CouliColor.textSecondary, monospacedDigits: true,
                               probe: probe + ".channel")
                    if let first = face.lines.first {
                        RecordText(first, style: .footnote, color: CouliColor.textPrimary, monospacedDigits: true,
                                   probe: probe + ".line")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                CouliIconView(.chevronDown, size: CouliComponentMetric.iconMedium, relativeTo: .footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .walletProbe(probe + ".arrow", role: "icon")
            }
            .padding(.vertical, CouliSpacing.s3)
            .padding(.horizontal, CouliSpacing.s4)
            .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum, alignment: .leading)
            .contentShape(Rectangle())
            // 整行 / 卡头一个读屏目标：内部文字不另成子元素（名称由按钮的 accessibilityLabel 给）
            .accessibilityElement(children: .ignore)
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: 0))
        .accessibilityLabel(Text(verbatim: face.spoken(full: true, texts: texts)))
        .accessibilityValue(Text(verbatim: texts.text("withdraw_records.collapsed")))
        .accessibilityHint(Text(verbatim: texts.text("withdraw_records.expand")))
        .accessibilityIdentifier("record.\(id)")
        .couliProbe(probe, role: "row", card: card)
    }
}

/// 一张月卡（同月相邻的收起行，行间 1 分隔线，左右内缩 16；W20）。测量：`card`。
struct RecordMonthCard: View {
    let faces: [RecordFace]
    let card: String
    let texts: WalletTexts
    let actions: RecordsActions
    let keeper: RecordListKeeper

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(faces.enumerated()), id: \.element.item.withdrawalId) { index, face in
                if index > 0 {
                    RecordDivider()
                        .padding(.horizontal, CouliSpacing.s4)
                }
                RecordRow(face: face, card: card, texts: texts, actions: actions)
                    .recordPlace(face.item.withdrawalId, keeper: keeper)
            }
        }
        .frame(maxWidth: .infinity)
        .recordCard()
        .walletProbe(card, role: "card")
    }
}
