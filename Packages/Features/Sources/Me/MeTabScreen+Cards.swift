import DesignSystem
import MeCore
import SwiftUI

/// 「我的」页的宫格（设计稿 Me、MeEarningsEntry、MeGuest）：每组一张白卡，上 16 / 左右下 8、标题 17/600 左缩进 8、标题到格子 4。
extension MeTabBody {
    func grid(_ view: MeViewModel, _ actions: MeTabActions) -> some View {
        let groups = [MeView.groupOrders, MeView.groupPromo, MeView.groupMore]
        return ForEach(groups, id: \.self) { group in
            let cells = view.grid.filter { $0.group == group }
            let items = cells.compactMap { cell -> EntryGridItem? in
                guard let key = MeDraftTexts.gridKey(cell.item) else { return nil }
                return EntryGridItem(id: cell.item, title: texts.text(key), icon: Self.icon(key),
                                     accessibilityIdentifier: MeDraftTexts.gridIdentifier(cell.item))
            }
            if !items.isEmpty {
                EntryGrid(
                    title: texts.text("me.group.\(group)"), items: items, eager: true,
                    contentInsets: EdgeInsets(top: CouliSpacing.s4, leading: CouliSpacing.s2,
                                              bottom: CouliSpacing.s2, trailing: CouliSpacing.s2),
                    titleInset: CouliSpacing.s2, titleSpacing: CouliSpacing.s1,
                    probeID: "me.grid.\(group)", cellProbePrefix: "me.cell"
                ) { item in
                    if let cell = cells.first(where: { $0.item == item.id }) {
                        actions.tap(cell)
                    }
                }
                .id("me.section.\(group)")
                .background(MeSectionTops.reader("me.section.\(group)"))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("me.grid.\(group)")
            }
        }
    }

    static func icon(_ key: String) -> CouliIcon {
        switch key {
        case "me.grid.orders": .orders
        case "me.grid.wallet": .wallet
        case "me.grid.ledger": .ledger
        case "me.grid.find_order": .claim
        case "me.grid.invite": .invite
        case "me.grid.earnings": .barChart
        case "me.grid.help": .help
        case "me.grid.cs": .headset
        case "me.grid.auth": .link
        default: .settings
        }
    }
}
