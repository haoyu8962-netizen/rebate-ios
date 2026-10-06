import Foundation
import Generated

/// 未决键的状态与存储（BR-ID-10 细则「敏感操作的幂等键」；03 §4.2「未决键」）。只做存储与状态，页面在 APP-09。
///
/// - `beforeSend`：四个 step-up 操作首次发送前写入 in_flight 记录（写不进去返回 false，不得发送）；当前账号同一操作
///   已有在途或结果未知的键时拒绝新的提交（不得换新键）。其他操作不建记录，直接放行。
/// - `onResponse`：没有统一外壳（超时、断连、网关错误页、进程被杀）→ unknown；拿到业务结果（成功、3xxxx，含作废接口
///   带回的原结果）或已作废（abandoned、20903）→ 结束并删除记录；其余（10001/10003/10004/10005、20903 以外的 2xxxx、
///   10405、40901、42901、5xxxx 等）出现过结果未知的保持待确认，从未结果未知的删除记录。
/// - `confirm` / `abandon`：只在 unknown 时由用户点击开始（置为 in_flight），两者在途时都不能再点；abandon 不是本地删除。
/// - `release`：确认或作废的请求在本地被拒绝、发送前出错时调用：in_flight 恢复为 unknown（从未发出的新记录直接删除）。
/// - `coldStart`：进程启动、登录成功、回前台时调用，只恢复该账号的记录。只有不属于本进程在途调用的 in_flight
///   （上个进程遗留）才改为 unknown；本进程仍在执行的调用保持锁定。记录不按时间过期。
///
/// 占用绑定调用标识（owner）：管线的结算与释放只对自己持有的占用生效，旧调用不会释放新调用的锁（lessons 26）。
/// 先持久化、成功后再改内存（lessons 32）：写回 unknown 失败时内存里仍按 unknown（覆盖层），删除失败时按已结束
/// 隐藏并在 coldStart 时重试；结算方法返回是否已落盘。线程安全（方法加锁）。
///
/// 存储读失败或记录损坏不当成「没有记录」（R1-07）：无法确认未决状态时新的提交返回 storeFailed（不发出），
/// 查询返回 unreadable，确认 / 放弃不开始。
public final class PendingKeyStore: @unchecked Sendable {
    public static let none = "none"
    public static let inFlight = "in_flight"
    public static let unknown = "unknown"
    public static let done = "done"
    /// 读不出来（安全存储读失败或记录损坏）：无法确认是否有未决的键。
    public static let unreadable = "unreadable"

    public static let noEnvelope = "no_envelope"
    public static let envelopeSuccess = "envelope_success"
    public static let abandoned = "abandoned"
    public static let envelopePrefix = "envelope_"
    private static let abandonedCode = 20903

    let backend: any PendingKeyBackend
    let clock: () -> Int64
    let lock = NSRecursiveLock()
    var account: String?
    /// 本进程里已结束的键（done 只是观察值，持久记录已删除）。
    var finished: Set<String> = []
    /// 本进程里正在执行的调用持有的占用：键 → 调用标识。
    var active: [String: String] = [:]
    /// 没能写回的 unknown（内存里按 unknown）：槽位 → 记录。
    var overlay: [String: PendingKeyRecord] = [:]
    /// 没能删除的已结束记录（内存里按已结束）：槽位。
    var pendingDeletes: Set<String> = []
    /// 本进程最近一次确认过的持久内容（槽位 → 记录）：读失败时只用于结算本进程自己的占用。
    var known: [String: PendingKeyRecord] = [:]

    public init(backend: any PendingKeyBackend, clock: @escaping () -> Int64) {
        self.backend = backend
        self.clock = clock
    }

    /// 四个需要二次验证的操作（operation 的 x-step-up）。
    public static func isSensitive(_ operationId: String) -> Bool {
        ApiOperations.byId(operationId)?.stepUp != nil
    }

