import CouliNetwork
import Foundation
import WalletCore

/// 页面执行器的在途读请求（归属 + 可取消的 Task；取消即取消传输）。出栈、会话换代时在同步出口 `cancelAll`（APP-04 第 28、47 条，APP-12
/// 第 28 条）；结果只在归属仍有效时交给 `settle`。写请求（提交、保存、撤回）不经这里：离开页面不取消。
@MainActor
public final class MeRequests {
    private var entries: [Int: (flag: RequestFlag, task: Task<Void, Never>)] = [:]
    let settling = SettlingTasks()
    private var next = 0

    public init() {}

    /// 发出一次读调用。`probe` 是本请求的发送前闸门（共享禁用期）；`expected` 是执行器固定的网络归属。返回请求编号。
    @discardableResult
    public func send(
        _ api: MeApi, _ call: ApiCall, probe: SendProbe, expected: RequestOwnership?,
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

    public func cancel(_ id: Int) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.flag.invalidate()
        entry.task.cancel()
    }

    public func cancelAll() {
        let all = entries.values
        entries = [:]
        for entry in all {
            entry.flag.invalidate()
            entry.task.cancel()
        }
    }

    public var count: Int {
        entries.count
    }
}

/// App 已释放后的环境：没有身份、什么都不做（在途任务回来只做比较，一律作废）。
@MainActor
final class DetachedMeEnv: MeEnv {
    static let shared = DetachedMeEnv()

    func identity() -> MeIdentity {
        .none
    }

    func isCurrent(_: MeIdentity) -> Bool {
        false
    }

    func open(_: String, params _: [String: String], from _: UUID?) {}
    func copy(_: String) -> Bool {
        false
    }

    func configObject(_: String) -> Any? {
        nil
    }

    func availableRoutes() -> Set<String> {
        []
    }

    func earningsFlag() -> Bool? {
        nil
    }

    func customerService(from _: String) {}
    func permissionStatus(_: String) async -> String {
        "unavailable"
    }

    func permissionDeniedAt(_: String) -> Int64? {
        nil
    }

    func openNotificationSettings() {}
    func openAppSettings() {}
    func permissionEntries() -> [[String: Any]] {
        []
    }

    func requestFullFunction() {}
    func forceUpdateContext() -> Bool {
        false
    }

    func enteredBy10006(_: MeIdentity) -> Bool {
        false
    }

    func deviceRegistered() -> Bool {
        false
    }

    func consentedPrivacyVersion() -> Int? {
        nil
    }

    func legalPrivacyVersion() -> Int? {
        nil
    }

    func cacheBytes() async -> Int64? {
        nil
    }

    func clearCache() async -> Bool {
        false
    }

    var appVersion: String {
        ""
    }

    var appBuild: String {
        ""
    }

    func diagnosticsFields() -> [String: Any] {
        [:]
    }

    func logout(_: MeIdentity, from _: UUID?) {}
    func withdrawConsent(_: MeIdentity) {}
    func close(page _: UUID) -> Bool {
        false
    }

    func tipsReset() {}
    func nowMillis() -> Int64 {
        0
    }

    func displayNowMillis() -> Int64 {
        0
    }
}
