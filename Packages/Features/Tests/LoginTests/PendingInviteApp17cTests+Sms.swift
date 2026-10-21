import CouliNetwork
import Foundation
@testable import Login
import Router
import Session
import XCTest

/// APP-17c：短信登录带码、提交结算与在途替换。沿用同一测试类与条件等待设施。
extension PendingInviteApp17cTests {
    // MARK: - 短信登录带码（R05、G18；AC-S1-182 ①⑧）

    /// AC-S1-182 ⑧：点【移除】后再登录，请求不带 invite_code。
    func testRemovedCodeIsNotSent() async {
        install([okReply(loginData(scope: "full", isNew: true))])
        let (env, pending) = harness()
        pending.set(codeK)
        let page = model(env)
        page.removePendingInvite()
        let outcome = await submit(env)
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.loggedIn)
        XCTAssertEqual(loginRequests.count, 1)
        XCTAssertNil(body(0)["invite_code"], "移除后不带")
    }

    /// AC-S1-182 ①：待绑定码随短信登录带上（只一次请求）；不论 invite_bind 结果（bound / failed / ignored_existing_user）都清除，
    /// 小字行消失，下一次登录不再带。
    func testSmsLoginCarriesPendingOnceThenClearsForEveryBindResult() async {
        let cases: [(String, String)] = [
            ("bound", bind("bound")), ("failed", bind("failed", "30401")),
            ("ignored_existing_user", bind("ignored_existing_user")),
        ]
        for (label, result) in cases {
            install([okReply(loginData(scope: "full", isNew: label != "ignored_existing_user", invite: result))])
            let (env, pending) = harness()
            pending.set(codeK)
            let page = model(env)
            let outcome = await submit(env)
            XCTAssertEqual(outcome.stateRaw, LoginOutcome.loggedIn, label)
            XCTAssertEqual(outcome.inviteResult, label)
            XCTAssertEqual(loginRequests.count, 1, "\(label)：只发一次")
            XCTAssertEqual(body(0)["invite_code"] as? String, codeK, "\(label)：带待绑定码")
            XCTAssertNil(pending.peek(), "\(label)：提交后清除")
            XCTAssertNil(page.pendingInviteRow, "\(label)：小字行消失")
            let again = await submit(env)
            XCTAssertEqual(again.stateRaw, LoginOutcome.loggedIn)
            XCTAssertEqual(loginRequests.count, 2)
            XCTAssertNil(body(1)["invite_code"], "\(label)：下一次登录不再带")
        }
    }

    /// 新码替换旧码后登录：只带最新的码，只带一次。
    func testSmsLoginAfterReplacementSendsNewestOnce() async {
        install([])
        let (env, pending) = harness()
        pending.set(codeOld)
        _ = guestLink(codeK, into: pending)
        let outcome = await submit(env)
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.loggedIn)
        XCTAssertEqual(body(0)["invite_code"] as? String, codeK)
        XCTAssertNil(pending.peek())
        _ = await submit(env)
        XCTAssertNil(body(1)["invite_code"])
    }

    /// G18：已带码提交、服务端回验证码错误（20002）也清除（「提交后不论结果都清除」）；下一次不再带。
    func testSubmittedButRejected20002StillClears() async {
        install([failReply(20002), okReply(loginData(scope: "full"))])
        let (env, pending) = harness()
        pending.set(codeK)
        let wrong = await submit(env)
        XCTAssertEqual(wrong.stateRaw, "code_error")
        XCTAssertEqual(loginRequests.count, 1)
        XCTAssertEqual(body(0)["invite_code"] as? String, codeK, "已提交")
        XCTAssertNil(pending.peek(), "提交后不论结果都清")
        _ = await submit(env)
        XCTAssertNil(body(1)["invite_code"])
    }

    /// G18（第 2 版，review r1 S1-2）：带码请求已到假服务、随后传输失败（断连，transportFailure）也清本次提交那份码，
    /// 不放回；重试（下一次提交）不再带。
    func testSubmittedThenTransportFailureStillClears() async {
        install([.hold("first"), okReply(loginData(scope: "full"))])
        let (env, pending) = harness()
        pending.set(codeK)
        let task = Task { await self.submit(env) }
        await waitUntil { LoginStubProtocol.isHeld("first") }
        XCTAssertTrue(LoginStubProtocol.isHeld("first"))
        XCTAssertEqual(body(0)["invite_code"] as? String, codeK, "请求已带码发出")
        LoginStubProtocol.release("first", with: .disconnect)
        let failed = await task.value
        XCTAssertNotEqual(failed.stateRaw, LoginOutcome.loggedIn, "传输失败")
        XCTAssertNotEqual(failed.stateRaw, LoginOutcome.stale)
        let sent = loginRequests.count
        XCTAssertGreaterThanOrEqual(sent, 1)
        XCTAssertNil(pending.peek(), "已提交、传输失败也清（不放回）")
        XCTAssertNil(model(env).pendingInviteRow)
        let retry = await submit(env)
        XCTAssertEqual(retry.stateRaw, LoginOutcome.loggedIn)
        XCTAssertEqual(loginRequests.count, sent + 1)
        XCTAssertNil(body(sent)["invite_code"], "重试不再带")
    }

    /// 本地校验失败（号码不合法、验证码不满位、未同意）不发请求、不消费；对照：之后有效提交带上并清除。
    func testLocalRejectionsSendNothingAndKeepPending() async {
        install([])
        let (env, pending) = harness()
        pending.set(codeK)
        let badPhone = await submit(env, phone: "12345")
        XCTAssertEqual(badPhone.field, "phone")
        let shortCode = await submit(env, code: "12")
        XCTAssertEqual(shortCode.stateRaw, LoginOutcome.codeIncomplete)
        let noConsent = await submit(env, consent: nil)
        XCTAssertEqual(noConsent.stateRaw, LoginOutcome.agreementRequired)
        XCTAssertTrue(LoginStubProtocol.requests(path: Paths.login).isEmpty, "本地拒绝不发请求")
        XCTAssertEqual(pending.peek(), codeK, "本地拒绝不消费")
        XCTAssertEqual(model(env).pendingInviteRow?.code, codeK)
        let valid = await submit(env)
        XCTAssertEqual(valid.stateRaw, LoginOutcome.loggedIn)
        XCTAssertEqual(loginRequests.count, 1)
        XCTAssertEqual(body(0)["invite_code"] as? String, codeK, "对照：有效提交带上")
        XCTAssertNil(pending.peek())
    }

    /// BR-INV-06（2026-10-18）：invite_code 只来自待绑定码；`invite:` 参数（旧手填框）忽略。
    func testTypedInviteIsIgnoredOnlyPendingCodeIsSent() async {
        install([])
        let (env, pending) = harness()
        _ = await submit(env, invite: "HAND23")
        XCTAssertNil(body(0)["invite_code"], "没有待绑定码时不带手填值")
        pending.set(codeK)
        _ = await submit(env, invite: "HAND23")
        XCTAssertEqual(body(1)["invite_code"] as? String, codeK, "带待绑定码，不带手填值")
    }

    /// G07：受限登录（从强更页进入）不带码也不清，留给下一次正常登录；对照：之后正常登录带上并清除。
    func testRestrictedLoginNeitherSendsNorClears() async {
        install([okReply(loginData(scope: "deletion_only")), okReply(loginData(scope: "full"))])
        let (env, pending) = harness()
        env.update.value = .below
        env.router.enterForceUpdate()
        env.router.openFromForceUpdatePage(RouteRequest(route: "Login", from: .inApp))
        pending.set(codeK)
        let restricted = await submit(env, invite: codeK, restricted: true)
        XCTAssertEqual(restricted.stateRaw, LoginOutcome.loggedIn)
        XCTAssertEqual(loginRequests.count, 1)
        XCTAssertNil(body(0)["invite_code"], "受限登录不带")
        XCTAssertEqual(pending.peek(), codeK, "受限登录不清")
        let normal = await submit(env)
        XCTAssertEqual(normal.stateRaw, LoginOutcome.loggedIn)
        XCTAssertEqual(body(1)["invite_code"] as? String, codeK, "对照：正常登录带上")
        XCTAssertNil(pending.peek())
    }

    // MARK: - 在途与 BUSY（G18：只清本次提交那一份）

    /// 请求在途时经分流入口到了新码 P：旧请求不论成功还是验证码错误，结算后 P 仍在；下一次提交带 P、带完清空。
    /// 首次提交带 K / 不带码各跑一次。
    func testCodeArrivingWhileInFlightSurvivesSettlementAndIsSentNext() async {
        let settlements: [(String, LoginStubProtocol.Reply)] = [
            ("success", okReply(loginData(scope: "full", isNew: true, invite: bind("bound")))),
            ("20002", failReply(20002)),
            ("transportFailure", .disconnect),
        ]
        for first in [codeK, nil] as [String?] {
            for (label, settle) in settlements {
                let tag = "\(first ?? "无码") / \(label)"
                install([.hold("first")])
                let (env, pending) = harness()
                if let first {
                    pending.set(first)
                }
                let task = Task { await self.submit(env) }
                await waitUntil { LoginStubProtocol.isHeld("first") }
                XCTAssertTrue(LoginStubProtocol.isHeld("first"), tag)
                _ = guestLink(codeP, into: pending)
                XCTAssertEqual(pending.peek(), codeP, "\(tag)：在途期间写入")
                LoginStubProtocol.release("first", with: settle)
                let settled = await task.value
                XCTAssertNotEqual(settled.stateRaw, LoginOutcome.busy, tag)
                XCTAssertNotEqual(settled.stateRaw, LoginOutcome.stale, tag)
                let firstCount = loginRequests.count
                XCTAssertGreaterThanOrEqual(firstCount, 1, tag)
                for index in 0..<firstCount {
                    if let first {
                        XCTAssertEqual(body(index)["invite_code"] as? String, first, "\(tag)：首次提交带 K")
                    } else {
                        XCTAssertNil(body(index)["invite_code"], "\(tag)：首次提交不带码")
                    }
                }
                XCTAssertEqual(pending.peek(), codeP, "\(tag)：在途期间新到的码在结算后仍在")
                XCTAssertEqual(model(env).pendingInviteRow?.code, codeP, tag)
                _ = await submit(env)
                XCTAssertEqual(loginRequests.count, firstCount + 1, tag)
                XCTAssertEqual(body(firstCount)["invite_code"] as? String, codeP, "\(tag)：下一次带 P")
                XCTAssertNil(pending.peek(), "\(tag)：带完清空")
            }
        }
    }

    /// BUSY（上一次登录在途）拒绝的提交不消费：在途期间经分流写入 P → 第二次提交（号码、验证码、同意都合法）回 busy、不发请求，P 仍在
    /// → 旧请求按 20002 结算后 P 仍在 → 下一次有效提交带 P。首次提交带 K / 不带码各跑一次。
    func testBusyRejectionDoesNotConsumePendingAndNextValidSubmissionCarriesIt() async {
        for first in [codeK, nil] as [String?] {
            let tag = first ?? "无码"
            install([.hold("first")])
            let (env, pending) = harness()
            if let first {
                pending.set(first)
            }
            let task = Task { await self.submit(env) }
            await waitUntil { LoginStubProtocol.isHeld("first") }
            _ = guestLink(codeP, into: pending)
            let busy = await submit(env)
            XCTAssertEqual(busy.stateRaw, LoginOutcome.busy, tag)
            XCTAssertEqual(loginRequests.count, 1, "\(tag)：BUSY 不发请求")
            XCTAssertTrue(LoginStubProtocol.isHeld("first"), "\(tag)：仍只有第一次在途")
            XCTAssertEqual(pending.peek(), codeP, "\(tag)：BUSY 不消费")
            XCTAssertEqual(model(env).pendingInviteRow?.code, codeP, tag)
            LoginStubProtocol.release("first", with: failReply(20002))
            let settled = await task.value
            XCTAssertEqual(settled.stateRaw, "code_error", tag)
            XCTAssertEqual(pending.peek(), codeP, "\(tag)：旧请求结算后 P 仍在")
            let next = await submit(env)
            XCTAssertEqual(next.stateRaw, LoginOutcome.loggedIn, tag)
            XCTAssertEqual(loginRequests.count, 2, tag)
            XCTAssertEqual(body(1)["invite_code"] as? String, codeP, "\(tag)：下一次有效提交带 P")
            XCTAssertNil(pending.peek(), tag)
        }
    }
}