    /// 响应 → kind：有外壳时 envelope_success / envelope_<code>。
    public static func envelopeKind(_ code: Int) -> String {
        code == 0 ? envelopeSuccess : "\(envelopePrefix)\(code)"
    }

    public var currentAccount: String? {
        lock.withLock { account }
    }

    static func slot(_ account: String, _ key: String) -> String {
        "\(account.count):\(account)|\(key)"
    }

    // MARK: - 恢复

    public func coldStart(account: String) {
        lock.withLock {
            self.account = account
            for slot in pendingDeletes where slot.hasPrefix(Self.slot(account, "")) {
                let key = String(slot.dropFirst(Self.slot(account, "").count))
                _ = remove(account, key)
            }
            // 读不出来时什么都不改（下次恢复或提交前再读）；新的提交在 admit 里因读失败被挡。
            let records = (try? list(account)) ?? []
            for record in records where record.stateRaw == Self.inFlight && active[record.key] == nil {
                var next = record
                next.stateRaw = Self.unknown
                next.everUnknown = true
                _ = persistUnknown(next)
            }
            for record in overlay.values where record.account == account {
                _ = persist(record)
            }
        }
    }

    /// 退出登录或切换账号：不删除记录（别的账号的记录不读不发），只停止读取。
    public func signOut() {
        lock.withLock { account = nil }
    }

    // MARK: - 发送前登记

    /// 登记结果：放行（带占用标识）；同一操作已有未决的键（不得换新键）；记录写不进安全存储（不得发送）。
    enum Admission: Equatable {
        case admitted(owner: String?)
        case blocked
        case storeFailed
    }

    /// 一次提交（管线发送前登记用）。
    struct Submission {
        let operationId: String
        let key: String
        let body: String
        let account: String
        let summary: String
    }

    /// 发送前登记。返回 false = 不得发送（同一操作已有未决的键，或记录写不进安全存储）。
    public func beforeSend(
        operationId: String,
        key: String,
        body: String,
        account: String,
        summary: String = ""
    ) -> Bool {
        if case .admitted = admit(operationId: operationId, key: key, body: body, account: account, summary: summary) {
            return true
        }
        return false
    }

    func admit(operationId: String, key: String, body: String, account: String, summary: String) -> Admission {
        guard Self.isSensitive(operationId) else {
            return .admitted(owner: nil)
        }
        return lock.withLock {
            if self.account != account {
                coldStart(account: account)
            }
            let existing: [PendingKeyRecord]
            do {
                existing = try list(account)
            } catch {
                // 无法确认有没有未决的键：不放行新的提交（R1-07）。
                return .storeFailed
            }
            if existing.contains(where: { $0.operationId == operationId }) {
                return .blocked
            }
            let record = PendingKeyRecord(
                key: key, operationId: operationId, body: body, account: account, summary: summary,
                stateRaw: Self.inFlight, everUnknown: false, createdAtMillis: clock()
            )
            guard persist(record) else {
                return .storeFailed
            }
            let owner = UUID().uuidString
            finished.remove(key)
            active[key] = owner
            return .admitted(owner: owner)
        }
    }

    /// 管线发送前调用：同一个键已有记录 → 只有这次调用自己持有的 in_flight（确认入口或自动续发）且请求体相同才放行；
    /// 没有记录 → 同 beforeSend。
    func prepareSend(_ submission: Submission, owner: String?) -> Admission {
        let (operationId, key, body, account, summary) = (
            submission.operationId, submission.key, submission.body, submission.account, submission.summary
        )
        guard Self.isSensitive(operationId) else {
            return .admitted(owner: nil)
        }
        return lock.withLock {
            if self.account != account {
                coldStart(account: account)
            }
            let found: PendingKeyRecord?
            do {
                found = try read(account, key)
            } catch {
                return .storeFailed
            }
            guard let existing = found else {
                return admit(operationId: operationId, key: key, body: body, account: account, summary: summary)
            }
            let owned = existing.stateRaw == Self.inFlight && owner != nil && active[key] == owner
                && existing.body == body
            return owned ? .admitted(owner: owner) : .blocked
        }
    }

