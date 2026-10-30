import DesignSystem
import SwiftUI
import WalletCore

/// 展开项（W23–W29，画板 WithdrawRecordsPending-v2 / Paid-v2 / Failed-v2）：单独成卡（描边 + 阴影、内边距 16、块间 12）。
/// 卡头「申请金额」12 + 28/700 等宽大数 + 胶囊 + 朝上箭头（整块一个收起目标）→ 状态块（主句 17、附句 12 次文字；失败原因 17 + 退回句 14；
/// 账号类失败【修改收款账号】通栏描边在此）→ 分隔线 → 明细字段表（手续费 / 代扣个税为 0 不写）→ 交易流水号两行 +【复制】→ 客服行。
/// 明细与流水号取同一份详情（共性第 28、34 条）；回调全部是渲染时取出的 `RecordsActions`（带版本与身份）。
struct RecordDetailCard: View {
    let face: RecordFace
    let detail: Withdrawal?
    let texts: WalletTexts
    let actions: RecordsActions
    @Environment(\.dynamicTypeSize) private var typeSize

    /// 辅助字号（AX1–AX5）：明细与流水号改成标签在上、值在下（r1 S2-5：值列太窄时日期 / 账号会在词中间断开）。
    private var stacked: Bool {
        typeSize.isAccessibilitySize
    }

    private var id: String {
        face.item.withdrawalId
    }

    private var probe: String {
        "records.detail.\(id)"
    }

    var body: some View {
        let source = detail ?? face.item
        let lines = face.statusLines(texts: texts)
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            header
            if !lines.isEmpty {
                statusBlock(lines)
            }
            if face.display.showChangeAccount, face.display.knownChannel,
               source.status == "FAILED" || source.status == "REJECTED" {
                RecordOutlineButton(
                    title: texts.text("withdraw_detail.change_account"),
                    probe: probe + ".changeAccount"
                ) {
                    actions.changeAccount(source.withdrawalId)
                }
                .accessibilityIdentifier("record.changeAccount")
            }
            RecordDivider()
            fields(source)
            if let text = TradeNoRow.copyText(status: source.status, channelOrderId: source.channelOrderId),
               source.isDetail {
                RecordDivider()
                tradeNo(source, text)
            }
            if let note = serviceNote(source) {
                RecordDivider()
                serviceRow(note)
            }
        }
        .padding(CouliSpacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .recordCard(bordered: true)
        .walletProbe(probe, role: "card")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("record.detail.\(id)")
    }

