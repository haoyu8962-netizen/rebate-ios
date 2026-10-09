import Combine
import Foundation

/// 搜索历史（SearchTyping 画板）：只在本进程内保存（新的在前、去重、最多 10 条），不落盘。
/// TODO(N-27)：历史是否持久化、条数上限、隐私撤回时是否清除未规定；保守处理为不落盘。
@MainActor
public final class SearchHistory: ObservableObject {
    public static let limit = 10

    @Published public private(set) var keywords: [String] = []

    public init() {}

    public func record(_ keyword: String) {
        let normalized = SearchQuery.normalizeKeyword(keyword)
        guard !normalized.isEmpty else { return }
        keywords.removeAll { $0 == normalized }
        keywords.insert(normalized, at: 0)
        if keywords.count > Self.limit {
            keywords.removeLast(keywords.count - Self.limit)
        }
    }

    public func clear() {
        keywords = []
    }
}
