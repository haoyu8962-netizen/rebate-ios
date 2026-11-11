import DesignSystem
import HomeCore
import SwiftUI
import UIKit

/// 首页视觉层的纯展示规则（APP-11v）。只决定怎么画，不改 SDUI 判定、数据源与路由（G26）；页面视图都经这里取结论。
@MainActor
enum HomeVisualRules {
    /// 游客价值卡：游客与基本模式显示，已登录不显示（登录后随身份立即消失，不等会员页面返回）。
    static func showsGuestValue(level: HomeLevel) -> Bool {
        level != .member
    }

    /// 首页弹窗的读屏名（spec §6 默认「首页弹窗」；契约 `alt` 未进锁，G-V07）：取草稿键，不在视图里写死。
    static var popupAccessibilityName: String {
        HomeText.text("home.popup.name")
    }

    /// 常驻粘贴卡按钮用的系统控件（BR-ID-16：iOS 用 UIPasteControl）。
    static var pasteControlKind: String {
        String(describing: UIPasteControl.self)
    }

    /// 网格 / 信息流的列数：最多 2 列；按卡上最宽的不可拆金额段所需宽度，两列放不下时整组改单列（03 §10.4）。
    static func gridColumns(availableWidth: CGFloat, requiredItemWidth: CGFloat, spacing: CGFloat) -> Int {
        (availableWidth - spacing) / 2 >= requiredItemWidth ? 2 : 1
    }

    /// 金刚区列数（FU-IOS-ADAPT-CHECK ③）：按 props 的列数，但每格至少放得下格名前两个字（格名 caption 12 随字号缩放、苹方）；
    /// 大字号下放不下就减列（5 → 4 → 3 …），格名不缩字、不逐字竖排。常规字号下列数不变。
    static func iconColumns(_ columns: Int, availableWidth: CGFloat, titles: [String], size: DynamicTypeSize,
                            spacing: CGFloat) -> Int {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let fontSize = UIFontMetrics(forTextStyle: .caption1).scaledValue(for: CouliTextStyle.caption.baseSize,
                                                                          compatibleWith: traits)
        let font = UIFont(name: "PingFangSC-Regular", size: fontSize) ?? UIFont.systemFont(ofSize: fontSize)
        let pair = titles.map { (String($0.prefix(2)) as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        var count = max(1, columns)
        while count > 1, (availableWidth - spacing * CGFloat(count - 1)) / CGFloat(count) < pair + 1 {
            count -= 1
        }
        return count
    }

    /// 横滑卡整卡读屏名：平台、标题、主价、返利（可见层不显示标题与来源，读屏仍完整读出）。
    static func scrollAccessibilityLabel(_ data: ProductCardData) -> String {
        var parts = [data.platformName, data.title, data.price.mainAccessibilityText]
        parts.append(data.rebate.hidingAmount(data.amountHidden).accessibilityText)
        return parts.filter { !$0.isEmpty }.joined(separator: PriceTerms.spokenPause)
    }

    /// 金刚区平台格（SDUI icon 项）的图来源：有下发图且没失败 → `remote`；否则有包内官方图 → `builtin`；再否则 → `text`（文字兜底）。
    /// 后台替换图（`/config.platform_icons`）不在本任务（F-X-05），这里只看 SDUI 项自身的图。
    static func platformIconSource(code: String, hasRemoteImage: Bool, remoteFailed: Bool) -> String {
        if hasRemoteImage, !remoteFailed {
            return "remote"
        }
        return PlatformIcon.hasBuiltinImage(code) ? "builtin" : "text"
    }
}

/// 游客价值卡（HomeGuest-v3；BR-TEXT-14 表 C `home.guest_value.*`）：白卡，左「下单前先在凑狸查返利」17/600，右【登录领返利】浅底次按钮。
/// 只对游客 / 基本模式（`HomeVisualRules.showsGuestValue`），不做关闭、无金额；点按钮由调用方经 Router 打开 Login。
public struct HomeGuestValueCard: View {
    private let level: HomeLevel
    private let text: (String) -> String
    private let onLogin: () -> Void

    public init(level: HomeLevel, text: @escaping (String) -> String, onLogin: @escaping () -> Void) {
        self.level = level
        self.text = text
        self.onLogin = onLogin
    }

    public var body: some View {
        if HomeVisualRules.showsGuestValue(level: level) {
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s3, verticalSpacing: CouliSpacing.s2) {
                Text(verbatim: text("home.guest_value.desc"))
                    .couliFont(.body, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .couliLineBox(.body)
                HomeTonalButton(title: text("home.guest_value.login"), probeID: "home.guest.login", action: onLogin)
                    .couliFlowPushTrailing(.always)
            }
            .padding(.vertical, CouliSpacing.s3)
            .padding(.leading, CouliSpacing.s4)
            .padding(.trailing, CouliSpacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                    .fill(CouliColor.backgroundSurface)
                    .couliShadow(.card)
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.guest.value")
        }
    }
}

/// 浅底次按钮（Main-v3【问 AI】【登录领返利】）：brand.subtle 底、brand.emphasis 字 14/600、圆角 12、最小高 44；可带一个 20 图标。
/// 文字是不可拆的一段（放不下时整块换行，不截断、不缩字）。
public struct HomeTonalButton: View {
    private let title: String
    private let icon: CouliIcon?
    private let probeID: String
    private let action: () -> Void

    /// - Parameter probeID: 可访问标识兼布局测量编号（`home.askAI`、`home.guest.login`）。
    public init(title: String, icon: CouliIcon? = nil, probeID: String, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.probeID = probeID
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: CouliSpacing.s1) {
                if let icon {
                    CouliIconView(icon, size: 20, relativeTo: .footnote)
                }
                CouliUnbreakableText(title, size: CouliTextStyle.footnote.baseSize, weight: .couliSemibold,
                                     relativeTo: .footnote, monospacedDigits: false,
                                     probeID: probeID + ".label", role: "button-label")
            }
            .foregroundColor(CouliColor.brandEmphasis)
            .padding(.horizontal, icon == nil ? CouliSpacing.s4 : CouliSpacing.s3)
            // 命中区下限 44 再留 1pt：所在行可能落在非整像素位置，量出来的高度不会因浮点舍入低于 44
            .frame(minHeight: CouliHitTarget.minimum + 1)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous).fill(CouliColor.brandSubtle)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityIdentifier(probeID)
        .couliProbe(probeID, role: "independent-hit")
    }
}