    /// 卡头：整块一个收起目标；读屏只读金额、状态、时间账号（副文案由状态块读一次，Android b r1 S2-3）。
    /// 画面内容放在按钮之上、不接点击也不进读屏树（放进按钮标签里时，XCUI / 读屏树会把「申请金额」与大数当成按钮的子元素列出，
    /// 排在【修改收款账号】之前像一行明细）；按钮本身铺在内容背后，命中区 = 整个卡头，按下浅底照常。
    private var header: some View {
        HStack(alignment: .center, spacing: CouliSpacing.s3) {
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s1) {
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    RecordText(texts.text("withdraw_detail.amount"), style: .caption,
                               color: CouliColor.textSecondary, probe: probe + ".header.label")
                    WalletAmount(text: WalletMoney.text(face.item.amountFen), style: .heading,
                                 weight: .couliBold, probe: probe + ".header.amount")
                        .foregroundColor(CouliColor.textPrimary)
                }
                RecordStatusPill(status: face.item.status, title: face.status, probe: probe + ".header.pill")
                    .couliFlowPushTrailing(.inlineOnly)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CouliIconView(.chevronDown, size: CouliGuideMetric.iconMedium, relativeTo: .footnote)
                .foregroundColor(CouliColor.textSecondary)
                .rotationEffect(.degrees(180))
                .walletProbe(probe + ".header.arrow", role: "icon")
        }
        .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .background(
            Button {
                actions.toggle(id)
            } label: {
                Color.clear
                    .contentShape(Rectangle())
            }
            .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
            .accessibilityLabel(Text(verbatim: face.spoken(full: false, texts: texts)))
            .accessibilityValue(Text(verbatim: texts.text("withdraw_records.expanded")))
            .accessibilityHint(Text(verbatim: texts.text("withdraw_records.collapse")))
            .accessibilityIdentifier("record.\(id)")
        )
        .walletProbe(probe + ".header", role: "header")
    }

    private func statusBlock(_ lines: [RecordStatusLine]) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                RecordText(line.text, style: line.style, color: line.primary ? CouliColor.textPrimary
                    : CouliColor.textSecondary, monospacedDigits: true, probe: probe + ".status.\(index)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text(verbatim: WalletAnnounce.masked(line.text, texts: texts)))
            }
        }
    }

    /// 明细字段表（W26）：标签不伸缩、值右对齐等宽可折行、行距 8；金额逐项取服务端字段（不推算）；手续费、代扣个税为 0 不写。
    private func fields(_ source: Withdrawal) -> some View {
        let account = source.payoutChannelName + " " + source.maskedAccount
        return VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            field("amount", texts.text("withdraw_detail.amount"), WalletMoney.text(source.amountFen))
            if source.feeFen != 0 {
                field("fee", texts.text("withdraw_detail.fee"), WalletMoney.text(source.feeFen))
            }
            if source.taxFen != 0 {
                field("tax", texts.text("withdraw_detail.tax"), WalletMoney.text(source.taxFen))
            }
            if let netKey = face.display.netKey {
                field("net", texts.text(netKey == WithdrawalText.netActual
                          ? "withdraw_detail.net_label.actual" : "withdraw_detail.net_label.expected"),
                WalletMoney.text(source.netFen))
            }
            field("payout", texts.text("withdraw_detail.payout"), account,
                  spoken: WalletAnnounce.masked(account, texts: texts))
            // 明细里的申请时间用完整写法「YYYY-MM-DD HH:mm」（列表行仍用 BR-TEXT-11 的相对写法）
            field("created", texts.text("withdraw_detail.created"),
                  CouliFormat.timeMinute(epochMillis: source.createdAtMillis))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .walletProbe(probe + ".fields", role: "fields")
    }

    /// 一行明细：常规字号左标签右值（值右对齐、可折行）；辅助字号标签在上、值在下（值占满卡宽、左对齐，只在空格处折行——
    /// 「2026-09-27 15:20」折成日期 / 时间、「支付宝 138****5678」折成通道 / 账号，不在词中间断）。
    @ViewBuilder
    private func field(_ key: String, _ label: String, _ value: String, spoken: String? = nil) -> some View {
        let title = RecordText(label, style: .footnote, color: CouliColor.textSecondary, singleLine: !stacked,
                               probe: probe + ".field.\(key).label")
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    title
                    RecordText(value, style: .footnote, color: CouliColor.textPrimary, monospacedDigits: true,
                               probe: probe + ".field.\(key).value")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .top, spacing: CouliSpacing.s3) {
                    title
                    RecordText(value, style: .footnote, color: CouliColor.textPrimary, monospacedDigits: true,
                               alignment: .trailing, probe: probe + ".field.\(key).value")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label + PriceTerms.spokenPause + (spoken ?? value)))
    }

    /// 交易流水号两行（标签 / 号码）+ 右侧【复制】（W27）。
    private func tradeNo(_ source: Withdrawal, _ text: String) -> some View {
        let label = texts.text("withdraw_detail.trade_no")
        let number = VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            RecordText(label, style: .footnote, color: CouliColor.textSecondary, probe: probe + ".tradeNo.label")
            RecordText(text, style: .footnote, color: CouliColor.textPrimary, monospacedDigits: true,
                       probe: probe + ".tradeNo.value")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label + PriceTerms.spokenPause + text))
        .accessibilityIdentifier("record.tradeNo")
        let copy = RecordLinkButton(title: texts.text("withdraw_detail.copy"), icon: .copy, probe: probe + ".copy") {
            actions.copy(source.withdrawalId, text)
        }
        .accessibilityIdentifier("record.copy")
        // 辅助字号：【复制】换到号码下方（左对齐），标签「交易流水号」与号码占满卡宽，不被按钮挤得在词中间断开（r1 S2-5）
        return Group {
            if stacked {
                VStack(alignment: .leading, spacing: 0) {
                    number
                    copy
                }
            } else {
                HStack(alignment: .center, spacing: CouliSpacing.s2) {
                    number
                    copy
                }
            }
        }
    }

    /// 客服行的说明：认识的通道且审核中 / 打款中 / 失败 / 未通过（打款中按画板 WithdrawRecordsPaying-v2 与 Android 三端统一口径，
    /// 编排 2026-10-30 裁定）；已到账、未知状态与不认识的通道（含微信零钱）不出客服行。
    private func serviceNote(_ source: Withdrawal) -> String? {
        guard face.display.knownChannel else { return nil }
        if WithdrawalText.isReviewing(source.status) {
            return texts.text("withdraw.irrevocable")
        }
        if source.status == "PAYING" || source.status == "FAILED" || source.status == "REJECTED" {
            return texts.text("withdraw_detail.doubt")
        }
        return nil
    }

    /// 客服行（W29）：说明 12 次文字 +「联系客服」14/500 链接色；行高 44（画板），链接视觉只是文字，命中区 44 不另撑高。
    private func serviceRow(_ note: String) -> some View {
        HStack(alignment: .center, spacing: CouliSpacing.s2) {
            RecordText(note, style: .caption, color: CouliColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            RecordLinkButton(title: texts.text("withdraw_detail.cs"), icon: nil, probe: probe + ".service.link",
                             action: actions.contact)
                .accessibilityIdentifier("record.cs")
        }
        .frame(minHeight: CouliHitTarget.minimum)
        .walletProbe(probe + ".service", role: "service")
    }
}

