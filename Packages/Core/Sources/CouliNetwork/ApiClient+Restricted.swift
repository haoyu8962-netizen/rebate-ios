import Foundation
import Session

/// 登录触发的受限会话复查结果（APP-05a，三端对齐名 refresh_restricted）。
public enum RestrictedRecheck: String, Sendable, Equatable {
    /// 复查后是正常会话（刷新拿到 full）。
    case full
    /// 仍是受限会话（刷新仍回 deletion_only，或会话没有 refresh_token、刷新暂时失败：会话保留）。
    case restricted
    /// 会话已被清除（刷新被拒、等待期间会话被清）。
    case cleared
    /// 调用方已失效（登录尝试作废、Task 被取消）或会话已换代：不据此做任何路由动作。
    case cancelled
}

public extension ApiClient {
    /// 当前会话的作用域（经过会话隔离判断：隔离中、读取失败、没有会话时为 nil）。守卫的会话状态据此区分受限会话。
    var isolatedSessionScope: String? {
        withSessionLock {
            // 撤回禁读屏障竖着时不读令牌（r3f NEW-01）
            guard !readBarrier, let live = readSessionLocked().live, live.access != nil else {
                return nil
            }
            return live.scope ?? SessionScope.full
        }
    }

    /// 登录拿到 deletion_only 而本机强更结论为受支持时的显式复查（APP-05a 共性 4、10；harmony-review R1-04 / R2-02）：
    /// 存储的会话是 deletion_only 就并入本世代的单飞刷新窗口，按窗口的完整结果返回。`isValid` 是登录尝试的归属：
    /// 它登记为刷新窗口的调用方，调用方的 Task 被取消时立即结束等待；它是最后一个有效调用方时刷新请求一并取消。
    func recheckRestrictedSession(isValid: @escaping @Sendable () -> Bool) async -> RestrictedRecheck {
        let state = await readContext()
        guard isValid() else {
            return .cancelled
        }
        // 可读性、世代与读取在同一把锁里：禁读屏障 / 快照不可信 / 读取本身换代（损坏条目）→ 已失效，不据此路由（评审 r1 S2-1）
        guard let noted = readSessionNotingIsolation(state) else {
            return .cancelled
        }
        let bound = noted.generation
        guard let live = noted.read.live, let access = live.access, live.scope == SessionScope.deletionOnly,
              live.refresh != nil
        else {
            return Self.recheckWithoutRefresh(noted)
        }
        let outcome = await joinRefresh(generation: bound, usedToken: access, caller: isValid)
        guard isValid(), !Task.isCancelled else {
            return .cancelled
        }
        switch outcome {
        case .refreshed:
            return recheckAfterRefresh(state, bound)
        case .transient:
            return .restricted
        case .cleared:
            return .cleared
        case .superseded:
            return .cancelled
        }
    }
}

extension ApiClient {
    /// 刷新完成后的读取（APP-08 iOS r3f NEW-01）：同一把锁里先比较（快照仍可信、撤回禁读屏障已放下、会话世代未变）、再读取；
    /// 刷新等待期间撤回过同意 / 切过环境 / 换过会话的，零读取、按已失效结束。
    func recheckAfterRefresh(_ state: NetworkContext, _ bound: UInt64) -> RestrictedRecheck {
        let result: (SessionRead, Bool)? = withSessionLock {
            guard credentialsReadableLocked(state), generation == bound else {
                return nil
            }
            let isolated = revokedSession != nil
            let read = readSessionLocked()
            // 读取本身可能发现损坏条目而换代（D10-1716）：换过代就按已失效结束，不当成完整会话。
            return generation == bound ? (read, isolated) : nil
        }
        guard let (read, isolated) = result else {
            return .cancelled
        }
        // 读不出 → 留在受限（不放成 full），等可读后照常复查；确认没有会话或没有 access → cleared（D10-1718 ④ / D10-1909）
        switch read {
        case .unreadable:
            // 会话隔离中读不出：会话在逻辑上早已清除，按已清除（D10-1911 ①）
            return isolated ? .cleared : .restricted
        case .none:
            return .cleared
        case let .live(live):
            guard live.access != nil else {
                return .cleared
            }
            return live.scope == SessionScope.deletionOnly ? .restricted : .full
        }
    }

    /// 入口不需要刷新时的结论：读不出（锁屏读不了 Keychain 等）→ 会话可能仍在、不能确认已升级，留在受限、等可读后照常复查
    /// （D10-1718 ④ / D10-1909）；会话隔离中读不出按已清除（D10-1911 ①）；没有会话或没有 access → 已清除；
    /// 非 deletion_only → 完整；deletion_only 但没有 refresh_token → 受限（会话保留）。
    static func recheckWithoutRefresh(_ noted: NotedSessionRead) -> RestrictedRecheck {
        if noted.read == .unreadable {
            return noted.isolated ? .cleared : .restricted
        }
        guard let live = noted.read.live, live.access != nil else {
            return .cleared
        }
        return live.scope == SessionScope.deletionOnly ? .restricted : .full
    }

    /// 读取当前会话的结果，连同读取前是否处于会话隔离与读取时的会话世代（同一把锁里取得）。
    struct NotedSessionRead {
        let read: SessionRead
        let isolated: Bool
        let generation: UInt64
    }

    /// 同一把锁里：核对凭据可读，记下会话世代与读取前是否处于会话隔离（读取本身可能删掉隔离条目而解除隔离），再读取当前会话。
    /// 凭据不可读（撤回禁读屏障、快照不可信），或读取本身发现损坏条目而换代（D10-1716）→ nil（调用方按已失效结束）。
    func readSessionNotingIsolation(_ state: NetworkContext) -> NotedSessionRead? {
        withSessionLock {
            guard credentialsReadableLocked(state) else {
                return nil
            }
            let bound = generation
            let isolated = revokedSession != nil
            let read = readSessionLocked()
            return generation == bound ? NotedSessionRead(read: read, isolated: isolated, generation: bound) : nil
        }
    }

    /// 调用方持有 `lock`。会话丢失（刷新失败）的 Effect：以最近读到的强更状态为准（结算前刚读过）。
    /// 只在刚清过会话（`clearSessionLocked`）之后、同一把锁里调用：Effect 归属这次清理之后的会话世代（APP-05a 共性 26）。
    func sessionLostEffectLocked() -> ErrorEffect {
        var effect = lastUpdateSeen == UpdateRaw.below
            ? ErrorEffect(code: 10002, kind: .clearSessionStayForceUpdate, route: "ForceUpdate")
            : ErrorEffect(code: 10002, kind: .clearSessionLogin, route: "Login")
        effect.sessionGeneration = generation
        return effect
    }

    /// 调用方持有 `lock`。记下「这一代因刷新失败被清」（只留最近几代）。
    func recordRefreshFailureLocked(_ value: UInt64, _ effect: ErrorEffect) {
        refreshFailures[value] = effect
        while refreshFailures.count > Self.refreshFailureMemory, let oldest = refreshFailures.keys.min() {
            refreshFailures[oldest] = nil
        }
    }
}
