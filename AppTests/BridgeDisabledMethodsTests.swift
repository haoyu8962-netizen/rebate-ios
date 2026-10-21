import BridgeHost
@testable import Couli
import Foundation
import XCTest

/// F-X-24 / B1–B7：真实 BridgeHost.handle 准入与分派；不直接调用新增的禁用判定函数。
@MainActor
final class BridgeDisabledMethodsTests: MeTestCase {
    func testB1DisabledClipboardRejectsBeforeHandlerAndRecordsBridgeCall() async throws {
        let app = make()
        let fixture = try DisabledMethodsFixture(client: app.client, disabled: ["clipboard.read"])
        let reply = try await fixture.call(fixture.makeHost(), method: "clipboard.read")
        assertDisabled(reply)
        XCTAssertEqual(fixture.services.calls, [])
        XCTAssertEqual(fixture.services.rejected.count, 1)
        let event = try XCTUnwrap(fixture.services.rejected.first)
        XCTAssertEqual(event.name, "bridge_call")
        XCTAssertEqual(event.fields["method"], .string("clipboard.read"))
        XCTAssertEqual(event.fields["code"], .integer(90403))
    }

    func testB2DisabledMethodIsAbsentFromNativeCapabilityList() throws {
        let app = make()
        let fixture = try DisabledMethodsFixture(client: app.client, disabled: ["clipboard.read"])
        XCTAssertFalse(fixture.makeHost().declaredMethods.contains("clipboard.read"))
    }

    func testB3OtherSupportedMethodStillSucceeds() async throws {
        let app = make()
        let fixture = try DisabledMethodsFixture(client: app.client, disabled: ["clipboard.read"])
        let reply = try await fixture.call(fixture.makeHost(), method: "app.getEnv")
        XCTAssertEqual(reply["code"] as? Int, 0)
        XCTAssertEqual((reply["data"] as? [String: Any])?["platform"] as? String, "ios")
        XCTAssertEqual(fixture.services.calls, ["app.getEnv"])
        XCTAssertTrue(fixture.services.rejected.isEmpty)
    }

    func testB4DisabledSignedRequestMakesZeroServerRequestsThenRestores() async throws {
        script.ok("POST /v1/orders/claims", "{}")
        let app = make()
        let fixture = try DisabledMethodsFixture(client: app.client, disabled: ["net.signedRequest"])
        let host = fixture.makeHost()
        // 契约 createOrderClaim 的完整合法示例，含必填 paid_date；不是用坏参数触发零请求。
        let body = ["platform": "pdd", "order_no": "231006-1234567890", "paid_date": "2026-10-06"]
        let params: [String: Any] = ["method": "POST", "path": "/v1/orders/claims", "body": body]
        await settle(50)
        let before = WalletStubProtocol.requests.count
        let denied = try await fixture.call(host, method: "net.signedRequest", params: params)
        assertDisabled(denied)
        XCTAssertEqual(fixture.services.calls, [], "禁用在处理器执行之前")
        XCTAssertEqual(WalletStubProtocol.requests.count, before, "整条代发链路零新增请求")
        XCTAssertEqual(requests("POST", "/v1/orders/claims").count, 0)

        // 阳性对照：同一宿主、会话、合法体和假服务，移除名单后确实能发出请求，排除无效夹具导致的假阳性。
        try fixture.update([])
        let allowed = try await fixture.call(host, method: "net.signedRequest", params: params)
        XCTAssertEqual(allowed["code"] as? Int, 0)
        XCTAssertEqual(fixture.services.calls, ["net.signedRequest"])
        XCTAssertEqual(requests("POST", "/v1/orders/claims").count, 1)
        let sent = try XCTUnwrap(requests("POST", "/v1/orders/claims").first)
        XCTAssertEqual(sent.json as? [String: String], body)
    }

    func testB5RemovingMethodRestoresNextCallOnSameHost() async throws {
        let app = make()
        let fixture = try DisabledMethodsFixture(client: app.client, disabled: ["clipboard.read"])
        let host = fixture.makeHost()
        await assertDisabled(try fixture.call(host, method: "clipboard.read"))
        XCTAssertTrue(fixture.services.calls.isEmpty)
        try fixture.update([])
        XCTAssertTrue(host.declaredMethods.contains("clipboard.read"))
        let reply = try await fixture.call(host, method: "clipboard.read")
        XCTAssertEqual(reply["code"] as? Int, 0)
        XCTAssertEqual((reply["data"] as? [String: Any])?["text"] as? String, "fx24-test-clipboard")
        XCTAssertEqual(fixture.services.calls, ["clipboard.read"])
        XCTAssertEqual(fixture.services.rejected.count, 1)
    }

    func testB6UnknownDisabledMethodDoesNotAffectClipboard() async throws {
        let app = make()
        let fixture = try DisabledMethodsFixture(client: app.client, disabled: ["unknown.method"])
        let host = fixture.makeHost()
        XCTAssertTrue(host.declaredMethods.contains("clipboard.read"))
        XCTAssertFalse(host.declaredMethods.contains("unknown.method"), "配置不能凭空新增能力")
        let reply = try await fixture.call(host, method: "clipboard.read")
        XCTAssertEqual(reply["code"] as? Int, 0)
        XCTAssertEqual(fixture.services.calls, ["clipboard.read"])
        XCTAssertTrue(fixture.services.rejected.isEmpty)
    }

