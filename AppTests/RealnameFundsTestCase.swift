@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Router
import Wallet
import WalletCore
import XCTest

/// FU-IOS-REALNAME-API（D10-856 ②）测试的公共部分：真实 ApiClient + 本地假服务；生产 `AppWallet` 不调 `installBackends`，
/// 即 Release / Staging 的接线。姓名、身份证号是明显的测试值（哨兵，同 specs/realname-submit-vectors.json request.normalize），
/// 失败信息不打印哨兵本身。类名带 Funds：不进 verify 的失败重试（tools/ci/verify.sh NO_RETRY_TEST_PATTERN）。
@MainActor
class RealnameFundsTestCase: WalletFlowTestCase {
    static let path = "/v1/me/realname"
    static let typedName = "  测试实名甲 "
    static let name = "测试实名甲"
    static let typedId = "11010519491231002x"
    static let idNo = "11010519491231002X"
    static let unverifiedMe = "{\"user_id\":\"user-a\",\"realname_status\":\"none\",\"phone_bound\":true}"
    static let successData = "{\"realname_status\":\"verified\",\"masked_name\":\"**甲\"}"
    static let success = WalletStubProtocol.Reply.envelope(code: 0, data: successData, headers: [:])

    var realnamePosts: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("POST", Self.path)
    }

    var consentPosts: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("POST", "/v1/consents")
    }

    var meGets: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("GET", "/v1/me")
    }

    /// 哨兵（含大小写两种身份证号写法）。
    var secrets: [String] {
        [Self.name, Self.idNo, Self.typedId]
    }

    func leaks(_ text: String) -> Bool {
        secrets.contains { text.contains($0) }
    }

    func key(_ request: WalletStubProtocol.Recorded) -> String? {
        request.header("Idempotency-Key")
    }

    /// GET /v1/me：先未实名，之后已实名（实名成功后的复查）。
    func scriptUnverifiedThenVerified() {
        script.on("GET /v1/me", .envelope(code: 0, data: Self.unverifiedMe, headers: [:]),
                  .envelope(code: 0, data: WalletSamples.me, headers: [:]))
    }

    func scriptAlwaysUnverified() {
        script.on("GET /v1/me", .envelope(code: 0, data: Self.unverifiedMe, headers: [:]))
    }

    /// 钱包 → 【提现】：未实名被守卫送进 RealName（生产接线，不装任何实名后端）。
    func openFromWithdraw(_ fixture: WalletAppFixture, file: StaticString = #filePath,
                          line: UInt = #line) async throws -> RealNameController {
        _ = try XCTUnwrap(fixture.open(WalletRoutes.wallet), "钱包没有打开", file: file, line: line)
        fixture.wallet.open(WalletRoutes.withdraw, params: [:], from: fixture.router.path.last?.id)
        await waitUntil("未实名没有进实名页", file: file, line: line) {
            fixture.router.path.last?.route == WalletRoutes.realName
        }
        return try XCTUnwrap(fixture.page(WalletRoutes.realName)?.controller as? RealNameController,
                             file: file, line: line)
    }

    /// 输入（每步按渲染时取回调，同 RealNameScreen）。
    func fill(_ page: RealNameController, name: String = RealnameFundsTestCase.typedName,
              idNo: String = RealnameFundsTestCase.typedId) {
        RealNameActions.make(page, page.state).name(name)
        RealNameActions.make(page, page.state).idNo(idNo)
    }

    /// 【提交认证】→ 单独同意半屏勾选 → 【同意并继续】。
    func submitWithConsent(_ page: RealNameController) {
        RealNameActions.make(page, page.state).submit()
        agree(page)
    }

    /// 半屏已打开时：勾选 → 【同意并继续】。
    func agree(_ page: RealNameController) {
        RealNameActions.make(page, page.state).toggleConsent()
        RealNameActions.make(page, page.state).agree()
    }

    /// 等到发出第 `count` 个实名提交。
    func awaitPosts(_ count: Int, timeout: TimeInterval = 5, file: StaticString = #filePath,
                    line: UInt = #line) async {
        await waitUntil("第 \(count) 个实名提交没有发出", timeout: timeout, file: file, line: line) {
            self.realnamePosts.count >= count
        }
    }

    /// 一次完整的提交（打开 → 填写 → 同意 → 等第 1 个提交发出并落定 1 秒）。
    func submitOnce(_ fixture: WalletAppFixture) async throws -> RealNameController {
        let page = try await openFromWithdraw(fixture)
        fill(page)
        submitWithConsent(page)
        await awaitPosts(1)
        await quietWindow(1.0)
        return page
    }

    /// 请求体解析为对象（失败信息不打印请求体）。
    func body(_ request: WalletStubProtocol.Recorded) -> [String: Any] {
        request.json
    }

    /// 本用例临时目录（缓存、草稿）里所有文件的字节。
    func storedFiles() -> [Data] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { ($0 as? URL).flatMap { try? Data(contentsOf: $0) } }
    }
}

/// specs/realname-submit-vectors.json（三端共用）。
enum RealnameVectors {
    static func root() throws -> [String: Any] {
        let url = WalletVisualData.repo().appendingPathComponent("specs/realname-submit-vectors.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func cases() throws -> [[String: Any]] {
        try XCTUnwrap(root()["cases"] as? [[String: Any]])
    }

    static func named(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(cases().first { $0["name"] as? String == name }, "向量 \(name) 不存在")
    }

    /// 向量里的回答 → 本地假服务的回答。
    static func reply(_ object: [String: Any]) throws -> WalletStubProtocol.Reply {
        if object["transport"] as? String == "disconnect" {
            return .disconnect
        }
        let code = try XCTUnwrap(object["code"] as? Int)
        let raw = object["data"] ?? NSNull()
        var data = "null"
        if !(raw is NSNull) {
            let encoded = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
            data = String(bytes: encoded, encoding: .utf8) ?? "null"
        }
        return .envelope(code: code, data: data, headers: object["headers"] as? [String: String] ?? [:])
    }
}
