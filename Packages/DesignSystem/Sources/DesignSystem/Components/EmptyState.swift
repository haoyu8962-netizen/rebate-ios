import SwiftUI

// MARK: - EmptyState

/// 空态的疏密档（APP-08v v5 跟进：放不下时先去插图、再压上下留白；标题、说明与按钮始终保留）。缺省 `.regular`（既有空态不变）。
public enum EmptyStateDensity: Int, Sendable, CaseIterable {
    /// 完整：96 插图块 + 上下留白 32。
    case regular
    /// 去掉插图块，上下留白仍 32。
    case noIllustration
    /// 去掉插图块，上下留白压到 12。
    case compact
}

/// 空态（GUIDE §3「空态 / 错误态」）：96 占位块 + 32 图标 → 说明 17/600 → 辅助 14 → 一个按钮（可省）。
public struct EmptyState: View {
    private let icon: CouliIcon
    private let title: String
    private let message: String?
    private let actionTitle: String?
    private let actionKind: CouliButtonKind
    private let density: EmptyStateDensity
    private let iconProbeID: String?
    private let action: () -> Void

    /// - Parameters:
    ///   - actionKind: 按钮外观，缺省描边次按钮（既有空态不变）；订单空态画板为实心主按钮（APP-08v OrdersEmpty）。
    ///   - density: 疏密档，缺省完整（既有空态不变）。
    ///   - iconProbeID: 图标的测量编号（APP-09v-b 提现记录空态）；缺省 nil 不量、外观不变。
    public init(
        icon: CouliIcon = .search,
        title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        actionKind: CouliButtonKind = .secondary,
        density: EmptyStateDensity = .regular,
        iconProbeID: String? = nil,
        action: @escaping () -> Void = {}
    ) {
        self.iconProbeID = iconProbeID
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.actionKind = actionKind
        self.density = density
        self.action = action
    }

    public var body: some View {
        StateLayout(icon: icon, title: title, message: message, actionTitle: actionTitle, actionKind: actionKind,
                    showsIllustration: density == .regular,
                    verticalPadding: density == .compact ? CouliSpacing.s3 : CouliSpacing.s8, iconProbeID: iconProbeID,
                    action: action)
    }
}
