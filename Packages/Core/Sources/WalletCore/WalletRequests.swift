import CouliNetwork
import Foundation

/// 一次请求的归属（线程安全）：页面离开、新一轮读取、会话换代时同步置为无效。ApiClient 在任意线程读取。
public final class RequestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    public init() {}

    public var isValid: Bool {
        lock.withLock { valid }
    }

    public func invalidate() {
        lock.withLock { valid = false }
    }
}

/// 页面执行器的在途读请求（归属 + 可取消的 Task；取消即取消传输）。出栈、会话换代时在同步出口 `cancelAll`（APP-04 第 28、47 条，APP-12
/// 第 28 条）；结果只在归属仍有效时交给 `settle`（调用方再复核轮次与固定身份）。写请求（提交、确认、放弃）不经这里：离开页面不取消。
@MainActor
final class WalletRequests {
    private var entries: [Int: (flag: RequestFlag, task: Task<Void, Never>)] = [:]
    let settling = SettlingTasks()
    private var next = 0

    /// 发出一次读调用。`probe` 是本请求的发送前闸门（共享禁用期）；`expected` 是执行器固定的网络归属。返回请求编号（单独作废用）。
    @discardableResult
    func send(
        _ api: WalletApi, _ call: ApiCall, probe: SendProbe, expected: RequestOwnership?,
        settle: @escaping @MainActor (ApiResult) -> Void
    ) -> Int {
        next += 1
        let id = next
        let flag = RequestFlag()
        let allowed = probe.allowed
        let settling = settling
        settling.begin()
        let task = Task { @MainActor [weak self] in
            defer { settling.end() }
            let result = await api.send(call, isValid: { flag.isValid }, sendAllowed: allowed, expected: expected)
            self?.entries[id] = nil
            guard flag.isValid else { return }
            settle(result)
        }
        entries[id] = (flag, task)
        return id
    }

    /// 作废并取消一个请求。
    func cancel(_ id: Int) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.flag.invalidate()
        entry.task.cancel()
    }

    /// 是否仍在途。
    func isActive(_ id: Int) -> Bool {
        entries[id] != nil
    }

    /// 作废并取消全部在途请求。
    func cancelAll() {
        let all = entries.values
        entries = [:]
        for entry in all {
            entry.flag.invalidate()
            entry.task.cancel()
        }
    }

    var count: Int {
        entries.count
    }
}

/// 页面可见性（APP-09 共性第 37、41、47、57 条）：页面被覆盖或退到后台时可见世代加一。异步结果要打开浮层或导航时，发出时记下世代
/// （`ticket`），结果到达时要求此刻可见且世代未变（`showing(_:)`）；成功导航只看「此刻可见」（`now`），不可见时推迟到回到可见。
@MainActor
public final class PageVisibility {
    public private(set) var visible = true
    public private(set) var generation = 0

    public init() {}

    public func set(_ shown: Bool) {
        if shown != visible {
            generation += 1
        }
        visible = shown
    }

    /// 本页发起的导航（打开前置页、记录、帮助、客服）：导航世代立即变化，不等系统回调（鸿蒙 H31 同口径）。
    public func navigated() {
        generation += 1
    }

    /// 此刻可见。
    public var now: Bool {
        visible
    }

    /// 发出时的世代仍有效、此刻可见。
    public func showing(_ ticket: Int) -> Bool {
        visible && generation == ticket
    }
}
