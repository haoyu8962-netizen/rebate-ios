import Foundation

/// 冷静期卡片的徽标与标题用哪个文案键（D10-2126 ②，三端同口径）：
/// 可撤回时是「冷静期中」+「注销申请已提交」；can_cancel=false 时状态停在注销处理，改用时间线的「注销处理」一组键，不新造句。
public struct DeletionCoolingHead: Equatable, Sendable {
    public let badgeKey: String
    public let titleKey: String
    /// 标题键带 {process_workdays} 占位时为 true（页面用 format 渲染）。
    public let titleNeedsWorkdays: Bool

    public static func of(showCancel: Bool) -> DeletionCoolingHead {
        showCancel
            ? DeletionCoolingHead(
                badgeKey: "deletion.cooling.badge", titleKey: "deletion.cooling.title", titleNeedsWorkdays: false
            )
            : DeletionCoolingHead(
                badgeKey: "deletion.timeline.processing", titleKey: "deletion.timeline.processing_desc",
                titleNeedsWorkdays: true
            )
    }
}
