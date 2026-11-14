@testable import Couli
import CouliNetwork
import Foundation
import MeCore
import XCTest

/// LOCK-ios 调用点：隐私中心撤回隐私同意（AppMe.withdrawConsent → recordConsent {type: privacy, accepted: false,
/// channel: privacy_center}）。
/// - D10-1711：交给网络层的 ApiCall 声明了 `sendsWhenIdentityUnknown: true`，身份未知（存着会话但读不出）时照发、不带 Authorization；
///   未声明的同类调用网络层按 session_unreadable 零发送（NetworkTests/LockIosIdentityUnknownTests 7a / 7b'）。
/// - D10-1713：撤回写的是设备级记录（契约 recordConsent x-signed=false：带 X-Device-Id、不带签名头、不带 Authorization），确认时固定
///   `identity.request?.sessionOnly`——只固定会话世代 / 作废世代、不固定账号。所以普通会员（会话里有账号）确认后会话读不出时照发；
///   确认后会话世代变了（换人 / 退出）仍零发送，本地撤回照常完成；游客照旧（设备已注册发设备级记录，未注册不发，G25）。
///
/// 时序：`withdrawConsent` 在同步入口里核对确认时的身份（isCurrent）、生成请求体与固定归属，然后起一个 @MainActor 外层 Task 发送；
/// 测试同在主 actor 上，`withdrawConsent` 返回后、外层 Task 开始前插入故障（令牌读取失败 / 会话换代），发送时看到的就是故障后的状态。
/// 撤回结果被调用点丢弃（`_ = await`），本地撤回在发送结束之后才做，所以「进入基本模式」时发送一定已经结束，可直接数请求。
@MainActor
final class LockIosConsentWithdrawUnknownTests: MeTestCase {
    /// D10-1713 ②（主用例）：普通会员确认撤回后会话读不出 → 撤回记录照发 1 条，设备级、不带令牌。
    func testMemberWithdrawSendsWhenSessionUnreadable() async throws {
        let fixture = make()
        let identity = fixture.me.computeIdentity()
        XCTAssertEqual(identity.request?.account, "user-a", "前提：普通会员，确认时的身份带账号")
        XCTAssertTrue(fixture.me.isCurrent(identity), "前提：确认时身份已确认")

        fixture.me.withdrawConsent(identity)
        // 确认生效的同步入口已经走完；之后的令牌读取一律失败（身份未知），撤回记录在外层 Task 里发送
        fixture.store.failReads(fromNth: 1)
        await waitUntil("没进基本模式") { fixture.me.privacy.state.decision == .basicMode }
        fixture.store.stopFailing()

        let consents = requests("POST", "/v1/consents")
        XCTAssertEqual(consents.count, 1, "D10-1713：只固定会话世代、不固定账号，会话读不出照发")
        assertDeviceLevelWithdraw(try XCTUnwrap(consents.first))
    }

    /// D10-1713：确认后换了人（退出后另一账号登录，会话世代 +1）→ 撤回记录零发送（session_changed），本地撤回照常完成。
    func testWithdrawAfterAccountSwitchSendsNothing() async throws {
        let fixture = make()
        let identity = fixture.me.computeIdentity()
        XCTAssertTrue(fixture.me.isCurrent(identity), "前提：确认时身份已确认")
        let generation = fixture.client.sessionGeneration

        fixture.me.withdrawConsent(identity)
        try fixture.switchAccount(to: "user-b")
        XCTAssertNotEqual(fixture.client.sessionGeneration, generation, "前提：会话世代变了")
        await waitUntil("没进基本模式") { fixture.me.privacy.state.decision == .basicMode }

        XCTAssertTrue(requests("POST", "/v1/consents").isEmpty, "旧确认的撤回记录不发给新会话")
        XCTAssertFalse(fixture.me.deps.withdraw.busy, "本地撤回已完成")
        XCTAssertEqual(fixture.me.currentIdentity.level, MeLevel.basic)
    }

    /// D10-1713：确认后退出登录（只清会话，会话世代 +1）→ 撤回记录零发送，本地撤回照常完成。
    func testWithdrawAfterSignOutSendsNothing() async {
        let fixture = make()
        let identity = fixture.me.computeIdentity()
        XCTAssertTrue(fixture.me.isCurrent(identity), "前提：确认时身份已确认")
        let generation = fixture.client.sessionGeneration

        fixture.me.withdrawConsent(identity)
        fixture.client.signOut()
        XCTAssertNotEqual(fixture.client.sessionGeneration, generation, "前提：会话世代变了")
        await waitUntil("没进基本模式") { fixture.me.privacy.state.decision == .basicMode }

        XCTAssertTrue(requests("POST", "/v1/consents").isEmpty, "退出之后不再发旧确认的撤回记录")
        XCTAssertFalse(fixture.me.deps.withdraw.busy, "本地撤回已完成")
        XCTAssertEqual(fixture.me.currentIdentity.level, MeLevel.basic)
    }

