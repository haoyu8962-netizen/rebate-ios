import Foundation
import Generated
@testable import Network
import XCTest

/// CT-LOCK-02（契约升版到 rebate-platform a7c9f1f）：x-auth 新取值 phone（生成器放行）、新增客户端接口只登记不接、
/// 后台专用错误码进表、recordConsent 错误码表扩充。
final class CtLock02ContractUpgradeTests: XCTestCase {
    private let fullState = NetworkRequestState(
        privacy: PrivacyRaw.full, sessionScope: "full", hasAccessToken: true, deviceId: "dev-1",
        environmentSettled: true, credentialsReadable: true
    )

    /// x-auth: phone 的三个新接口：已登记、未接（无调用方）；请求头策略与 login 一样带 Authorization（只按 auth != none 判定）。
    func testPhoneAuthOperationsAreRegisteredAndTreatedAsAuthenticated() throws {
        let expected: [[String]] = [
            ["bindInviter", "POST", "/v1/me/inviter"],
            ["getMyInvite", "GET", "/v1/invites/me"],
            ["submitRealname", "POST", "/v1/me/realname"],
        ]
        for row in expected {
            let operation = try XCTUnwrap(ApiOperations.byId(row[0]), row[0])
            XCTAssertEqual(operation.method, row[1], row[0])
            XCTAssertEqual(operation.pathTemplate, row[2], row[0])
            XCTAssertEqual(operation.auth, "phone", row[0])
            let decision = RequestHeaderPolicy.decide(state: fullState, operation: operation, body: [:])
            XCTAssertTrue(decision.includeAuthorization, row[0])
        }
        // #24 test-change（升锁 00deded0ef6f）：新锁新增 createShare（x-auth phone），本端不调用；其余判据不变
        let createShare = try XCTUnwrap(ApiOperations.byId("createShare"))
        XCTAssertEqual(createShare.auth, "phone")
        XCTAssertTrue(RequestHeaderPolicy.decide(state: fullState, operation: createShare, body: [:])
            .includeAuthorization)
        XCTAssertEqual(ApiOperations.all.values.filter { $0.auth == "phone" }.count, expected.count + 1)
        XCTAssertEqual(
            Set(ApiOperations.all.values.map(\.auth)), ["none", "optional", "login", "phone", "realname"],
            "仍无 admin / super"
        )
    }

    /// 新增 24 个客户端 operation 全部登记（只生成不接）；/admin/ 仍排除；既有 62 个一个不少（62 + 24 = 86）。
    func testNewClientOperationsAreRegisteredAndAdminStillExcluded() {
        let added = [
            "mergeAccount", "createOrderClaim", "listOrderClaims", "getAgreements", "getPage", "listMessages",
            "markMessagesRead", "getUnreadMessageCount", "updateMe", "bindInviter", "getMyInvite", "sendLandingSmsCode",
            "landingRegister", "submitRealname", "getLaborAgreement", "signLaborAgreement", "getNotificationSettings",
            "updateNotificationSettings", "getDict", "getProductPriceTrend", "listFavorites", "addFavorite",
            "removeFavorite", "batchDeleteFavorites",
        ]
        // #24 test-change（FU-X-HOME-PAGE-API-ios 升锁 00deded0ef6f）：再新增 15 个（86 → 101，只增不删；安卓 U1 同口径，编排 11-04 15:01）
        let addedByLock00deded = [
            "getAgreementVersion", "listPageSectionItems", "createPayOrder", "getPayOrder", "payOrderReturned",
            "cancelPayOrder", "getReverify", "reverifyByIdNumber", "reverifyByOauth", "bindOauthIdentity",
            "listMyDataCopies", "getMyDataCopyDownload", "getHotRank", "getSearchHotWords", "createShare",
        ]
        // #24 test-change（FU-X-CTA-KEY-DRIFT-ios 升锁 a89c1ec3a，D10-857）：再新增 2 个（101 → 103，只增不删）
        let addedByLockA89c1ec = ["submitProductFeedback", "openProductShop"]
        XCTAssertEqual(ApiOperations.byId("submitProductFeedback")?.auth, "optional")
        XCTAssertEqual(ApiOperations.byId("openProductShop")?.auth, "login")
        for id in added + addedByLock00deded + addedByLockA89c1ec {
            XCTAssertNotNil(ApiOperations.byId(id), id)
        }
        XCTAssertEqual(ApiOperations.all.count, 103)
        XCTAssertFalse(ApiOperations.all.values.contains { $0.pathTemplate.hasPrefix("/admin/") })
    }

