@testable import BridgeHost
import Foundation
import XCTest

/// APP-05a iOS 第 1 轮评审 R1-05（APP-04 三端共性第 63、65 条）：nav.open 收到时记下的强更状态只是起点；执行导航前重新绑定
/// 当前这一轮版本检查——其间进入新一轮检查中就重新等这一轮，状态一直不稳定就取消，不补执行。
@MainActor
final class BridgeNavRebindTests: XCTestCase {
    private let origin = "https://h5.example.test"
    private var update = BridgeUpdateState.supported
    private let services = NavServices()
    private let ui = NavUI()

    private func makeHost(awaitUpdate: @escaping @MainActor () async -> String) -> BridgeHost {
        BridgeHost(
            protocol: { [origin] in BridgeProtocol(trustedOrigins: [origin], linkPatterns: [:], shareDomains: []) },
            caller: { [unowned self] in
                BridgeCallerState(privacy: BridgePrivacy.consented, accountKey: "u1#1", update: update)
            },
            services: services,
            ui: ui,
            awaitUpdate: awaitUpdate
        )
    }

    private func navOpen(_ host: BridgeHost, id: String) -> NavReply {
        let reply = NavReply()
        let raw = #"{"v":1,"id":"\#(id)","method":"nav.open","params":{"route":"Search"}}"#
        host.handle(raw: raw, origin: origin, isMainFrame: true, userGesture: true) { reply.values.append($0) }
        return reply
    }

    private func settle() async {
        for _ in 0..<40 {
            await Task.yield()
        }
    }

    /// 收到时 supported，执行前进入新一轮检查中：不沿用旧的 supported，重新等这一轮；等满 5 秒按未知，只开只读页面。
    func testNewCheckingRoundBeforeRunIsAwaited() async {
        var waits = 0
        let host = makeHost(awaitUpdate: {
            waits += 1
            return BridgeUpdateState.unknown
        })
        let reply = navOpen(host, id: "n1")
        // 执行任务开始之前，新一轮版本检查开始。
        update = BridgeUpdateState.checking
        await settle()

        XCTAssertEqual(waits, 1, "重新等待当前这一轮检查")
        XCTAssertEqual(services.navCalls.map(\.readOnly), [true], "按这一轮的结论（未知）执行：只开只读页面")
        XCTAssertEqual(reply.values.count, 1)
    }

    /// 收到时 supported，执行前新一轮检查得出低于最低版本：按新结论拒绝（90500），不执行导航。
    func testRebindsToNewConclusion() async {
        let host = makeHost(awaitUpdate: { BridgeUpdateState.below })
        let reply = navOpen(host, id: "n2")
        update = BridgeUpdateState.below
        await settle()

        XCTAssertTrue(services.navCalls.isEmpty)
        XCTAssertEqual(reply.code, BridgeCode.nativeError)
    }

    /// 检查状态反复变化、始终没有稳定的结论：取消（90500），之后状态稳定了也不补执行。
    func testUnstableCheckCancelsWithoutLaterExecution() async {
        var waits = 0
        let host = makeHost(awaitUpdate: {
            waits += 1
            return BridgeUpdateState.supported
        })
        let reply = navOpen(host, id: "n3")
        update = BridgeUpdateState.checking
        await settle()

        XCTAssertEqual(waits, BridgeHost.updateBindAttempts - 1, "每次重新绑定都重新等这一轮，到上限即止")
        XCTAssertEqual(reply.code, BridgeCode.nativeError)
        XCTAssertTrue(services.navCalls.isEmpty)
        update = BridgeUpdateState.supported
        await settle()
        XCTAssertTrue(services.navCalls.isEmpty, "取消后不补执行")
        XCTAssertEqual(reply.values.count, 1)
    }

    /// 状态没变：照常执行一次（不多等）。
    func testStableStateRunsOnce() async {
        var waits = 0
        let host = makeHost(awaitUpdate: {
            waits += 1
            return BridgeUpdateState.supported
        })
        let reply = navOpen(host, id: "n4")
        await settle()

        XCTAssertEqual(waits, 0)
        XCTAssertEqual(services.navCalls.map(\.readOnly), [false])
        XCTAssertEqual(reply.code, BridgeCode.ok)
    }
}

private final class NavReply {
    var values: [String?] = []

    var code: Int? {
        guard let last = values.last, let text = last,
              let body = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        else { return nil }
        return body["code"] as? Int
    }
}

@MainActor
private final class NavUI: BridgeUI {
    func toast(text _: String, long _: Bool) {}
    func showLoading(text _: String?) {}
    func hideLoading() {}
    func setNavBar(_: BridgeNavBar) -> Bool {
        true
    }

    func close() {}
}

@MainActor
private final class NavServices: BridgeServices {
    struct NavCall {
        let route: String
        let readOnly: Bool
    }

    var navCalls: [NavCall] = []

    func env() -> [String: Any] {
        [:]
    }

    func config(keys _: [String]) -> BridgeOutcome {
        .ok()
    }

    func user(validity _: BridgeCallValidity) async -> BridgeOutcome {
        .ok()
    }

    func h5Token(readOnly _: Bool, validity _: BridgeCallValidity) async -> BridgeOutcome {
        .ok()
    }

    func login() async -> BridgeOutcome {
        .ok()
    }

    func signedRequest(
        method _: String,
        path _: String,
        bodyJson _: String?,
        validity _: BridgeCallValidity
    ) async -> BridgeOutcome {
        .ok()
    }

    func navOpen(route: String, paramsJson _: String, readOnlyPagesOnly: Bool) async -> BridgeOutcome {
        navCalls.append(NavCall(route: route, readOnly: readOnlyPagesOnly))
        return .ok(["opened": true])
    }

    func clipboardWrite(text _: String) -> BridgeOutcome {
        .ok()
    }

    func clipboardRead() async -> BridgeOutcome {
        .ok()
    }

    func setClipboardAutoDetect(enabled _: Bool) -> BridgeOutcome {
        .ok()
    }

    func pushStatus() async -> BridgeOutcome {
        .ok()
    }

    func requestPermission(type _: String, isStillValid _: @escaping @MainActor () -> Bool) async -> BridgeOutcome {
        .ok()
    }

    func track(name _: String) -> BridgeOutcome {
        .ok()
    }

    func reportRejected(method _: String, code _: Int) {}
}
