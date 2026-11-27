@testable import Couli
import Foundation
import XCTest

/// FU-IOS-WITHDRAW-STEPUP-PANEL-CLEANUP 补测 S3-3（FU-IOS-CONTRACT-LOCK-6c97062/review-funds-r1.md）：Debug 假后端提现分支的直测。
/// 升锁单已把 DebugFakeWallet 的提现改成不校令牌、不回 10003（契约 6c97062，B1-02zzzc），但之前只有 UI 测试间接覆盖。这里照
/// LockIosFakeWalletStepUpTests 的构造直接调假服务的回答入口（不经网络管线），钉住现状：
/// - 提现不带 X-Step-Up-Token（含 step_up=always、带一张从未签发的令牌）→ 成功建单，同键再发回同一结果；
/// - submit=unknown_lost 不要令牌 → offline（请求未到达：不建单、不记幂等结果，记下丢在路上的键）。
@MainActor
final class FuIosFakeWalletWithdrawNoTokenTests: XCTestCase {
    static let walletKey = DebugFakeWallet.launchArgument
    static let auth = ["Authorization": "Bearer debug-at"]

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.walletKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: Self.walletKey)
        try await super.tearDown()
    }

    /// 提现提交：只带 Idempotency-Key（和 `extra` 里的头），请求体 amount_fen。
    private func submit(_ fake: DebugFakeWallet, key: String, amount: Int = 1000,
                        extra: [String: String] = [:]) -> DebugFakeWallet.Reply? {
        var headers = Self.auth.merging(extra) { _, new in new }
        headers["Idempotency-Key"] = key
        return fake.answer(method: "POST", path: "/v1/withdrawals", query: [:], body: ["amount_fen": amount],
                           headers: headers)
    }

    private func code(_ reply: DebugFakeWallet.Reply?) -> Int? {
        if case let .answer(code, _, _) = reply {
            return code
        }
        return nil
    }

    private func data(_ reply: DebugFakeWallet.Reply?) -> [String: Any] {
        guard case let .answer(_, text, _) = reply,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return [:] }
        return object
    }

    private func isOffline(_ reply: DebugFakeWallet.Reply?) -> Bool {
        if case .offline = reply {
            return true
        }
        return false
    }

    /// 缺省场景与 step_up=always：提现不带令牌 → 0 并建单（金额照请求体）；同键再发回同一张单、不重复建单；
    /// 带一张假服务从未签发的令牌也照样成功（提现不校验令牌）。
    func testWithdrawWithoutTokenSucceeds() throws {
        for scene in [nil, "step_up=always"] {
            let label = scene ?? "缺省"
            if let scene {
                UserDefaults.standard.set(scene, forKey: Self.walletKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.walletKey)
            }
            let fake = DebugFakeWallet()
            let first = submit(fake, key: "K-no-token")
            XCTAssertEqual(code(first), 0, "\(label)：不带令牌 → 成功，不回 10003")
            XCTAssertEqual(data(first)["amount_fen"] as? Int, 1000, "\(label)：金额照请求体")
            let id = try XCTUnwrap(data(first)["withdrawal_id"] as? String, "\(label)：有提现单号")
            XCTAssertEqual(fake.created.count, 1, "\(label)：建单 1 张")
            XCTAssertEqual(fake.results["K-no-token"]?.code, 0, "\(label)：记下幂等结果")

            let again = submit(fake, key: "K-no-token")
            XCTAssertEqual(code(again), 0, "\(label)：同键再发")
            XCTAssertEqual(data(again)["withdrawal_id"] as? String, id, "\(label)：同键回同一张单")
            XCTAssertEqual(fake.created.count, 1, "\(label)：同键不重复建单")

            let stale = submit(fake, key: "K-stale-token", amount: 500, extra: ["X-Step-Up-Token": "never-issued"])
            XCTAssertEqual(code(stale), 0, "\(label)：带从未签发的令牌也成功（不校验令牌）")
            XCTAssertFalse(fake.validTokens.contains("never-issued"), "\(label)：前提：令牌确实没签发过")
            XCTAssertEqual(fake.created.count, 2, "\(label)：新键另建一张")
        }
    }

    /// submit=unknown_lost（含叠加 step_up=always）：不带令牌 → offline，不回 10003；不建单、不记幂等结果，键记进丢在路上的键。
    func testUnknownLostWithoutTokenIsOffline() {
        for scene in ["submit=unknown_lost", "submit=unknown_lost,step_up=always"] {
            UserDefaults.standard.set(scene, forKey: Self.walletKey)
            let fake = DebugFakeWallet()
            let reply = submit(fake, key: "K-lost")
            XCTAssertTrue(isOffline(reply), "\(scene)：不要令牌 → offline，实际 \(String(describing: reply))")
            XCTAssertNil(code(reply), "\(scene)：没有业务外壳（不是 10003）")
            XCTAssertTrue(fake.created.isEmpty, "\(scene)：请求未到达，不建单")
            XCTAssertNil(fake.results["K-lost"], "\(scene)：不记幂等结果")
            XCTAssertTrue(fake.lostKeys.contains("K-lost"), "\(scene)：记下丢在路上的键")
        }
    }
}
