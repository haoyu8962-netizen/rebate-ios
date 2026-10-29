@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Wallet
import WalletCore
import XCTest

/// APP-09v-a（钱包页视觉）三端同一份截图数据：`specs/wallet-vectors.json` 的 `visualWallet`（G-W25；与 Android 33d6b62 合入版逐字节相同，
/// 只在根末尾多这一组，原 22 组不动）。固定时钟 2026-10-22 10:32 +08:00、断网缓存时刻 09:30。只读，不写回共用文件。
enum WalletVisualData {
    static func repo() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            directory = directory.deletingLastPathComponent()
        }
        return directory
    }

    static func root() throws -> [String: Any] {
        let data = try Data(contentsOf: repo().appendingPathComponent("specs/wallet-vectors.json"))
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(vectors["visualWallet"] as? [String: Any], "共用向量文件缺 visualWallet 组（G-W25）")
    }

    /// 一份完整摘要报文（WalletSummary，13 个字段原样；null 为 NSNull）。
    static func summary(_ name: String) throws -> [String: Any] {
        let all = try XCTUnwrap(root()["summaries"] as? [String: Any])
        return try XCTUnwrap(all[name] as? [String: Any], "visualWallet.summaries 缺 \(name)")
    }

    static func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(bytes: data, encoding: .utf8))
    }

    static func millis(_ key: String) throws -> Int64 {
        let text = try XCTUnwrap(root()[key] as? String, "visualWallet 缺 \(key)")
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: text), "\(key) 不是 ISO 8601：\(text)")
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// 固定时钟（10:32）。
    static func nowMillis() throws -> Int64 {
        try millis("clock")
    }

    /// 断网缓存的获取时刻（今天 09:30）。
    static func cachedAtMillis() throws -> Int64 {
        try millis("cachedAt")
    }

    /// HTTP 响应头 Date（RFC 1123，GMT）：生产 ApiClient 按它校准显示用时钟（与本机相差超过 300 秒才校正，测试机日期不同于夹具日，必定校正）。
    static func httpDate(_ millis: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }

    /// 金额（分）按 DesignSystem 格式化（测试不自己拼金额字符串）。
    static func money(_ fen: Int64) -> String {
        WalletVisualFormat.money(fen)
    }
}

/// 金额格式化只走 DesignSystem（AGENTS.md 硬规则 3）。
enum WalletVisualFormat {
    static func money(_ fen: Int64) -> String {
        CouliFormat.money(fen: fen)
    }
}

/// 钱包视觉的假服务脚本（生产同一个 WalletStubProtocol / WalletScript）：摘要回 visualWallet 的一份报文，并带固定时钟的 Date 响应头。
enum WalletVisualScript {
    /// 摘要正常返回。
    static func summary(_ script: WalletScript, _ name: String, at millis: Int64? = nil) throws {
        let now = try millis ?? WalletVisualData.nowMillis()
        let body = try WalletVisualData.json(WalletVisualData.summary(name))
        script.on("GET /v1/wallet/summary",
                  .envelope(code: 0, data: body, headers: ["Date": WalletVisualData.httpDate(now)]))
    }

    /// 派生摘要（测试内改几个字段，不写回共用文件）。
    static func summary(_ script: WalletScript, object: [String: Any]) throws {
        let now = try WalletVisualData.nowMillis()
        try script.on("GET /v1/wallet/summary",
                      .envelope(code: 0, data: WalletVisualData.json(object),
                                headers: ["Date": WalletVisualData.httpDate(now)]))
    }

    /// 摘要挂起（加载骨架）。
    static func hold(_ script: WalletScript) {
        script.on("GET /v1/wallet/summary", .hold)
    }

    /// 摘要读取失败、本机无缓存（错误态，带 trace6）。
    static func serverError(_ script: WalletScript) throws {
        let now = try WalletVisualData.nowMillis()
        script.on("GET /v1/wallet/summary",
                  .envelope(code: 50001, data: "null", headers: ["Date": WalletVisualData.httpDate(now)]))
    }

    /// 断网（传输层失败，生产只在这种失败时读缓存，G22）。
    static func offline(_ script: WalletScript) {
        script.on("GET /v1/wallet/summary", .disconnect)
    }
}

/// 收益看板入口的测试开关（G20：生产 Earnings 路由 since.ios 为 null，入口一律不显示）。WalletEarningsEntry 画板要第三个入口，Android 同样只在
/// 测试环境给 since=1.0.0。这里把生产 AppWallet 包一层：只改 `earningsFlag` / `earningsSince` 两项，其余（身份、打开路由、时钟）全部原样转给
/// AppWallet——页面、执行器、Router 仍是生产的。生产 since=null 仍隐藏由 `WalletVisualOracleTests` 另行守住。
@MainActor
final class WalletVisualEarningsEnv: WalletEnv {
    let base: AppWallet

    init(base: AppWallet) {
        self.base = base
    }

    func currentOwner() -> WalletOwner {
        base.currentOwner()
    }

    func isCurrent(_ owner: WalletOwner) -> Bool {
        base.isCurrent(owner)
    }

    func check(_ owner: WalletOwner) -> IdentityCheck {
        base.check(owner)
    }

    func recheckIdentity() {
        base.recheckIdentity()
    }

    func configText(_ key: String) -> String? {
        base.configText(key)
    }

    func helpLinks() -> [String: Any]? {
        base.helpLinks()
    }

    func earningsFlag() -> Bool? {
        true
    }

    var appVersion: String {
        base.appVersion
    }

    var earningsSince: String? {
        "1.0.0"
    }

    func open(_ route: String, params: [String: String], from page: UUID?) {
        base.open(route, params: params, from: page)
    }

    func replace(page: UUID, route: String, params: [String: String]) -> Bool {
        base.replace(page: page, route: route, params: params)
    }

    func close(page: UUID) -> Bool {
        base.close(page: page)
    }

    func payoutSaved(page: UUID) -> Bool {
        base.payoutSaved(page: page)
    }

    func copy(_ text: String) -> Bool {
        base.copy(text)
    }

    func contactService(from route: String) {
        base.contactService(from: route)
    }

    func stepUpPhone(account: String) -> String? {
        base.stepUpPhone(account: account)
    }

    func markWalletDirty(_ owner: WalletOwner) {
        base.markWalletDirty(owner)
    }

    func realnameChanged() {
        base.realnameChanged()
    }

    func sensitiveOverlay(_ showing: Bool) {
        base.sensitiveOverlay(showing)
    }

    func nowMillis() -> Int64 {
        base.nowMillis()
    }

    func displayNowMillis() -> Int64 {
        base.displayNowMillis()
    }
}
