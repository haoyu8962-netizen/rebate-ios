import Foundation
@testable import MeCore

/// 换号执行器分支用例（App13a2PhoneChangeBranchTests）的「我的」环境替身：固定一个已登录身份，`current = false` 模拟换代；其余能力都是
/// 不做事的空实现（换号执行器只用到身份核对、客服出口、打开路由与时钟）。
@MainActor
final class App13a2BranchMeEnv: MeEnv {
    let fixed: MeIdentity
    var current = true
    private(set) var customerServiceFrom: [String] = []
    private(set) var opened: [String] = []

    init(identity: MeIdentity) {
        fixed = identity
    }

    func identity() -> MeIdentity {
        fixed
    }

    func isCurrent(_ identity: MeIdentity) -> Bool {
        current && identity == fixed
    }

    func sessionScope() -> String {
        "full"
    }

    func open(_ route: String, params _: [String: String], from _: UUID?) {
        opened.append(route)
    }

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

    func customerService(from route: String) {
        customerServiceFrom.append(route)
    }

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
        true
    }

    func consentedPrivacyVersion() -> Int? {
        1
    }

    func legalPrivacyVersion() -> Int? {
        1
    }

    func cacheBytes() async -> Int64? {
        nil
    }

    func clearCache() async -> Bool {
        false
    }

    var appVersion: String {
        "1.2.0"
    }

    var appBuild: String {
        "1"
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
        1_790_904_600_000
    }

    func displayNowMillis() -> Int64 {
        1_790_904_600_000
    }
}
