import Foundation
import Generated
@testable import Network
import XCTest

/// FU-X-HOME-PAGE-API-ios D10-607 ②：基本模式匿名白名单（BR-ID-11）恰好多出首页两个接口；基本模式与撤回清理未完成（凭据不可读）时
/// 两个接口都放行且只带匿名公共头，其余照旧。对应安卓 n02–n05。
final class HomePageApiNetworkTests: XCTestCase {
    private let homeOperations = ["getPage", "listPageSectionItems"]

    private func state(privacy: String, readable: Bool = true) -> NetworkRequestState {
        NetworkRequestState(
            privacy: privacy, sessionScope: "full", hasAccessToken: true, deviceId: "dev-1",
            environmentSettled: true, credentialsReadable: readable
        )
    }

    private func operation(_ id: String) throws -> ApiOperation {
        try XCTUnwrap(ApiOperations.byId(id), "\(id) 不在生成表（listPageSectionItems 要升锁 00deded0ef6f）")
    }

    /// n02 白名单 = 原有 4 个 + getPage + listPageSectionItems，不多不少。
    func testBasicModeAllowlistGainsExactlyTheTwoHomeOperations() {
        XCTAssertEqual(
            RequestHeaderPolicy.basicModeAllowed,
            ["getConfig", "searchProducts", "getProduct", "listArticles", "getPage", "listPageSectionItems"]
        )
    }

    /// n03 基本模式、撤回清理未完成：两个首页接口放行，只带匿名公共头（无 Authorization、X-Device-Id、签名、Idempotency-Key）。
    func testHomeOperationsPassAnonymouslyInBasicModeAndWhileCredentialsUnreadable() throws {
        for (label, state) in [
            ("基本模式", state(privacy: PrivacyRaw.basic)),
            ("撤回清理未完成", state(privacy: PrivacyRaw.full, readable: false)),
        ] {
            for id in homeOperations {
                let decision = RequestHeaderPolicy.decide(state: state, operation: try operation(id))
                XCTAssertTrue(decision.send, "\(label) \(id) 被拦")
                XCTAssertFalse(decision.includeAuthorization, "\(label) \(id)")
                XCTAssertFalse(decision.includeDeviceId, "\(label) \(id)")
                XCTAssertEqual(Set(decision.headerNames), Set(HeaderNames.anonymous), "\(label) \(id) 只带匿名公共头")
            }
            // 对照：白名单外的接口仍拒绝
            let other = RequestHeaderPolicy.decide(state: state, operation: try operation("getMe"))
            XCTAssertFalse(other.send, "\(label) getMe 被放行")
            XCTAssertEqual(other.localRejectReason, LocalRejectReason.basicModeDenied)
        }
    }

    /// n04 已同意：两个首页接口带 Authorization 与 X-Device-Id（契约：按设备分桶读灰度版本），不签名。
    func testConsentedHomeOperationsCarryCredentials() throws {
        for id in homeOperations {
            let decision = RequestHeaderPolicy.decide(
                state: state(privacy: PrivacyRaw.full),
                operation: try operation(id)
            )
            XCTAssertTrue(decision.send, id)
            XCTAssertTrue(decision.includeAuthorization, id)
            XCTAssertTrue(decision.includeDeviceId, id)
            XCTAssertFalse(decision.includeSignature, id)
        }
    }

    /// n05 隐私未决定的白名单不放宽（仍只有 getConfig、listArticles）；首页两接口在未决定时仍拒绝。
    func testUndecidedAllowlistIsUnchanged() throws {
        XCTAssertEqual(RequestHeaderPolicy.undecidedAllowed, ["getConfig", "listArticles"])
        for id in homeOperations {
            XCTAssertFalse(
                RequestHeaderPolicy.decide(state: state(privacy: PrivacyRaw.undecided), operation: try operation(id))
                    .send,
                id
            )
        }
    }
}