    // MARK: - 结算

    /// 一次响应（三端接线的 raw）：no_envelope、envelope_success、abandoned、envelope_3xxxx、envelope_<code>。
    /// 不认识的 kind 按非终结处理（保守）。按当前账号结算（管线用带账号与占用标识的版本）。
    public func onResponse(key: String, kind: String) {
        lock.withLock {
            guard let current = account else {
                active[key] = nil
                return
            }
            _ = settle(key: key, kind: kind, account: current, owner: nil)
        }
    }

    /// 按发出时的账号与占用标识结算。占用已不归这次调用（被别的调用接手）时不动记录。返回是否已落盘。
    @discardableResult
    func onResponse(key: String, kind: String, account owner: String, callOwner: String?) -> Bool {
        lock.withLock { settle(key: key, kind: kind, account: owner, owner: callOwner) }
    }

    private func settle(key: String, kind: String, account owner: String, owner callOwner: String?) -> Bool {
        if let callOwner, let holder = active[key], holder != callOwner {
            return true
        }
        active[key] = nil
        guard let record = readForSettlement(owner, key) else {
            return true
        }
        var next = record
        switch Self.classify(kind) {
        case .noEnvelope:
            next.stateRaw = Self.unknown
            next.everUnknown = true
            return persistUnknown(next)
        case .terminal:
            finished.insert(key)
            return remove(owner, key)
        case .nonTerminal:
            if record.everUnknown {
                next.stateRaw = Self.unknown
                return persistUnknown(next)
            }
            return remove(owner, key)
        }
    }

    /// 确认 / 作废 / 首次发送的请求没有真正发出（本地拒绝、发送前出错）：释放这次调用持有的占用。
    /// 出现过结果未知的恢复为 unknown；从未发出的新记录删除（这次提交没有发生）。按占用时的账号结算。
    @discardableResult
    func release(key: String, account owner: String, callOwner: String?) -> Bool {
        lock.withLock {
            if let callOwner, let holder = active[key], holder != callOwner {
                return true
            }
            active[key] = nil
            guard let record = readForSettlement(owner, key), record.stateRaw == Self.inFlight else {
                return true
            }
            if record.everUnknown {
                var next = record
                next.stateRaw = Self.unknown
                return persistUnknown(next)
            }
            return remove(owner, key)
        }
    }

    // MARK: - 用户操作

    /// 用户点确认：用原键、原请求体重发。只在 unknown 时接受。
    public func confirm(key: String) -> Bool {
        startUserAction(key) != nil
    }

    /// 用户点放弃（二次确认后调作废接口）。只在 unknown 时接受；不是本地删除。
    public func abandon(key: String) -> Bool {
        startUserAction(key) != nil
    }

    /// 管线用：开始确认 / 放弃，返回占用标识；nil = 不在 unknown 或 in_flight 写不进去（内存保持 unknown）。
    func startUserAction(_ key: String) -> String? {
        lock.withLock {
            guard let current = account, let record = try? read(current, key), record.stateRaw == Self.unknown else {
                return nil
            }
            var next = record
            next.stateRaw = Self.inFlight
            guard persist(next) else {
                return nil
            }
            let owner = UUID().uuidString
            active[key] = owner
            return owner
        }
    }

    private enum Outcome {
        case noEnvelope
        case terminal
        case nonTerminal
    }

    private static func classify(_ kind: String) -> Outcome {
        if kind == noEnvelope {
            return .noEnvelope
        }
        if kind == envelopeSuccess || kind == abandoned || kind == "envelope_3xxxx" {
            return .terminal
        }
        guard kind.hasPrefix(envelopePrefix), let code = Int(kind.dropFirst(envelopePrefix.count)) else {
            return .nonTerminal
        }
        return code == abandonedCode || ErrorActionMapper.isBusinessCode(code) ? .terminal : .nonTerminal
    }
}