    func testB7UnknownCallKeepsExistingUnsupportedCode() async throws {
        let app = make()
        let fixture = try DisabledMethodsFixture(client: app.client, disabled: [])
        let host = fixture.makeHost()
        let baseline = try await fixture.call(host, method: "foo.bar")
        XCTAssertEqual(baseline["code"] as? Int, 90001)
        try fixture.update(["clipboard.read"])
        let reply = try await fixture.call(host, method: "foo.bar")
        XCTAssertEqual(reply["code"] as? Int, 90001)
        XCTAssertEqual(fixture.services.calls, [])
        XCTAssertTrue(fixture.services.rejected.isEmpty, "沿用既有做法：只记录契约内的方法名")
    }

    func testDisabledDuringForceUpdateWaitRejectsBeforeSignedRequestHandler() async throws {
        script.ok("POST /v1/orders/claims", "{}")
        let app = make()
        let fixture = try DisabledMethodsFixture(client: app.client, disabled: [])
        let gate = DisabledMethodsUpdateGate()
        let host = fixture.makeHost(update: { gate.state }, awaitUpdate: { await gate.wait() })
        defer {
            gate.release()
            host.dispose()
        }
        let body = ["platform": "pdd", "order_no": "231006-1234567890", "paid_date": "2026-10-06"]
        let params: [String: Any] = ["method": "POST", "path": "/v1/orders/claims", "body": body]
        let before = WalletStubProtocol.requests.count
        XCTAssertTrue(fixture.store.bridgeDisabledMethods().isEmpty)
        let reply = try await fixture.call(host, method: "net.signedRequest", params: params) {
            await waitUntil("桥调用没有进入强更等待") { gate.isWaiting }
            XCTAssertTrue(gate.isWaiting)
            XCTAssertEqual(host.inFlightCount, 1, "还在桥宿主等待，尚未结算")
            XCTAssertTrue(fixture.services.calls.isEmpty)
            XCTAssertTrue(fixture.services.rejected.isEmpty)
            XCTAssertEqual(WalletStubProtocol.requests.count, before)
            // 在已挂起、处理器尚未开始的窗口内，经真实 ConfigStore 切换生效配置。
            try fixture.update(["net.signedRequest"])
            XCTAssertEqual(fixture.store.bridgeDisabledMethods(), ["net.signedRequest"])
            gate.release()
        }
        assertDisabled(reply)
        XCTAssertTrue(fixture.services.calls.isEmpty, "等待后必须复核，不能首次进入处理器")
        XCTAssertEqual(WalletStubProtocol.requests.count, before, "整条链路零新增服务端请求")
        XCTAssertEqual(requests("POST", "/v1/orders/claims").count, 0)
        XCTAssertEqual(fixture.services.rejected.count, 1)
        let event = try XCTUnwrap(fixture.services.rejected.first)
        XCTAssertEqual(event.name, "bridge_call")
        XCTAssertEqual(event.fields["method"], .string("net.signedRequest"))
        XCTAssertEqual(event.fields["code"], .integer(90403))

        // 同一宿主和合法参数的阳性对照：移出名单后处理器与生产签名代发链路都可执行。
        try fixture.update([])
        let allowed = try await fixture.call(host, method: "net.signedRequest", params: params)
        XCTAssertEqual(allowed["code"] as? Int, 0)
        XCTAssertEqual(fixture.services.calls, ["net.signedRequest"])
        XCTAssertEqual(requests("POST", "/v1/orders/claims").count, 1)
        XCTAssertEqual(fixture.services.rejected.count, 1)
    }

    func testDisabledLoginRequiredMethodRejectsBeforeLoginCheck() async throws {
        let app = make(account: nil)
        XCTAssertNil(app.client.isolatedAccount)
        let fixture = try DisabledMethodsFixture(client: app.client, disabled: ["auth.getUser"])
        let host = fixture.makeHost()
        let reply = try await fixture.call(host, method: "auth.getUser")
        assertDisabled(reply)
        XCTAssertEqual(fixture.services.calls, [], "不得执行 auth.getUser，也不得触发 auth.login")
        XCTAssertEqual(fixture.services.rejected.count, 1)
        let event = try XCTUnwrap(fixture.services.rejected.first)
        XCTAssertEqual(event.name, "bridge_call")
        XCTAssertEqual(event.fields["method"], .string("auth.getUser"))
        XCTAssertEqual(event.fields["code"], .integer(90403))

        // 相同未登录会话，只有移出禁用名单后才回到原来的登录准入错误。
        try fixture.update([])
        let allowed = try await fixture.call(host, method: "auth.getUser")
        XCTAssertEqual(allowed["code"] as? Int, 90401)
        XCTAssertTrue(fixture.services.calls.isEmpty)
    }

