@testable import Couli
import CouliNetwork
import Foundation
import Me
@testable import MeCore
import Router
import XCTest

/// FU-IOS-0713 第 3 版（T-11）：申诉列表与风险说明附加读取的响应首次遇身份未知。getMe 正常完成，单独挂住附加读取；放行时注入单次 /
/// 持续读取失败（按读取位置遍历），结算后撤掉；之后只经生产身份确认入口 `syncIdentity` → 自动恢复并显示实际内容，不点【重试】。
extension FollowupIos0713MeTests {
    /// 假服务挂住的请求里，路径为 `path` 的那一个。
    func held(_ path: String) throws -> Int {
        let ids = Set(WalletStubProtocol.heldIds)
        return try XCTUnwrap(WalletStubProtocol.requests.first { ids.contains($0.id) && $0.path == path }?.id,
                             "\(path) 没有挂住")
    }

    static let withdrawalsBody = "{\"items\":[\(WalletSamples.withdrawal("W1"))],\"next_cursor\":null}"

    /// 申诉列表响应首次遇身份未知：页面结算（不停在加载中）后撤掉故障；只经 `syncIdentity` → 显示实际申诉结论（维持原处理结果、列表一条）。
    func testAppealListResponseAtUnknownIdentityRecoversOnConfirmation() async throws {
        try await forEachReadPosition("申诉列表响应") { fault, nth in
            let tag = "申诉列表响应/\(fault.rawValue)#\(nth)"
            script.ok("GET /v1/me", Self.banned)
            script.on("GET /v1/me/appeals", .hold, .envelope(code: 0, data: Self.upheld, headers: [:]))
            let fixture = fresh(tag)
            let entry = try XCTUnwrap(fixture.open(AppMe.appeal))
            entry.appeared()
            let controller = try XCTUnwrap(entry.controller() as? AppealController)
            await waitUntil("\(tag)：申诉列表没有挂住") { WalletStubProtocol.heldIds.count == 1 }
            let list = try held("/v1/me/appeals")
            let window = FaultWindow(fixture.store)
            window.begin(fault, nth)
            WalletStubProtocol.release(list, with: .envelope(code: 0, data: Self.upheld, headers: [:]))
            await waitUntil("\(tag)：列表响应回来后停在加载中（无出口）") { controller.state.phase != .loading }
            let used = window.end()
            fixture.me.syncIdentity()
            await waitUntil("\(tag)：身份确认后没有自动显示申诉结论") { controller.state.phase == .content }
            assertActualContent(controller, tag)
            return used
        }
    }

    /// 风险说明附加读取（申诉摘要、进行中的提现）响应首次遇身份未知：说明内容正常，单独挂住两个附加读取；放行时注入故障，等页面空闲后
    /// 撤掉；只经 `syncIdentity` → 显示「最近一次申诉：维持原处理结果」与进行中的提现 W1。
    func testRiskSectionResponsesAtUnknownIdentityRecoverOnConfirmation() async throws {
        try await forEachReadPosition("风险说明附加读取") { fault, nth in
            let tag = "风险说明附加读取/\(fault.rawValue)#\(nth)"
            script.ok("GET /v1/me", Self.banned)
            script.on("GET /v1/me/appeals", .hold, .envelope(code: 0, data: Self.upheld, headers: [:]))
            script.on("GET /v1/withdrawals", .hold, .envelope(code: 0, data: Self.withdrawalsBody, headers: [:]))
            let fixture = fresh(tag)
            let entry = try XCTUnwrap(fixture.open(AppMe.riskNotice))
            entry.appeared()
            let controller = try XCTUnwrap(entry.controller() as? RiskNoticeController)
            await waitUntil("\(tag)：附加读取没有挂住") {
                controller.state.phase == .content && WalletStubProtocol.heldIds.count == 2
            }
            let appeals = try held("/v1/me/appeals")
            let withdrawals = try held("/v1/withdrawals")
            let window = FaultWindow(fixture.store)
            window.begin(fault, nth)
            WalletStubProtocol.release(appeals, with: .envelope(code: 0, data: Self.upheld, headers: [:]))
            WalletStubProtocol.release(withdrawals, with: .envelope(code: 0, data: Self.withdrawalsBody, headers: [:]))
            await controller.whenIdle()
            let used = window.end()
            fixture.me.syncIdentity()
            await waitUntil("\(tag)：身份确认后附加读取没有自动恢复") {
                controller.model()?.upheldLine == true && controller.state.withdrawals.map(\.id) == ["W1"]
            }
            XCTAssertEqual(controller.state.phase, .content, "\(tag)：说明内容保留")
            return used
        }
    }
}