/// 链接式按钮（【复制】【联系客服】）：视觉 = 可选 16 图标 + 14/500 链接色文字（左右 4）；命中区 = 视觉外扩到至少 44 × 44（只在视觉不足
/// 44 时外扩，所在行不因命中区变高——行高由同行内容决定）。测量：`probe` 视觉、`.hit` 命中、`.icon`、`.label`。
struct RecordLinkButton: View {
    let title: String
    let icon: CouliIcon?
    let probe: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: CouliSpacing.s1) {
                if let icon {
                    CouliIconView(icon, size: CouliSpacing.s4, relativeTo: .footnote)
                        .walletProbe(probe + ".icon", role: "icon")
                }
                RecordText(title, style: .footnote, weight: .couliMedium, color: CouliColor.textLink,
                           singleLine: true, probe: probe + ".label")
            }
            .foregroundColor(CouliColor.textLink)
            .padding(.horizontal, CouliSpacing.s1)
            .walletProbe(probe, role: "link")
            .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
            .contentShape(Rectangle())
            .walletProbe(probe + ".hit", role: "hit")
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
        .fixedSize()
        .accessibilityLabel(Text(verbatim: title))
    }
}

/// 通栏描边次按钮（【修改收款账号】，画板 Failed-v2：白底、border.control 描边、圆角 12、14/500、最小高 44）。视觉 = 命中。
struct RecordOutlineButton: View {
    let title: String
    let probe: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RecordText(title, style: .footnote, weight: .couliMedium, color: CouliColor.textPrimary,
                       alignment: .center)
                .padding(.vertical, CouliSpacing.s2)
                .padding(.horizontal, CouliSpacing.s4)
                .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(RecordOutlineStyle())
        .walletProbe(probe, role: "button")
        .walletProbe(probe + ".hit", role: "hit")
        .accessibilityLabel(Text(verbatim: title))
    }
}

private struct RecordOutlineStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .fill(configuration.isPressed ? CouliColor.backgroundMuted : CouliColor.backgroundSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .strokeBorder(CouliColor.borderControl, lineWidth: CouliComponentMetric.controlBorderWidth)
            )
    }
}
