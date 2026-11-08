@testable import Couli
import CouliNetwork
import Foundation
import Wallet
import WalletCore
import XCTest

/// 编排 D10-1018（评审 r1 S2-3）：提交结果未知（断连）之后再拿到 10405 / 5xxxx / 42901，照错误码表「不结束键」——保留原幂等键，
/// 下一次提交（表单不变）仍用原键；30406（写入幂等结果）作对照，键结束换新键。向量 specs/realname-submit-vectors.json
/// 里带 sequence 的 case，判读见 harnessUnknown。
final class RealnameFundsUnknownKeyTests: RealnameFundsTestCase {
    func testUnknownThenForceUpdateKeepsKey() async throws {
        try await runUnknown("unknown_then_e10405")
    }

    func testUnknownThenServerErrorKeepsKey() async throws {
        try await runUnknown("unknown_then_e50001")
    }

    func testUnknownThenVendorTimeoutKeepsKey() async throws {
        try await runUnknown("unknown_then_e50401")
    }

    func testUnknownThenServiceUnavailableKeepsKey() async throws {
        try await runUnknown("unknown_then_e50301")
    }

    func testUnknownThenRateLimitedKeepsKey() async throws {
        try await runUnknown("unknown_then_e42901")
    }

    func testUnknownThenBusinessErrorEndsKey() async throws {
        try await runUnknown("unknown_then_e30406")
    }

    private func runUnknown(_ name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let vector = try RealnameVectors.named(name)
        let sequence = try XCTUnwrap(vector["sequence"] as? [[String: Any]], file: file, line: line)
        let expect = try XCTUnwrap(vector["expect"] as? [String: Any], file: file, line: line)
        let next = try XCTUnwrap(expect["nextSubmit"] as? String, file: file, line: line)
        scriptUnverifiedThenVerified()
        try script.on("POST \(Self.path)", RealnameVectors.reply(sequence[0]), RealnameVectors.reply(sequence[1]),
                      Self.success)
        let fixture = make()
        let page = try await submitOnce(fixture)
        await waitUntil("\(name)：结果未知后没有恢复可提交", file: file, line: line) { page.submitEnabled }
        submitWithConsent(page)
        await awaitPosts(2, file: file, line: line)
        await quietWindow(1.0)
        XCTAssertFalse(fixture.wallet.realnameVerified(), "\(name)：第 2 次的错误不当成功", file: file, line: line)
        await waitUntil("\(name)：第 2 次后没有恢复可提交", file: file, line: line) {
            page.submitEnabled && !page.gate.active
        }
        XCTAssertTrue(page.submitEnabled, "\(name)：前提（可再提交）不成立", file: file, line: line)
        submitWithConsent(page)
        await awaitPosts(3, file: file, line: line)
        let posts = realnamePosts
        guard posts.count >= 3 else { return }
        XCTAssertEqual(key(posts[0]), key(posts[1]), "\(name)：结果未知后沿用原键（前提）", file: file, line: line)
        XCTAssertTrue(posts[0].body == posts[2].body, "\(name)：表单未改，请求体一致（不打印）", file: file, line: line)
        let same = key(posts[0]) == key(posts[2])
        XCTAssertEqual(same, next == "same_key", "\(name)：第 3 次提交的幂等键应为 \(next)（D10-1018）", file: file,
                       line: line)
        await waitUntil("\(name)：第 3 次成功后没有按已实名", file: file, line: line) {
            fixture.wallet.realnameVerified()
        }
    }
}
