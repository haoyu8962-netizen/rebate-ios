import DesignSystem
import Generated
import Home
import HomeCore
import Privacy
import Router
import SwiftUI

/// 首页原生头部（APP-11v G-V02；不属 SDUI，G26 行为不变）：作为首页列表的首项，与 SDUI 卡同一条纵向滚动、同一列宽。
/// - 已同意：剪贴板提示条（商品 / 邀请）→ 本页粘贴结果 → 游客价值卡（只游客）→ 常驻粘贴卡；
/// - 基本模式：基本模式提示条 → 游客价值卡（基本模式同游客底稿）；不画粘贴卡（基本模式不读剪贴板）。
/// 由 RootView 组装（它持有剪贴板、隐私、Router），经环境值交给 HomeRouteView 放进 HomeSduiScreen 的 header 槽。
struct HomeNativeHeader: View {
    @ObservedObject var home: AppHome
    @ObservedObject var clipboard: AppClipboard
    let basic: Bool
    let onLogin: () -> Void
    let onEnableFull: () -> Void

    var body: some View {
        let guest = HomeGuestValueCard(level: home.controller.identity.level, text: home.controller.text,
                                       onLogin: onLogin)
        if basic {
            VStack(spacing: CouliSpacing.s3) {
                BasicModeNotice(onEnableFull: onEnableFull)
                guest
            }
        } else {
            HomeClipboardArea(clipboard: clipboard) { guest }
        }
    }
}

extension EnvironmentValues {
    /// 首页原生头部（nil 时首页列表没有头部，如只装配首页路由的单测宿主）。
    @Entry var homeNativeHeader: AnyView?
}

/// 首页顶部吸顶的搜索行（G-V02：不随列表滚动）：左搜索入口（按钮语义）+ 右【问 AI】浅底次按钮（经 Router 打开 AgentChat）。
/// iOS 尚无 AI 入口开关（APP-10 未做，`agent.entry.visible` 未接），【问 AI】常显。内容列限宽 600 居中（与列表同一列）。
struct HomeSearchRow: View {
    let onSearch: () -> Void
    let onAskAI: () -> Void
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        // 辅助字号档（≥ AX1）时重新排布：搜索入口独占一行，【问 AI】换到下一行靠右，两者都按大字号显示，不再挤在同一行里逐字折行
        let layout = size.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: CouliSpacing.s2))
            : AnyLayout(HStackLayout(spacing: CouliSpacing.s2))
        layout {
            HomeSearchEntry(identifier: "home.search", onSearch: onSearch)
                .frame(maxWidth: .infinity)
            HomeTonalButton(title: HomeDraftTexts.text("home.search.ask_ai", [:]), icon: .chat, probeID: "home.askAI",
                            action: onAskAI)
                .fixedSize()
                .accessibilityShowsLargeContentViewer()
        }
        .frame(maxWidth: HomeSearchRow.maxColumn)
        .couliProbe("home.column.search", role: "column")
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.vertical, CouliSpacing.s2)
        .frame(maxWidth: .infinity)
        // 吸顶栏按内容定高、不被下方列表压缩（否则文字溢出框外）。字号跟随到 AX3（正文约 235%、脚注约 254%，满足 03 §10.4「跟随到
        // 200%」），更大的辅助档按 03 §10.4「超过 200%：导航元素封顶在约 200%，长按用系统大内容查看器」处理：不再继续放大，
        // 长按搜索入口 /【问 AI】显示大内容查看器
        .dynamicTypeSize(...Self.maxTypeSize)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 内容列最大宽度（03 §10.4；与首页列表、搜索页同一取值）。
    static let maxColumn: CGFloat = 600
    /// 吸顶搜索行的字号上限（首页与基本模式同一取值）：AX3，正文 17→40（约 235%），超过 200% 的更大档封顶并提供大内容查看器。
    static let maxTypeSize = DynamicTypeSize.accessibility3
}

/// 首页 / 基本模式的搜索入口（Main-v3：按钮语义的假输入框）：20 搜索图标 + 占位「搜商品名，或粘贴商品链接」17 次要色（G-V09 草稿键
/// `search.placeholder`，首页与基本模式同键）；surface 底、控件边 1、圆角 12、最小高 44。占位折行不截断。
struct HomeSearchEntry: View {
    let identifier: String
    let onSearch: () -> Void
    /// 占位文字实际字号（与 `couliFont(.body)` 同一缩放曲线；受所在搜索行的字号上限约束）。
    @ScaledMetric(relativeTo: .body) private var fontSize = CouliTextStyle.body.baseSize
    private var placeholder: String {
        HomeDraftTexts.text("search.placeholder", [:])
    }

    var body: some View {
        Button(action: onSearch) {
            HStack(spacing: CouliSpacing.s2) {
                CouliIconView(.search, size: 20)
                Text(verbatim: placeholder)
                    .couliFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .couliTextProbe(identifier + ".label", role: "search-label", text: placeholder,
                                    fontSize: fontSize, baseFontSize: CouliTextStyle.body.baseSize)
                Spacer(minLength: 0)
            }
            .foregroundColor(CouliColor.textSecondary)
            .padding(.vertical, CouliSpacing.s2)
            .padding(.horizontal, CouliSpacing.s3)
            .frame(minHeight: CouliHitTarget.minimum)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .fill(CouliColor.backgroundSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .stroke(CouliColor.borderControl, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityShowsLargeContentViewer()
        .couliProbe(identifier, role: "independent-hit")
    }
}

/// 基本模式提示条（设计稿 BasicMode）：品牌浅底、圆角 16、内边距 16；信息图标 + `privacy.basic_mode.notice`，下面整行【开启完整功能】。
/// APP-11v 起作为基本模式首页列表的头部项（与游客底稿同一列宽、同一滚动）。
struct BasicModeNotice: View {
    let onEnableFull: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                CouliIconView(.info, size: 20, relativeTo: .footnote)
                    .foregroundColor(CouliColor.brandEmphasis)
                Text(verbatim: DefaultTexts.text("privacy.basic_mode.notice") ?? "")
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("basic.notice")
            }
            CouliButton(
                DefaultTexts.text("privacy.basic_mode.enable") ?? "",
                kind: .primary,
                size: .compact,
                fillsWidth: true,
                action: onEnableFull
            )
            .accessibilityIdentifier("basic.enableFull")
        }
        .padding(CouliSpacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(CouliColor.brandSubtle)
        )
    }
}
