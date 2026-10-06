import Foundation
import Generated
@testable import Network
import XCTest

/// 21：有明确动作的错误码不降成 Toast（逐项对照 error-codes.yaml 的 action 列）。
final class ErrorActionExplicitActionTests: XCTestCase {
    private func map(_ code: Int, data: [String: Any] = [:], operation: String = "getMe") throws -> ErrorEffect {
        ErrorActionMapper.map(ErrorActionInput(
            code: code, data: data, operation: try XCTUnwrap(ApiOperations.byId(operation)), headers: [:],
            isReplay: false, state: ErrorActionState(update: "supported", sessionScope: "full", appVersion: "1.2.0")
        ))
    }

    func test30144RefetchesProductOrShowsEmptyStateOnLinkLanding() throws {
        let effect = try map(30144, operation: "openLink")
        XCTAssertEqual(effect.effectKindRaw, "refetch_product")
        XCTAssertEqual(effect.replay, ReplayMode.none, "管线不自动重放")
        let landing = ErrorActionMapper.map(ErrorActionInput(
            code: 30144, data: [:], operation: try XCTUnwrap(ApiOperations.byId("openLink")), headers: [:],
            isReplay: false, state: ErrorActionState(update: "supported", sessionScope: "full", appVersion: "1.2.0"),
            fromProductCard: false
        ))
        XCTAssertEqual(landing.effectKindRaw, "page_action")
        XCTAssertEqual(landing.action, ErrorPageAction.emptyState)
        XCTAssertEqual(landing.replay, ReplayMode.none, "LinkLanding 不自动重试")
    }

    func test30144OnLinkAndSharePageIsAlwaysPageAction() throws {
        for operation in ["getLink", "getSharePage"] {
            let effect = try map(30144, operation: operation)
            XCTAssertEqual(effect.effectKindRaw, "page_action", operation)
            XCTAssertEqual(effect.replay, ReplayMode.none, operation)
        }
    }

    func testLinkLanding30144UsesLinkLandingText() throws {
        let landing = ErrorActionMapper.map(ErrorActionInput(
            code: 30144, data: [:], operation: try XCTUnwrap(ApiOperations.byId("openLink")), headers: [:],
            isReplay: false, state: ErrorActionState(update: "supported", sessionScope: "full", appVersion: "1.2.0"),
            fromProductCard: false
        ))
        XCTAssertEqual(landing.textKey, "link_landing.invalid")
        XCTAssertEqual(try map(30144, operation: "openLink").textKey, "error.30144", "商品卡重取继续用 error.30144")
    }

    /// R2-06：20001 / 20004 输出裁定的 Effect kind（field_error、reread_device_hash、reauthorize），不是 page_action /
    /// guide_only 加近似的 action。
    func test20001IsFieldErrorEffectWithFields() throws {
        let effect = try map(20001, data: ["fields": ["phone"], "reason": "phone_invalid"], operation: "sendSmsCode")
        XCTAssertEqual(effect.kind, .fieldError)
        XCTAssertEqual(effect.effectKindRaw, "field_error")
        XCTAssertNil(effect.action)
        XCTAssertEqual(effect.fields, ["phone"])
        XCTAssertEqual(effect.replay, ReplayMode.none)
        let device = try map(20001, data: ["fields": ["device_hash"]], operation: "registerDevice")
        XCTAssertEqual(device.effectKindRaw, "reread_device_hash")
        XCTAssertEqual(device.fields, ["device_hash"])
        XCTAssertNil(device.textKey, "device_hash 不向用户提示")
        XCTAssertEqual(device.replay, ReplayMode.none)
    }

    func test20004IsReauthorizeBackToLoginOrStepUpPanel() throws {
        let login = try map(20004, operation: "loginByWechat")
        XCTAssertEqual(login.effectKindRaw, "reauthorize")
        XCTAssertEqual(login.route, "Login")
        XCTAssertEqual(login.replay, ReplayMode.none)
        let stepUp = try map(20004, operation: "stepUp")
        XCTAssertEqual(stepUp.effectKindRaw, "reauthorize")
        XCTAssertNil(stepUp.route, "回到二次验证面板（不是路由）")
        XCTAssertNil(stepUp.action)
        XCTAssertFalse(stepUp.registerPending)
        XCTAssertEqual(stepUp.replay, ReplayMode.none)
    }

    func test40901KeepsLoading() throws {
        XCTAssertEqual(try map(40901, operation: "createWithdrawal").effectKindRaw, "keep_loading")
    }

    func testSharedLocalRejectReasonNames() {
        XCTAssertEqual(LocalRejectReason.callCancelled, "call_cancelled", "R2-06：隐私或环境世代变化")
        XCTAssertEqual(LocalRejectReason.accountUnknown, "account_unknown")
        XCTAssertEqual(LocalRejectReason.pendingStoreFailed, "pending_store_failed")
        XCTAssertEqual(LocalRejectReason.accountMismatch, "account_mismatch")
        XCTAssertEqual(LocalRejectReason.sessionChanged, "session_changed")
        XCTAssertEqual(LocalRejectReason.sessionCleared, "session_cleared")
        XCTAssertEqual(LocalRejectReason.pendingKeyUnresolved, "pending_key_unresolved")
        XCTAssertEqual(ErrorEffectKind.clearSessionLogin.rawValue, "clear_session_login")
        XCTAssertEqual(ErrorEffectKind.clearSessionStayForceUpdate.rawValue, "clear_session_stay_force_update")
    }

    func test30306DisablesWithdrawButton() throws {
        let effect = try map(30306, operation: "createWithdrawal")
        XCTAssertEqual(effect.kind, .disableButton)
        XCTAssertNil(effect.disableMillis)
    }

    func testPayoutAndRealNameCodesOnlyGuide() throws {
        for code in [30304, 30305, 30307, 30308] {
            for operation in ["createWithdrawal", "getMe"] {
                let effect = try map(code, operation: operation)
                XCTAssertEqual(effect.kind, .guideOnly, "\(code) \(operation)")
                XCTAssertEqual(effect.replay, ReplayMode.none, "\(code) \(operation)")
                XCTAssertFalse(effect.registerPending, "\(code) \(operation)")
            }
        }
    }

    func testCodesWithExplicitActionsAreNotToasts() throws {
        // error-codes.yaml 里动作不是「仅提示 / 提示重新输入 / 按 reason 提示」的码。
        let explicit = [
            10001, 10002, 10003, 10004, 10005, 10006, 10007, 10402, 10404, 10405, 20004, 20901, 20902,
            30101, 30102, 30103, 30104, 30111, 30121, 30132, 30141, 30143, 30144, 30151, 30153, 30205, 30206,
            30302, 30304, 30305, 30306, 30307, 30308, 30309, 30408, 30413, 30416, 30501, 30502, 30504, 30505,
            30506, 30602, 30701, 30802, 30803, 30804, 40901, 42901, 44001, 44003, 50001, 50301, 50302, 50303,
            50304, 50305, 50401,
        ]
        for code in explicit {
            let effect = try map(code)
            XCTAssertNotEqual(effect.kind, .toast, "\(code)")
            XCTAssertNotEqual(effect.kind, .fallbackMessage, "\(code)")
            if effect.kind == .pageAction {
                XCTAssertNotNil(effect.action, "\(code) 要给出具体界面动作")
            }
        }
        XCTAssertEqual(try map(30411, data: ["reason": "mergeable"]).action, ErrorPageAction.mergeConfirm)
        XCTAssertEqual(try map(30411).kind, .toast, "30411 无 reason 仅提示")
    }
}