    /// recordConsent 的 x-error-codes 加 10401 / 10402（请求体 version 改 integer | string，本端只发整数，不受影响）。
    func testRecordConsentErrorCodes() throws {
        let operation = try XCTUnwrap(ApiOperations.byId("recordConsent"))
        XCTAssertEqual(operation.errorCodes, [20001, 10401, 10402, 10405])
        XCTAssertEqual(operation.auth, "optional")
        XCTAssertFalse(operation.planned)
    }

    private func map(_ code: Int, data: [String: Any] = [:], operation: String = "getMe") throws -> ErrorEffect {
        ErrorActionMapper.map(ErrorActionInput(
            code: code, data: data, operation: try XCTUnwrap(ApiOperations.byId(operation)), headers: [:],
            isReplay: false, state: ErrorActionState(update: "supported", sessionScope: "full", appVersion: "1.2.0")
        ))
    }

    /// 编排口径：表内但无用户侧文案的码按表外码处理（服务端 msg）。30154 / 30417 / 44004 与表外 39999 / 49999 同一结果，
    /// 不会因进表从「回落」变成「Toast + 空文案键」。
    func testAdminOnlyTextlessCodesFallBackLikeUnlistedCodes() throws {
        XCTAssertNil(ErrorCodes.info(39999))
        XCTAssertNil(ErrorCodes.info(49999))
        for operation in ["getMe", "openLink", "createWithdrawal"] {
            for (code, unlisted) in [(30154, 39999), (30417, 39999), (44004, 49999)] {
                let reference = try map(unlisted, operation: operation)
                XCTAssertEqual(reference.kind, .fallbackMessage, "前提：表外码用服务端 msg")
                let effect = try map(code, data: ["status": "failed"], operation: operation)
                XCTAssertEqual(effect.kind, reference.kind, "\(code) \(operation)")
                XCTAssertNil(effect.textKey, "\(code) \(operation)")
                XCTAssertEqual(effect.replay, reference.replay, "\(code) \(operation)")
                XCTAssertEqual(effect.registerPending, reference.registerPending, "\(code) \(operation)")
                XCTAssertEqual(effect.route, reference.route, "\(code) \(operation)")
                XCTAssertEqual(effect.includeTrace6, reference.includeTrace6, "\(code) \(operation)")
                XCTAssertNil(effect.action, "\(code) \(operation)")
            }
        }
    }

    /// 对照：现有码行为不变——无文案的页面自处理码（30505 / 44003）仍是 page_action，置灰码仍置灰，有文案的普通码仍 Toast，
    /// 10008 / 10009 仍回落，20001 的 favorites_full 取子键文案。
    func testExistingCodesKeepTheirEffects() throws {
        XCTAssertEqual(try map(30505).kind, .pageAction)
        XCTAssertEqual(try map(44003).kind, .pageAction)
        XCTAssertEqual(try map(30206).kind, .disableButton)
        XCTAssertEqual(try map(30306).kind, .disableButton)
        let toast = try map(30201)
        XCTAssertEqual(toast.kind, .toast)
        XCTAssertEqual(toast.textKey, "error.30201")
        XCTAssertEqual(try map(10008).kind, .fallbackMessage)
        XCTAssertEqual(try map(10009).kind, .fallbackMessage)
        XCTAssertEqual(try map(20001, data: ["reason": "favorites_full"]).textKey, "error.20001.favorites_full")
    }

    /// 后台专用新码 30154 / 30417 / 44004 进表（never、用户侧字典无文案）；20001 新 reason favorites_full 有子键文案。
    func testNewErrorCodesAndTexts() {
        for code in [30154, 30417, 44004] {
            XCTAssertEqual(ErrorCodes.info(code)?.retryKind, .never, "\(code)")
            XCTAssertNil(DefaultTexts.text("error.\(code)"), "\(code)")
        }
        XCTAssertNotNil(DefaultTexts.text("error.20001.favorites_full"))
    }
}
