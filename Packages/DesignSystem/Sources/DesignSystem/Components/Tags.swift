import SwiftUI

/// 胶囊标签的配色（GUIDE §3「标签（胶囊）」、§7.1）。状态不只靠颜色：状态类配色都带图标。
public enum CouliTagStyle: Sendable {
    /// 优惠标签（有券、预售、规格以下单页为准…）：白底、装饰描边、墨棕字。
    case outline
    /// 预估 / 等待：中性浅底 + 钟表。
    case pending
    /// 已结算 / 已完成：松叶绿浅底 + 对勾。
    case success
    /// 警告：浅黄底 + 三角。
    case warning
    /// 错误：浅红底 + 三角。
    case error
    /// 中性提示（规格待确认等）：中性浅底 + 信息图标。
    case neutralInfo

    struct Colors {
        let background: Color
        let text: Color
        let border: Color?
    }

    var colors: Colors {
        switch self {
        case .outline: Colors(background: CouliColor.backgroundSurface, text: CouliColor.textPrimary,
                              border: CouliColor.borderSubtle)
        case .pending, .neutralInfo: Self.status("pending")
        case .success: Self.status("success")
        case .warning: Self.status("warning")
        case .error: Self.status("error")
        }
    }

    private static func status(_ name: String) -> Colors {
        Colors(
            background: CouliColor.token("status.\(name).background"),
            text: CouliColor.token("status.\(name).text"),
            border: nil
        )
    }

    var icon: CouliIcon? {
        switch self {
        case .outline: nil
        case .pending: .clock
        case .success: .check
        case .warning, .error: .alert
        case .neutralInfo: .info
        }
    }
}

/// 胶囊标签：caption 12/18，最小高 22（大字号时增高，不截断）。
public struct CouliTag: View {
    private let text: String
    private let style: CouliTagStyle

    public init(_ text: String, style: CouliTagStyle = .outline) {
        self.text = text
        self.style = style
    }

    public var body: some View {
        let colors = style.colors
        HStack(spacing: CouliSpacing.s1) {
            if let icon = style.icon {
                CouliIconView(icon, size: CouliComponentMetric.iconSmall, relativeTo: .caption)
            }
            Text(verbatim: text)
                .couliFont(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(colors.text)
        .padding(.horizontal, CouliSpacing.s2)
        .padding(.vertical, CouliPendingTokenMetric.tagPaddingVertical)
        .frame(minHeight: CouliComponentMetric.tagMinHeight)
        .background(Capsule(style: .circular).fill(colors.background))
        .overlay(
            Capsule(style: .circular)
                .strokeBorder(colors.border ?? .clear, lineWidth: CouliComponentMetric.controlBorderWidth)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }
}

/// 平台来源标签（GUIDE §7.1、03 §10.2）：白底 + source 描边、中性文字；有包内官方图的平台在文字左侧加 14pt 图标
/// （F-X-05a，design/specs/app-home.md「14px 官方图标」；画板：左内边距 4、图文间距 4、右内边距 8）。
/// 暂缺图的平台、未知编码或不给编码时只显示文字（与原样式一致，不画占位）。名称由调用方给（平台字典），
/// 读屏整个标签只读这个名称一次，图标不单独可聚焦。`remoteURL` 给 F-X-05 预留，本任务一律用内置图。
public struct PlatformBadge: View {
    private let name: String
    private let platformCode: String?
    private let remoteURL: URL?

    public init(_ name: String, platformCode: String? = nil, remoteURL: URL? = nil) {
        self.name = name
        self.platformCode = platformCode
        self.remoteURL = remoteURL
    }

    public var body: some View {
        content
            .foregroundColor(CouliColor.token("source.text"))
            .frame(minHeight: CouliComponentMetric.badgeMinHeight)
            .background(Capsule().fill(CouliColor.token("source.background")))
            .overlay(
                Capsule().strokeBorder(
                    CouliColor.token("source.border"),
                    lineWidth: CouliComponentMetric.controlBorderWidth
                )
            )
            .fixedSize()
            // 读屏只有一个静态文字元素「平台名」（与改动前的纯文字标签一致）；图标与内部文字不再单独暴露。
            // 用 accessibilityRepresentation 而不是 accessibilityElement(children: .ignore)：后者在 XCUI 无障碍树里
            // 仍会把内部 Image / StaticText 挂成子节点。
            .accessibilityRepresentation { Text(verbatim: name) }
    }

    @ViewBuilder private var content: some View {
        if let code = platformCode, PlatformIcon.hasBuiltinImage(code) {
            HStack(spacing: CouliSpacing.s1) {
                PlatformIcon(platformCode: code, size: .badge, remoteURL: remoteURL)
                Text(verbatim: name)
                    .couliFont(.caption)
            }
            .padding(.leading, CouliSpacing.s1)
            .padding(.trailing, CouliSpacing.s2)
        } else {
            Text(verbatim: name)
                .couliFont(.caption)
                .padding(.horizontal, CouliSpacing.s2)
        }
    }
}

/// Agent 卡片的条件标记（BR-AI-24）；文字由调用方从字典给（agent.match.*）。
public struct MatchBadge: View {
    public enum Kind: Sendable {
        /// 符合条件。
        case matched
        /// 已放宽条件。
        case relaxed
        /// 规格待确认 / 标题显示为…
        case specUnconfirmed
    }

    private let text: String
    private let kind: Kind

    public init(_ text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    public var body: some View {
        switch kind {
        case .matched: CouliTag(text, style: .success)
        case .relaxed: CouliTag(text, style: .warning)
        case .specUnconfirmed: CouliTag(text, style: .neutralInfo)
        }
    }
}

/// AI 内容标识（BR-TEXT-16）；文字由调用方给（texts.ai_label）。
public struct AiLabel: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(verbatim: text)
            .couliFont(.caption, weight: .couliMedium)
            .foregroundColor(CouliColor.textSecondary)
            .padding(.horizontal, CouliSpacing.s2)
            .frame(minHeight: CouliComponentMetric.badgeMinHeight)
            .background(RoundedRectangle(cornerRadius: CouliRadius.small).fill(CouliColor.backgroundMuted))
            .fixedSize()
            .accessibilityLabel(Text(verbatim: text))
    }
}
