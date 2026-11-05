import Foundation
import Generated
@testable import Network
import XCTest

/// CT-LOCK-01（契约升版到 rebate-platform 40cfc268）：错误码表新增 10008 / 10009、30102 / 30111 的 sharer_auth_invalid、
/// 生成器排除 /admin/ 与 Agent 接口只登记。
final class CtLock01ContractUpgradeTests: XCTestCase {
    private func map(_ code: Int, data: [String: Any] = [:], operation: String = "getMe") throws -> ErrorEffect {
        ErrorActionMapper.map(ErrorActionInput(
            code: code, data: data, operation: try XCTUnwrap(ApiOperations.byId(operation)), headers: [:],
            isReplay: false, state: ErrorActionState(update: "supported", sessionScope: "full", appVersion: "1.2.0")
        ))
    }

    /// 10008 / 10009 只出现在 /admin/v1：进了表、用户侧字典没有文案键。
    func testAdminOnlyCodesAreInTheTableWithoutUserTexts() {
        XCTAssertNotNil(ErrorCodes.info(10008))
        XCTAssertNotNil(ErrorCodes.info(10009))
        XCTAssertNil(ErrorCodes.info(19999), "对照码 19999 仍是表外码")
        XCTAssertNil(DefaultTexts.text("error.10008"))
        XCTAssertNil(DefaultTexts.text("error.10009"))
    }

    /// 10008 / 10009 与表外 1xxxx（19999）同一回落：用服务端 msg，不写专门分流。
    func testAdminOnlyCodesFallBackLikeUnlistedAuthCodes() throws {
        for operation in ["getMe", "openLink", "createWithdrawal"] {
            let reference = try map(19999, operation: operation)
            XCTAssertEqual(reference.kind, .fallbackMessage, "前提：表外 1xxxx 用服务端 msg")
            for code in [10008, 10009] {
                let effect = try map(code, data: ["locked_until": "2026-10-14T12:00:00+08:00"], operation: operation)
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

    /// 回落只针对没有文案键的 1xxxx：有 error.<code> 的表内码（10401 / 10403）仍是 Toast。
    func testTextedAuthCodesWithoutDedicatedBranchStillToast() throws {
        for code in [10401, 10403] {
            let effect = try map(code)
            XCTAssertEqual(effect.kind, .toast, "\(code)")
            XCTAssertEqual(effect.textKey, "error.\(code)", "\(code)")
        }
    }

    /// 生成表：30102 / 30111 的 sharer_auth_invalid 重试类别为 never。
    func testGeneratedTableCarriesSharerAuthInvalidReason() {
        XCTAssertEqual(ErrorCodes.info(30102)?.retryKindByReason["sharer_auth_invalid"], .never)
        XCTAssertEqual(ErrorCodes.info(30111)?.retryKindByReason["sharer_auth_invalid"], .never)
        XCTAssertTrue(ErrorActionMapper.promptOnlyReason(code: 30102, reason: "sharer_auth_invalid"))
        XCTAssertTrue(ErrorActionMapper.promptOnlyReason(code: 30111, reason: "sharer_auth_invalid"))
        XCTAssertFalse(ErrorActionMapper.promptOnlyReason(code: 30102, reason: nil))
        XCTAssertFalse(ErrorActionMapper.promptOnlyReason(code: 30111, reason: "no_such_reason"))
    }

    /// 30102 / 30111 带 sharer_auth_invalid：只提示，不弹授权、不登记待办、不重放（含 step-up 操作）。
    func testSharerAuthInvalidReasonOnlyPromptsWithoutAuthorizeOrReplay() throws {
        for code in [30102, 30111] {
            for operation in ["openLink", "getSharePage", "createWithdrawal"] {
                let effect = try map(code, data: ["reason": "sharer_auth_invalid"], operation: operation)
                XCTAssertEqual(effect.kind, .toast, "\(code) \(operation)")
                XCTAssertEqual(effect.replay, ReplayMode.none, "\(code) \(operation)")
                XCTAssertFalse(effect.registerPending, "\(code) \(operation)")
                XCTAssertNil(effect.route, "\(code) \(operation)")
                XCTAssertEqual(effect.textKey, "error.\(code)", "字典没有子键，回落 error.<code>")
            }
        }
    }

    /// 无 reason（或表里没有的 reason）的授权流程不变：AuthSheet、新键、登记待办；step-up 操作只引导。
    func testAuthorizationCodesWithoutATableReasonKeepTheAuthorizeFlow() throws {
        for code in [30101, 30102, 30111] {
            for data: [String: Any] in [[:], ["reason": "no_such_reason"]] {
                let effect = try map(code, data: data, operation: "openLink")
                XCTAssertEqual(effect.kind, .authorize, "\(code) \(data)")
                XCTAssertEqual(effect.replay, .newKey, "\(code) \(data)")
                XCTAssertTrue(effect.registerPending, "\(code) \(data)")
                XCTAssertEqual(effect.route, "AuthSheet", "\(code) \(data)")
            }
            XCTAssertEqual(try map(code, operation: "createWithdrawal").kind, .guideOnly, "\(code)")
        }
        XCTAssertEqual(try map(30101, data: ["reason": "auth_unavailable"], operation: "openLink").kind, .toast)
    }

    /// 生成器排除 /admin/ 前缀：登记表没有后台接口；Agent 6 条路径 7 个 operation 已登记、planned（只生成不接线）。
    func testOperationRegistryHasNoAdminPathsAndListsTheAgentOperations() throws {
        XCTAssertFalse(ApiOperations.all.values.contains { $0.pathTemplate.hasPrefix("/admin/") })
        XCTAssertFalse(ApiOperations.all.values.contains { ["admin", "super"].contains($0.auth) })
        // #24 test-change（FU-X-HOME-PAGE-API-ios 升锁 00deded0ef6f）：新锁 planned 逐个钉——4 个已实现（false）、3 个仍 planned（true），
        // 与安卓 U3（编排 11-04 15:01）同口径；路径与方法不变
        let planned: [String: Bool] = [
            "createAgentSession": false, "getCurrentAgentSession": false, "listAgentSessionMessages": true,
            "sendAgentMessage": false, "cancelAgentRun": false, "setAgentMessageFeedback": true,
            "reportAgentMessage": true,
        ]
        let expected: [[String]] = [
            ["createAgentSession", "POST", "/v1/agent/sessions"],
            ["getCurrentAgentSession", "GET", "/v1/agent/sessions/current"],
            ["listAgentSessionMessages", "GET", "/v1/agent/sessions/{id}/messages"],
            ["sendAgentMessage", "POST", "/v1/agent/sessions/{id}/messages"],
            ["cancelAgentRun", "POST", "/v1/agent/runs/{run_id}/cancel"],
            ["setAgentMessageFeedback", "POST", "/v1/agent/messages/{message_id}/feedback"],
            ["reportAgentMessage", "POST", "/v1/agent/messages/{message_id}/report"],
        ]
        for row in expected {
            let (operationId, method, path) = (row[0], row[1], row[2])
            let operation = try XCTUnwrap(ApiOperations.byId(operationId), operationId)
            XCTAssertEqual(operation.method, method, operationId)
            XCTAssertEqual(operation.pathTemplate, path, operationId)
            XCTAssertEqual(operation.planned, planned[operationId], operationId)
        }
        let agent = ApiOperations.all.values.filter { $0.pathTemplate.hasPrefix("/v1/agent/") }
        XCTAssertEqual(agent.count, expected.count)
        XCTAssertEqual(Set(agent.map(\.pathTemplate)).count, 6)
    }
}
