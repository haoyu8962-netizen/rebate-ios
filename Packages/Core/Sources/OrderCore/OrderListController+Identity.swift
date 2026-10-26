import CouliNetwork
import Foundation

/// 订单列表的身份核对与恢复（FU-IOS-0712 整体重理：与详情、钱包、各资金页同一套机制）。
extension OrderListController: IdentityResumable {
    /// 固定身份与此刻身份的核对结论（一次读取）。
    public var ownerCheck: IdentityCheck {
        guard let env else { return .stale }
        return env.check(owner)
    }

    /// 第一页（新一轮）的身份核对：暂时未知 → 记待补取（身份确认后 `reloadFirst`）、结算；已换代 → 不放行。
    func admitFirst(_ check: IdentityCheck) -> Bool {
        deferral.admit(check, slot: Slot.first, resume: { [weak self] in self?.reloadFirst() }, settle: {
            settleIdentityPending()
        })
    }

    /// 身份确认后补取第一页（同一查询轮次：恢复任务不因此取消）；已有结果的保留显示。
    func reloadFirst() {
        guard !left, admitFirst(ownerCheck) else { return }
        load(keepItems: !snapshot.items.isEmpty && [.content, .stale].contains(snapshot.phase))
    }

    /// 读取因身份暂时未知中止的结算：在途标记复位；没有结果时进「加载失败」+【重试】（不是没有出口的骨架）。
    func settleIdentityPending() {
        snapshot.refreshing = false
        snapshot.loadingMore = false
        snapshot.identityPending = true
        guard snapshot.items.isEmpty else { return }
        snapshot.nextCursor = nil
        snapshot.error = nil
        // 整页错误态不置顶（G-O04；APP-08v-a 评审 r1 S2-1：身份未知时下拉刷新空列表 / 切分享）
        snapshot.claimPinned = false
        snapshot.phase = .error
    }

    /// 用户入口（下拉、【重试】、筛选、搜索）的身份核对：暂时未知时记待补取、结算，并请 App 立即核对一次身份（未知期间构造的页面由
    /// App 换上身份）；已换代不受理。
    func admitUser() -> Bool {
        let check = ownerCheck
        guard check == .unknown else { return check == .current }
        _ = admitFirst(check)
        env?.recheckIdentity()
        return false
    }

    /// 身份确认之后（App 的会话核对，判据相同也调）：补做因身份暂时未知中止的第一页、翻页与恢复对齐（FU-IOS-0712 整体重理）。
    public func resumeAfterIdentityConfirmed() {
        guard !left else { return }
        deferral.resume()
    }
}