    /// B9 反向：入口先放行，等待中加入再移出；真正执行时应使用最新名单。
    func testB9RemovedDuringForceUpdateWaitExecutesSignedRequestExactlyOnce() async throws {
        script.ok("POST /v1/orders/claims", "{}")
        let app = make()
        let fixture = try DisabledMethodsFixture(client: app.client, disabled: [])
        let gate = DisabledMethodsUpdateGate()
        let host = fixture.makeHost(update: { gate.state }, awaitUpdate: { await gate.wait() })
        defer {
            gate.release()
            host.dispose()
        }
        let body = ["platform": "pdd", "order_no": "231006-1234567890", "paid_date": "2026-10-06"]
        let params: [String: Any] = ["method": "POST", "path": "/v1/orders/claims", "body": body]
        let before = WalletStubProtocol.requests.count
        let reply = try await fixture.call(host, method: "net.signedRequest", params: params) {
            await waitUntil("B9 调用没有进入强更等待") { gate.isWaiting }
            XCTAssertTrue(gate.isWaiting)
            try fixture.update(["net.signedRequest"])
            XCTAssertEqual(fixture.store.bridgeDisabledMethods(), ["net.signedRequest"])
            try fixture.update([])
            XCTAssertTrue(fixture.store.bridgeDisabledMethods().isEmpty)
            XCTAssertTrue(gate.isWaiting, "移出名单时调用仍须挂在强更等待里")
            XCTAssertEqual(host.inFlightCount, 1)
            XCTAssertTrue(fixture.services.calls.isEmpty)
            XCTAssertTrue(fixture.services.rejected.isEmpty)
            XCTAssertEqual(WalletStubProtocol.requests.count, before)
            gate.release()
        }
        XCTAssertEqual(reply["code"] as? Int, 0)
        XCTAssertEqual(fixture.services.calls, ["net.signedRequest"])
        XCTAssertTrue(fixture.services.rejected.isEmpty)
        XCTAssertEqual(requests("POST", "/v1/orders/claims").count, 1)
        XCTAssertEqual(requests("POST", "/v1/orders/claims").first?.json as? [String: String], body)
    }

    /// B9 入口拒绝分支：禁用时已经结算，之后移出不能排队补执行。
    func testB9EntryRejectionNeverQueuesExecutionAfterRemoval() async throws {
        script.ok("POST /v1/orders/claims", "{}")
        let app = make()
        let fixture = try DisabledMethodsFixture(client: app.client, disabled: ["net.signedRequest"])
        let gate = DisabledMethodsUpdateGate()
        let host = fixture.makeHost(update: { gate.state }, awaitUpdate: { await gate.wait() })
        defer {
            gate.release()
            host.dispose()
        }
        let body = ["platform": "pdd", "order_no": "231006-1234567890", "paid_date": "2026-10-06"]
        let params: [String: Any] = ["method": "POST", "path": "/v1/orders/claims", "body": body]
        let before = WalletStubProtocol.requests.count
        let reply = try await fixture.call(host, method: "net.signedRequest", params: params)
        assertDisabled(reply)
        XCTAssertFalse(gate.isWaiting, "入口已拒绝，不应进入强更等待")
        try fixture.update([])
        gate.release()
        await settle()
        XCTAssertEqual(host.inFlightCount, 0)
        XCTAssertTrue(fixture.services.calls.isEmpty)
        XCTAssertEqual(WalletStubProtocol.requests.count, before)
        XCTAssertEqual(requests("POST", "/v1/orders/claims").count, 0)
        XCTAssertEqual(fixture.services.rejected.count, 1)

        // 只有页面重新发起的新调用才可以执行，旧调用不能跟着补跑。
        let allowed = try await fixture.call(host, method: "net.signedRequest", params: params)
        XCTAssertEqual(allowed["code"] as? Int, 0)
        XCTAssertEqual(fixture.services.calls, ["net.signedRequest"])
        XCTAssertEqual(requests("POST", "/v1/orders/claims").count, 1)
        XCTAssertEqual(fixture.services.rejected.count, 1)
    }

    func testUnknownDisabledMethodRejectsBeforeUnsupportedCheck() async throws {
        let app = make()
        let fixture = try DisabledMethodsFixture(client: app.client, disabled: ["foo.bar"])
        let host = fixture.makeHost()
        XCTAssertFalse(host.declaredMethods.contains("foo.bar"), "禁用配置不能创造能力")
        let reply = try await fixture.call(host, method: "foo.bar")
        assertDisabled(reply)
        XCTAssertTrue(fixture.services.calls.isEmpty)
        XCTAssertTrue(fixture.services.rejected.isEmpty, "沿用只记录契约方法的埋点范围")

        try fixture.update([])
        let allowed = try await fixture.call(host, method: "foo.bar")
        XCTAssertEqual(allowed["code"] as? Int, 90001)
        XCTAssertTrue(fixture.services.calls.isEmpty)
        XCTAssertTrue(fixture.services.rejected.isEmpty)
    }

    private func assertDisabled(_ reply: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(reply["code"] as? Int, 90403, file: file, line: line)
        XCTAssertEqual((reply["data"] as? [String: Any])?["reason"] as? String,
                       "method_disabled", file: file, line: line)
    }
}
