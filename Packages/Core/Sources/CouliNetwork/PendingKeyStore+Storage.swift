import Foundation

/// 未决记录的读写：覆盖层优先读；先持久化、成功后再改内存（lessons 32）。调用方持有 `lock`。
/// 读失败或记录损坏一律抛错（R1-07），不当成没有记录；`known` 是本进程最近一次确认过的持久内容，只在结算本进程
/// 自己持有的占用时兜底（读不出来也要把在途请求的结果记下来），不用来放行新的提交。
extension PendingKeyStore {
    // MARK: - 读（覆盖层优先）

    func read(_ owner: String, _ key: String) throws -> PendingKeyRecord? {
        let slot = Self.slot(owner, key)
        if pendingDeletes.contains(slot) {
            return nil
        }
        if let pending = overlay[slot] {
            return pending
        }
        let record = try backend.load(account: owner, key: key)
        known[slot] = record
        return record
    }

    /// 读不出来时退回本进程最近确认过的内容（只给结算、释放本进程的占用用）。
    func readForSettlement(_ owner: String, _ key: String) -> PendingKeyRecord? {
        do {
            return try read(owner, key)
        } catch {
            let slot = Self.slot(owner, key)
            return overlay[slot] ?? known[slot]
        }
    }

    func list(_ owner: String) throws -> [PendingKeyRecord] {
        try backend.loadAll(account: owner).compactMap { record in
            let slot = Self.slot(owner, record.key)
            if pendingDeletes.contains(slot) {
                return nil
            }
            known[slot] = record
            return overlay[slot] ?? record
        }
    }

    /// 先写后改内存：写成功清掉覆盖层；写失败返回 false（内存状态由调用方决定）。
    func persist(_ record: PendingKeyRecord) -> Bool {
        do {
            try backend.write(record)
        } catch {
            return false
        }
        let slot = Self.slot(record.account, record.key)
        overlay[slot] = nil
        known[slot] = record
        return true
    }

    /// 写回 unknown：写不进去时内存里仍按 unknown（覆盖层），返回 false。
    func persistUnknown(_ record: PendingKeyRecord) -> Bool {
        if persist(record) {
            return true
        }
        overlay[Self.slot(record.account, record.key)] = record
        return false
    }

    func remove(_ owner: String, _ key: String) -> Bool {
        let slot = Self.slot(owner, key)
        overlay[slot] = nil
        do {
            try backend.delete(account: owner, key: key)
            pendingDeletes.remove(slot)
            known[slot] = nil
            return true
        } catch {
            pendingDeletes.insert(slot)
            return false
        }
    }
}
