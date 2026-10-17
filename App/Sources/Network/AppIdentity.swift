import CouliNetwork
import Foundation

/// 页面固定身份里核对要用的三项（版本串、账号、构造时是否已确认）。
struct FixedIdentity {
    let key: String
    let account: String?
    let known: Bool
}

/// 订单与钱包共用的身份快照入口（FU-IOS-0712 整体重理）：凭据可读性与会话在同一时刻一次取得（`ApiClient.identitySnapshot`）；判据、
/// 对账、页面固定身份与页面核对都只经这里取。建页期间可钉住一份快照（`pinning`），执行器构造、恢复决策与建页时的核对都用这同一份。
@MainActor
final class AppIdentity {
    private let client: ApiClient
    /// 撤回同意的清理已完成、会话凭据可读（生产为 `PrivacyWithdrawalCleanup.runner`；测试注入）。只读内存标记。
    let credentialsReadable: @MainActor () -> Bool
    private var pinned: IdentitySnapshot?

    init(client: ApiClient, credentialsReadable: @escaping @MainActor () -> Bool) {
        self.client = client
        self.credentialsReadable = credentialsReadable
    }

    /// 此刻的身份快照（一次读取）；建页期间返回钉住的那一份。
    func snapshot() -> IdentitySnapshot {
        pinned ?? client.identitySnapshot(credentialsReadable: credentialsReadable())
    }

    /// 同步建页期间钉住一份快照（执行器构造时取的固定身份、恢复决策、构造期间的核对都是这一次读取）。
    func pinning<T>(_ snapshot: IdentitySnapshot, _ body: () -> T) -> T {
        let previous = pinned
        pinned = snapshot
        defer { pinned = previous }
        return body()
    }

    /// 固定身份的版本串（账号 + 会话世代 + 作废世代 + 清理次数；撤回清理进行中另加标记）。订单、钱包同一口径。
    static func ownerKey(account: String?, _ snapshot: IdentitySnapshot, cleared: Int) -> String {
        let key = "\(account ?? "-")#\(snapshot.generation)#\(snapshot.epoch)#\(cleared)"
        return snapshot.readable ? key : key + "#withdrawing"
    }

    /// 固定身份与此刻快照的核对（订单、钱包同一口径）：
    /// - 此刻身份已确认、且与按此刻快照构造的身份相同（凭据可读）→ 仍是当前；
    /// - 否则，凭据可读、会话 / 作废世代与清理次数都没变，并且「此刻身份暂时未知」或「页面构造时身份未确认」→ 暂时未知（页面记待补做，
    ///   身份确认后统一补做 / 换上身份）；
    /// - 其余（换代、撤回、切环境、同账号换登录世代）→ 已作废。
    static func check(
        matchesNow: Bool, fixed: FixedIdentity, now: IdentitySnapshot, cleared: Int
    ) -> IdentityCheck {
        // 「当前」必须是已确认的身份（RW-01）：两份都未确认的身份即使相同也只是暂时未知
        if now.readable, now.known, matchesNow {
            return .current
        }
        guard now.readable, ownerKey(account: fixed.account, now, cleared: cleared) == fixed.key,
              !now.known || !fixed.known
        else { return .stale }
        return .unknown
    }
}
