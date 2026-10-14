import Foundation

/// 提现记录列表的分区（BR-WDR-25，G30；iOS R2-05，APP-09 共性第 80 条）：按 withdrawal_id 定位的那张单单独成一个置顶区（独立标识），其余
/// 记录按 +08:00 下的月份分组；同一个月份只有一个分组（即使服务端顺序里不相邻），分区标识唯一且稳定（置顶区 `pinned`，月份 `month-YYYY-MM`）。
public struct RecordSection: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case pinned
        case month(year: Int, month: Int)
    }

    public let id: String
    public let kind: Kind
    public let items: [Withdrawal]
}

public enum RecordSections {
    public static let pinnedId = "pinned"

    public static func make(_ snapshot: RecordsSnapshot) -> [RecordSection] {
        make(items: snapshot.items, pinnedId: snapshot.pinnedId)
    }

    /// `pinnedId` 的单（在列表里时）放进置顶区；其余按月份分组，保持服务端顺序，月份按首次出现的位置排列。
    public static func make(items: [Withdrawal], pinnedId: String?) -> [RecordSection] {
        var out: [RecordSection] = []
        var rest = items
        if let pinnedId, let index = rest.firstIndex(where: { $0.withdrawalId == pinnedId }) {
            out.append(RecordSection(id: Self.pinnedId, kind: .pinned, items: [rest.remove(at: index)]))
        }
        var order: [String] = []
        var groups: [String: (kind: RecordSection.Kind, items: [Withdrawal])] = [:]
        for item in rest {
            let parts = WalletClock.parts(item.createdAtMillis)
            let year = parts.year ?? 0
            let month = parts.month ?? 0
            let id = String(format: "month-%04d-%02d", year, month)
            if groups[id] == nil {
                order.append(id)
                groups[id] = (.month(year: year, month: month), [])
            }
            groups[id]?.items.append(item)
        }
        for id in order {
            guard let group = groups[id] else { continue }
            out.append(RecordSection(id: id, kind: group.kind, items: group.items))
        }
        return out
    }
}
