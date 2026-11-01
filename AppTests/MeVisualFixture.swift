@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Me
import MeCore
import Router
import XCTest

/// APP-12v（「我的」视觉）三端同一份截图数据：`specs/me-vectors.json` 的 `visualMe`（G-M18；取自 Android 合入版，逐字节相同，
/// 只在根末尾多这一组，原 25 组不动）。固定时钟 2026-10-12 10:30 +08:00。只读，不写回共用文件。
enum MeVisualData {
    static func root() throws -> [String: Any] {
        let url = WalletVisualData.repo().appendingPathComponent("specs/me-vectors.json")
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(vectors["visualMe"] as? [String: Any], "共用向量文件缺 visualMe 组（G-M18）")
    }

    /// 一份完整 Me 报文（13 个字段原样；null 为 NSNull）。
    static func profile(_ name: String) throws -> [String: Any] {
        let all = try XCTUnwrap(root()["profiles"] as? [String: Any])
        return try XCTUnwrap(all[name] as? [String: Any], "visualMe.profiles 缺 \(name)")
    }

    static func body(_ name: String) throws -> String {
        try WalletVisualData.json(profile(name))
    }

    static func routes(_ key: String) throws -> Set<String> {
        try Set(XCTUnwrap(root()[key] as? [String], "visualMe 缺 \(key)"))
    }

    static func local(_ name: String) throws -> [String: Any] {
        let all = try XCTUnwrap(root()["localStates"] as? [String: Any])
        return try XCTUnwrap(all[name] as? [String: Any], "visualMe.localStates 缺 \(name)")
    }

    static func millis(_ text: String) throws -> Int64 {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: text), "不是 ISO 8601：\(text)")
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// 固定时钟（10:30）：页面不依赖真实墙钟（APP-09v-e T4）。
    static func nowMillis() throws -> Int64 {
        try millis(XCTUnwrap(root()["clock"] as? String))
    }

    static func money(_ fen: Int64) -> String {
        WalletVisualData.money(fen)
    }
}

/// 文案替身：只替换指定键（G-M10 切分的可切 / 不可切 / 空尾 / 尾过长都走生产页面渲染，测试不实现切分）。
final class MeVisualTexts: MeTexts, @unchecked Sendable {
    private let base: MeTexts
    private let lock = NSLock()
    private var overrides: [String: String]

    init(base: MeTexts, overrides: [String: String]) {
        self.base = base
        self.overrides = overrides
    }

    func set(_ key: String, _ value: String) {
        lock.withLock { overrides[key] = value }
    }

    func text(_ key: String) -> String {
        lock.withLock { overrides[key] } ?? base.text(key)
    }

    func format(_ key: String, _ vars: [String: String]) -> String {
        base.format(key, vars)
    }
}

/// 包一层的环境：除「可用路由、收益开关」外原样转给真实 AppMe，并记下每一次导航 / 客服 / 复制（计数断言）。生产路由表 Earnings since 为 null，
/// 公开版宫格（routes_public + 开关）只能这样注入（与 `WalletVisualEarningsEnv` 同做法）。
@MainActor
final class MeVisualEnv: MeEnv {
    let base: AppMe
    let routes: Set<String>?
    let earnings: Bool?
    private(set) var opened: [(route: String, params: [String: String])] = []
    private(set) var customerServiceFrom: [String] = []
    private(set) var copies: [String] = []

    init(base: AppMe, routes: Set<String>?, earnings: Bool?) {
        self.base = base
        self.routes = routes
        self.earnings = earnings
    }

    func availableRoutes() -> Set<String> {
        routes ?? base.availableRoutes()
    }

    func earningsFlag() -> Bool? {
        earnings ?? base.earningsFlag()
    }

    func open(_ route: String, params: [String: String], from page: UUID?) {
        opened.append((route, params))
        base.open(route, params: params, from: page)
    }

    func customerService(from route: String) {
        customerServiceFrom.append(route)
        base.customerService(from: route)
    }

    func copy(_ text: String) -> Bool {
        copies.append(text)
        return base.copy(text)
    }

    /// 会话作用域（F-X-14 端口，同 Android `MeEnv.sessionScope`；AppMe 已有同名方法）。
    func sessionScope() -> String {
        base.sessionScope()
    }

    func identity() -> MeIdentity {
        base.identity()
    }

    func isCurrent(_ identity: MeIdentity) -> Bool {
        base.isCurrent(identity)
    }

    func check(_ identity: MeIdentity) -> IdentityCheck {
        base.check(identity)
    }

    func recheckIdentity() {
        base.recheckIdentity()
    }

    func configObject(_ key: String) -> Any? {
        base.configObject(key)
    }

    func permissionStatus(_ type: String) async -> String {
        await base.permissionStatus(type)
    }

    func permissionDeniedAt(_ type: String) -> Int64? {
        base.permissionDeniedAt(type)
    }

    func openNotificationSettings() {
        base.openNotificationSettings()
    }

    func openAppSettings() {
        base.openAppSettings()
    }

    func permissionEntries() -> [[String: Any]] {
        base.permissionEntries()
    }

    func requestFullFunction() {
        base.requestFullFunction()
    }

    func forceUpdateContext() -> Bool {
        base.forceUpdateContext()
    }

    func enteredBy10006(_ identity: MeIdentity) -> Bool {
        base.enteredBy10006(identity)
    }

    func deviceRegistered() -> Bool {
        base.deviceRegistered()
    }

    func consentedPrivacyVersion() -> Int? {
        base.consentedPrivacyVersion()
    }

    func legalPrivacyVersion() -> Int? {
        base.legalPrivacyVersion()
    }

    func cacheBytes() async -> Int64? {
        await base.cacheBytes()
    }

    func clearCache() async -> Bool {
        await base.clearCache()
    }

    var appVersion: String {
        base.appVersion
    }

    var appBuild: String {
        base.appBuild
    }

    func diagnosticsFields() -> [String: Any] {
        base.diagnosticsFields()
    }

    func logout(_ identity: MeIdentity, from page: UUID?) {
        base.logout(identity, from: page)
    }

    func withdrawConsent(_ identity: MeIdentity) {
        base.withdrawConsent(identity)
    }

    func close(page: UUID) -> Bool {
        base.close(page: page)
    }

    func tipsReset() {
        base.tipsReset()
    }

    func nowMillis() -> Int64 {
        base.nowMillis()
    }

    func clipboardAutoOn() -> Bool {
        base.clipboardAutoOn()
    }

    func setClipboardAuto(_ on: Bool) {
        base.setClipboardAuto(on)
    }

    func displayNowMillis() -> Int64 {
        base.displayNowMillis()
    }
}

/// 只看测量记录的纯判据（Oracle 用例先正后反自证）。
enum MeVisualJudge {
    /// 可折行文字是否被截断：按自然宽折算至少要几行，框高放不下这么多行即截断（lineLimit、父级裁高都会让框比需要的矮）。
    /// `naturalWidth` 必须上报（§4）；没报按「判据失效」给 true，不放行。
    static func truncated(_ item: CouliLayoutProbeRecord) -> Bool {
        guard item.naturalWidth > 0, item.rect.width > 0, item.fontSize > 0 else { return true }
        let lines = (item.naturalWidth / (item.rect.width + 0.5)).rounded(.up)
        return item.rect.height + 0.5 < lines * item.fontSize
    }
}
