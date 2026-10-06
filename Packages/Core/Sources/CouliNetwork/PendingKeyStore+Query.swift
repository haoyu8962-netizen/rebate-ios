import Foundation

/// 未决记录的查询（读不出来与没有记录分开，R1-07）。
public extension PendingKeyStore {
    /// 指定账号下一个键的状态（管线按占用时的账号查询）。
    internal func state(key: String, account owner: String) -> PendingKeyState {
        lock.withLock {
            let record: PendingKeyRecord?
            do {
                record = try read(owner, key)
            } catch {
                // 本进程自己持有的记录按最近确认过的内容；否则如实报告读不出来。
                if let cached = overlay[Self.slot(owner, key)] ?? known[Self.slot(owner, key)] {
                    return PendingKeyState(stateRaw: cached.stateRaw, record: cached)
                }
                return PendingKeyState(stateRaw: Self.unreadable, record: nil)
            }
            if let record {
                return PendingKeyState(stateRaw: record.stateRaw, record: record)
            }
            return PendingKeyState(stateRaw: finished.contains(key) ? Self.done : Self.none, record: nil)
        }
    }

    func state(key: String) -> PendingKeyState {
        lock.withLock {
            guard let current = account else {
                return PendingKeyState(stateRaw: finished.contains(key) ? Self.done : Self.none, record: nil)
            }
            return state(key: key, account: current)
        }
    }

    /// 当前账号某个操作的未决记录（发起页据此进入待确认）。读不出来时为 nil；要区分请用 `lookup(operationId:)`。
    func pendingFor(operationId: String) -> PendingKeyRecord? {
        if case let .record(record) = lookup(operationId: operationId) {
            return record
        }
        return nil
    }

    /// 当前账号某个操作的未决状态：没有、有记录、读不出来（不能当成没有）。
    func lookup(operationId: String) -> PendingLookup {
        lock.withLock {
            guard let current = account else {
                return .none
            }
            do {
                return try list(current).first { $0.operationId == operationId }.map { .record($0) } ?? .none
            } catch {
                return .unreadable
            }
        }
    }
}

/// 未决记录查询的结果：读不出来与没有记录分开（R1-07）。
public enum PendingLookup: Sendable, Equatable {
    case none
    case record(PendingKeyRecord)
    /// 安全存储读失败或记录损坏：无法确认，发起页不得放行新的提交。
    case unreadable
}
