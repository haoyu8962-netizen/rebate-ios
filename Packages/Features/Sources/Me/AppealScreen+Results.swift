import CouliNetwork
import DesignSystem
import MeCore
import SwiftUI

/// 申诉页的进度与结果版式（AppealProgress*、AppealResultLifted*、AppealResultUpheld*）。
extension AppealScreen {
    func progress(_: AppealState, _ actions: AppealActions) -> some View {
        let pending = frozen ? "appeal.timeline.result_pending.frozen" : "appeal.timeline.result_pending.banned"
        return VStack(alignment: .leading, spacing: CouliSpacing.s4) {
            VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                CouliTag(texts.text("appeal.progress.badge"), style: .outline)
                Text(verbatim: texts.text("appeal.progress.heading"))
                    .couliFont(.title, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: texts.text(frozen ? "appeal.progress.desc.frozen" : "appeal.progress.desc.banned"))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            timeline(result: texts.text(pending))
            contentCard()
            HStack(spacing: CouliSpacing.s1) {
                Text(verbatim: texts.text("appeal.footer"))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                CouliButton(texts.text("appeal.contact_cs"), kind: .text, size: .compact, action: actions.contactCs)
                    .accessibilityIdentifier("appeal.cs")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appeal.progress")
    }

    /// 时间线（已提交 / 处理中 / 处理结果）：只用服务端返回的 created_at、closed_at（进度与维持结果两种版式共用，R1-08）。
    func timeline(result: String) -> some View {
        let latest = controller.latest
        return VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            timelineRow(texts.text("appeal.timeline.submitted"), time(latest?["created_at"]))
            timelineRow(texts.text("appeal.timeline.processing"),
                        AppealCopy.processingDesc(frozenLayout: frozen, state: controller.riskState)
                            .map(texts.text))
            timelineRow(texts.text("appeal.timeline.result"), result)
                .accessibilityIdentifier("appeal.timeline.result")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .couliCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appeal.timeline")
    }

    /// 原申诉内容（服务端返回的 content）；没有就不显示。
    @ViewBuilder
    func contentCard() -> some View {
        if let content = controller.latest?["content"] as? String {
            VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                Text(verbatim: texts.text("appeal.content_section"))
                    .couliFont(.body, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: content)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("appeal.content")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .couliCard()
        }
    }

    func timelineRow(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            Text(verbatim: title)
                .couliFont(.footnote, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
            if let detail {
                Text(verbatim: detail)
                    .couliFont(.footnote, monospacedDigits: true)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    func lifted(_ actions: AppealActions) -> some View {
        let state = controller.riskState
        return VStack(alignment: .leading, spacing: CouliSpacing.s4) {
            VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                Text(verbatim: texts.text(AppealCopy.liftedTitle(frozenLayout: frozen, state: state)))
                    .couliFont(.title, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("appeal.result.title")
                Text(verbatim: texts.text(AppealCopy.liftedDesc(state)))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                MeInfoRow(label: texts.text("appeal.conclusion"), value: texts.text("appeal.passed"))
                if let closed = time(controller.latest?["closed_at"]) {
                    MeInfoRow(label: texts.text("appeal.closed_at"), value: closed)
                }
                if let key = AppealCopy.currentStateKey(state) {
                    MeInfoRow(label: texts.text(frozen ? "appeal.withdraw" : "appeal.account_state"),
                              value: texts.text(frozen && state == "normal" ? "appeal.withdraw_ok" : key))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .couliCard()
            if let note = AppealCopy.liftedNote(frozenLayout: frozen, state: state) {
                Text(verbatim: texts.text(note))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(AppealCopy.liftedActions(frozenLayout: frozen, state: state), id: \.self) { raw in
                CouliButton(texts.text(Self.actionKey(raw)), kind: raw == "view_messages" ? .text : .primary,
                            fillsWidth: raw != "view_messages") { actions.action(raw) }
                    .accessibilityIdentifier("appeal.action." + raw)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appeal.result.lifted")
    }

    static func actionKey(_ raw: String) -> String {
        switch raw {
        case "go_wallet": "appeal.go_wallet"
        case "start": "appeal.start"
        case "view_messages": "appeal.view_messages"
        default: "appeal.contact_cs"
        }
    }

    func upheld(_ actions: AppealActions) -> some View {
        let state = controller.riskState
        let closed = time(controller.latest?["closed_at"])
        return VStack(alignment: .leading, spacing: CouliSpacing.s4) {
            VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                CouliTag(texts.text("appeal.upheld.badge"), style: .outline)
                Text(verbatim: texts.text("appeal.upheld.title"))
                    .couliFont(.title, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("appeal.result.title")
                Text(verbatim: texts.text("appeal.upheld.desc"))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let closed {
                    MeInfoRow(label: texts.text("appeal.closed_at"), value: closed)
                }
            }
            // R1-08（设计稿 AppealResultUpheld）：时间线 + 当前状态 + 接下来可以 + 原申诉内容。处理结果一行是历史结论；当前限制只按本次 risk.state
            timeline(result: closed.map { texts.format("appeal.upheld.result_line", ["time": $0]) }
                ?? texts.text("appeal.upheld.title"))
            if let key = AppealCopy.currentStateKey(state) {
                MeInfoRow(
                    label: texts.text(frozen ? "appeal.current_frozen_state" : "appeal.current_account_state"),
                    value: texts.text(key)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .couliCard()
            }
            upheldNext(state)
            contentCard()
            CouliButton(texts.text("appeal.again"), fillsWidth: true, action: actions.again)
                .accessibilityIdentifier("appeal.again")
            HStack(spacing: CouliSpacing.s3) {
                CouliButton(texts.text("risk.contact_cs"), kind: .text, action: actions.contactCs)
                    .accessibilityIdentifier("appeal.cs")
                Text(verbatim: "|")
                    .foregroundColor(CouliColor.textSecondary)
                    .accessibilityHidden(true)
                CouliButton(texts.text("risk.logout"), kind: .text, action: actions.askLogout)
                    .accessibilityFocused($logoutFocused)
                    .accessibilityIdentifier("appeal.logout")
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appeal.result.upheld")
    }

    func upheldNext(_ state: String?) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            Text(verbatim: texts.text("appeal.next"))
                .couliFont(.body, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
            ForEach(nextLines(state), id: \.self) { key in
                Text(verbatim: texts.text(key))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func nextLines(_ state: String?) -> [String] {
        var lines = ["appeal.next.again", "appeal.next.cs"]
        if AppealCopy.upheldFrozenNext(frozenLayout: frozen, state: state) {
            lines.append("appeal.next.frozen")
        } else {
            lines.append("appeal.next.logout")
        }
        return lines
    }
}
