import CouliNetwork
import Foundation

/// 条件、搜索框与用户接管（OrderListController 的一部分）。
public extension OrderListController {
    // MARK: - 条件（42901 禁用期内一律不改，返回 false）

    @discardableResult
    func setScope(_ scope: String) -> Bool {
        change { $0.setScope(scope) }
    }

    @discardableResult
    func setGroup(_ group: String) -> Bool {
        change { $0.setGroup(group) }
    }

    @discardableResult
    func setPlatform(_ platform: String?) -> Bool {
        change { $0.setPlatform(platform) }
    }

    @discardableResult
    func setMonth(_ month: String?) -> Bool {
        change { $0.setMonth(month) }
    }

    /// 搜索框输入（只改文字，不发请求；超过 40 个码点截掉）。
    func updateSearchText(_ text: String) {
        let limited = OrderQuery.limit(text)
        guard limited != snapshot.searchText else { return }
        snapshot.searchText = limited
        // 用户接管（RW-01）：之后换上身份重建页面时保留这次输入，不用磁盘旧条件覆盖
        userTookOver = true
    }

    /// 键盘「搜索」：按规整后的搜索词开新一轮（与当前相同也重新查）。
    @discardableResult
    func submitSearch() -> Bool {
        let text = snapshot.searchText
        return change { $0.setQ(text) }
    }

    /// 清空搜索框：有搜索词时开新一轮。
    @discardableResult
    func clearSearch() -> Bool {
        guard !gate.active, !left else { return false }
        snapshot.searchText = ""
        guard snapshot.query.keyword != nil else { return true }
        return change { $0.setQ(nil) }
    }

    /// 条件变化（切子 Tab、筛选、提交搜索）。身份暂时未知时照样受理（记为用户接管、条件生效），只是不发请求：记待补取并结算，请 App
    /// 立即核对一次；确认后按这份条件补取（未知期间构造的页面换上身份时由 App 带到新页面，旧恢复记录不再覆盖，RW-01）。
    internal func change(_ mutate: (inout OrderQuery) -> Void) -> Bool {
        guard !gate.active, !left else { return false }
        let check = ownerCheck
        guard check != .stale else { return false }
        let before = snapshot.query
        var query = before
        mutate(&query)
        snapshot.query = query
        if query.scope != before.scope {
            // 切子 Tab：搜索框一并清空（BR-TEXT-02 细则）
            snapshot.searchText = ""
        } else if query.keyword != before.keyword || query.keyword != nil {
            snapshot.searchText = query.keyword ?? ""
        }
        userTookOver = true
        guard check == .current else {
            // 新条件下没有结果：旧结果不留着冒充新条件的
            snapshot.items = []
            _ = admitFirst(check)
            env?.recheckIdentity()
            return true
        }
        load(keepItems: false)
        return true
    }
}