    /// D10-1713：游客照旧——设备已注册发 1 条设备级撤回记录（不带令牌）。
    func testGuestRegisteredWithdrawSendsDeviceLevel() async throws {
        let fixture = make(account: nil)
        let identity = fixture.me.computeIdentity()
        XCTAssertEqual(identity.level, MeLevel.guest, "前提：游客")
        XCTAssertTrue(fixture.me.isCurrent(identity), "前提：确认时身份已确认")

        fixture.me.withdrawConsent(identity)
        await waitUntil("没进基本模式") { fixture.me.privacy.state.decision == .basicMode }

        let consents = requests("POST", "/v1/consents")
        XCTAssertEqual(consents.count, 1, "游客设备已注册：照旧发设备级记录")
        assertDeviceLevelWithdraw(try XCTUnwrap(consents.first))
    }

    /// D10-1713：游客照旧——设备未注册不发（PrivacyWithdrawFlow.request 的 deviceRegistered 条件，G25），本地撤回照常完成。
    func testGuestUnregisteredWithdrawSendsNothing() async {
        let fixture = make(account: nil, registered: false)
        let identity = fixture.me.computeIdentity()
        XCTAssertEqual(identity.level, MeLevel.guest, "前提：游客")

        fixture.me.withdrawConsent(identity)
        await waitUntil("没进基本模式") { fixture.me.privacy.state.decision == .basicMode }

        XCTAssertTrue(requests("POST", "/v1/consents").isEmpty, "设备未注册不发")
        XCTAssertFalse(fixture.me.deps.withdraw.busy, "本地撤回已完成")
    }

    /// D10-1711 / D10-1713：存着令牌、但没有账号字段的会话（确认时固定的归属 account == nil）——确认时会话可读、身份已确认，确认之后令牌
    /// 读取持续失败，撤回记录发送时身份未知。这一条单看 D10-1711 的 `sendsWhenIdentityUnknown` 声明（不涉及账号固定）：有声明才会发出。
    func testPrivacyWithdrawSendsWhenIdentityUnknown() async throws {
        let fixture = make()
        try fixture.tokens.save(access: "at-legacy", refresh: "rt-legacy", scope: "full", account: nil)
        let identity = fixture.me.computeIdentity()
        XCTAssertNil(identity.request?.account, "前提：确认时固定的归属不带账号")
        XCTAssertTrue(fixture.me.isCurrent(identity), "前提：确认时身份已确认")

        fixture.me.withdrawConsent(identity)
        // 确认生效的同步入口已经走完；之后的令牌读取一律失败（身份未知），撤回记录在外层 Task 里发送
        fixture.store.failReads(fromNth: 1)
        await waitUntil("没进基本模式") { fixture.me.privacy.state.decision == .basicMode }
        fixture.store.stopFailing()

        let consents = requests("POST", "/v1/consents")
        XCTAssertEqual(consents.count, 1, "声明了 sendsWhenIdentityUnknown：身份未知照发")
        assertDeviceLevelWithdraw(try XCTUnwrap(consents.first))
    }

    /// 设备级撤回记录（契约 recordConsent x-signed=false）：带 X-Device-Id，不带 Authorization 与签名头；请求体是隐私中心撤回隐私同意。
    private func assertDeviceLevelWithdraw(
        _ sent: WalletStubProtocol.Recorded, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNil(sent.header(HeaderNames.authorization), "设备级、不带令牌", file: file, line: line)
        XCTAssertEqual(sent.header(HeaderNames.deviceId), "device-fixture-0001", "设备级", file: file, line: line)
        for name in HeaderNames.signature {
            XCTAssertNil(sent.header(name), "x-signed=false：不带 \(name)", file: file, line: line)
        }
        XCTAssertEqual(sent.json["type"] as? String, "privacy", file: file, line: line)
        XCTAssertEqual(sent.json["accepted"] as? Bool, false, file: file, line: line)
        XCTAssertEqual(sent.json["channel"] as? String, "privacy_center", file: file, line: line)
    }
}
