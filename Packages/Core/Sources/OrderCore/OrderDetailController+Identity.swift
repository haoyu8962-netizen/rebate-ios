import CouliNetwork
import Foundation

/// 订单详情的身份核对与恢复（FU-IOS-0712 整体重理：与列表、钱包、各资金页同一套机制）。
extension OrderDetailController: IdentityResumable {
    /// 固定身份与此刻身份的核对结论（一次读取）。
    public var ownerCheck: IdentityCheck {
        guard let env else { return .stale }
        return env.check(owner)
    }

    /// 读取的身份核对：暂时未知 → 记待补取（身份确认后 `reloadAfterIdentity`）、在途标记复位、没有内容时进可重试的失败态。
    func admitLoad(_ check: IdentityCheck) -> Bool {
        deferral.admit(check, slot: Self.loadSlot, resume: { [weak self] in self?.reloadAfterIdentity() }, settle: {
            snapshot.refreshing = false
            if snapshot.detail == nil {
                snapshot.error = nil
                snapshot.phase = .error
            }
        })
    }

    /// 身份确认后补取（已显示的内容保留）。
    func reloadAfterIdentity() {
        guard !left, !cleared, admitLoad(ownerCheck) else { return }
        load(keep: snapshot.detail != nil)
    }

    /// 用户入口（【重试】、下拉）的身份核对：暂时未知时记待补取并请 App 立即核对一次身份；已换代不受理。
    func admitUser() -> Bool {
        let check = ownerCheck
        guard check == .unknown else { return check == .current }
        _ = admitLoad(check)
        env?.recheckIdentity()
        return false
    }

    /// 身份确认之后（App 的会话核对，判据相同也调）：补做因身份暂时未知中止的读取。
    public func resumeAfterIdentityConfirmed() {
        guard !left, !cleared else { return }
        deferral.resume()
    }

    /// 构造时身份未确认的页面，在身份确认后换上这一次已确认的身份（App 在同一次核对里给），作废旧请求；页面出现过就按新身份加载。
    /// 构造时已确认且有账号的页面不换（固定身份只比较，换代由 App 清空并移出）。
    public func identityConfirmed(_ confirmed: OrderOwner) {
        guard !left, !cleared, !owner.identityKnown || owner.account == nil, confirmed.identityKnown, confirmed != owner
        else { return }
        owner = confirmed
        requests.cancelAll()
        seq += 1
        deferral.reset()
        snapshot.refreshing = false
        guard started else { return }
        reloadAfterIdentity()
    }
}
