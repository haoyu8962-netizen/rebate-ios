import CouliNetwork
import Foundation
@testable import Login
import Router
import Session
import XCTest

/// APP-17c：InviteLink 分流真值表与导航出口。沿用同一测试类，保留原用例名。
extension PendingInviteApp17cTests {
    // MARK: - InviteLinkDispatcher（R08；AC-S1-182 ⑩）

    /// 32 行真值表（同意 × 格式 × 本人码 × 游客 × eligible），期望按 BR-INV-04 细则「邀请链接拉起 App」的处理顺序：
    /// 未同意 / 基本模式 → drop；格式不符 → drop；等于本人码 → drop；游客 → login；已登录且 eligible → invite_backfill；其余 → home。
    /// code 只在 login / invite_backfill 时非空。
    func testDispatcherFullTruthTable() {
        let valid = codeK
        let invalid = "K7M2Q"
        for consented in [true, false] {
            for wellFormed in [true, false] {
                for own in [true, false] {
                    for guest in [true, false] {
                        for eligible in [true, false] {
                            let raw = wellFormed ? valid : invalid
                            let input = InviteLinkInput(
                                rawCode: raw, consented: consented, guest: guest,
                                ownCode: own ? raw : "T3ST22", eligible: eligible
                            )
                            let expected: (String, String?) = if !consented || !wellFormed || own {
                                (InviteLinkDecision.drop, nil)
                            } else if guest {
                                (InviteLinkDecision.login, valid)
                            } else if eligible {
                                (InviteLinkDecision.inviteBackfill, valid)
                            } else {
                                (InviteLinkDecision.home, nil)
                            }
                            let label = "consented=\(consented) wellFormed=\(wellFormed) own=\(own) guest=\(guest) "
                                + "eligible=\(eligible)"
                            let decision = InviteLinkDispatcher.decide(input)
                            XCTAssertEqual(decision.kindRaw, expected.0, label)
                            XCTAssertEqual(decision.code, expected.1, label)
                        }
                    }
                }
            }
        }
        XCTAssertEqual(InviteLinkDecision.drop, "drop")
        XCTAssertEqual(InviteLinkDecision.login, "login")
        XCTAssertEqual(InviteLinkDecision.inviteBackfill, "invite_backfill")
        XCTAssertEqual(InviteLinkDecision.home, "home")
    }

    /// 游客本人码为 nil；已登录本人码未知（nil）不当本人码；各种格式不符的码游客 / 已登录都 drop。
    func testDispatcherNilOwnCodeAndBadFormats() throws {
        let guest = InviteLinkDispatcher.decide(
            InviteLinkInput(rawCode: codeK, consented: true, guest: true, ownCode: nil, eligible: false)
        )
        XCTAssertEqual(guest.kindRaw, InviteLinkDecision.login)
        XCTAssertEqual(guest.code, codeK)
        let unknownOwn = InviteLinkDispatcher.decide(
            InviteLinkInput(rawCode: codeK, consented: true, guest: false, ownCode: nil, eligible: true)
        )
        XCTAssertEqual(unknownOwn.kindRaw, InviteLinkDecision.inviteBackfill, "本人码未知不当本人码")
        XCTAssertEqual(unknownOwn.code, codeK)
        // 共用 v2 invalid 包含原 10 条手写样例，另补 K0M2QX；游客 / 已登录的分流断言均保留。
        for raw in try PendingInviteSetVectors.load().invalid {
            for asGuest in [true, false] {
                let decision = InviteLinkDispatcher.decide(
                    InviteLinkInput(rawCode: raw, consented: true, guest: asGuest, ownCode: nil, eligible: true)
                )
                XCTAssertEqual(decision.kindRaw, InviteLinkDecision.drop, "\(raw) guest=\(asGuest)")
                XCTAssertNil(decision.code, raw)
            }
        }
    }

    /// 丢弃的情形（基本模式 / 未同意的游客与已登录、格式不符的游客与已登录、等于本人码）：没有任何 open，原待绑定码不动。
    func testDispatchDropCasesNoNavigationAndPendingUntouched() {
        let inputs = [
            InviteLinkInput(rawCode: codeK, consented: false, guest: true, ownCode: nil, eligible: false),
            InviteLinkInput(rawCode: codeK, consented: false, guest: false, ownCode: "T3ST22", eligible: true),
            InviteLinkInput(rawCode: "K7M2Q", consented: true, guest: true, ownCode: nil, eligible: false),
            InviteLinkInput(rawCode: "K7M2Q0", consented: true, guest: false, ownCode: "T3ST22", eligible: true),
            InviteLinkInput(rawCode: codeK, consented: true, guest: false, ownCode: codeK, eligible: true),
            InviteLinkInput(rawCode: codeK, consented: true, guest: false, ownCode: codeK, eligible: false),
        ]
        for (index, input) in inputs.enumerated() {
            let pending = PendingInviteCode()
            pending.set(codeOld)
            var opened: [(String, [String: String])] = []
            let decision = InviteLinkDispatcher.dispatch(input, pending: pending) { opened.append(($0, $1)) }
            XCTAssertEqual(decision.kindRaw, InviteLinkDecision.drop, "#\(index)")
            XCTAssertTrue(opened.isEmpty, "#\(index)：丢弃时没有任何页面跳转")
            XCTAssertEqual(pending.peek(), codeOld, "#\(index)：原待绑定码不动")
        }
        // 分流入口按接口约定不拿网络客户端：不可能发请求（不另做「零请求」断言）。
    }

    /// AC-S1-182 ⑩ 游客：替换旧待绑定码、只打开一次 Login（参数为空，不自动提交）；登录页小字行显示新码；之后短信登录带新码并清除。
    func testGuestLinkReplacesPendingAndOpensLoginThenLoginCarriesIt() async {
        install([])
        let (env, pending) = harness()
        pending.set(codeOld)
        var opened: [(String, [String: String])] = []
        let decision = InviteLinkDispatcher.dispatch(
            InviteLinkInput(rawCode: codeK, consented: true, guest: true, ownCode: nil, eligible: false),
            pending: pending
        ) { opened.append(($0, $1)) }
        XCTAssertEqual(decision.kindRaw, InviteLinkDecision.login)
        XCTAssertEqual(decision.code, codeK)
        XCTAssertEqual(opened.map(\.0), ["Login"], "只打开一次 Login")
        XCTAssertEqual(opened.first?.1, [:], "不带参数（码在待绑定码容器里）")
        XCTAssertEqual(pending.peek(), codeK, "替换旧码")
        XCTAssertEqual(model(env).pendingInviteRow?.code, codeK)
        XCTAssertTrue(loginRequests.isEmpty, "分流本身不发请求")
        let outcome = await submit(env)
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.loggedIn)
        XCTAssertEqual(body(0)["invite_code"] as? String, codeK)
        XCTAssertNil(pending.peek())
    }

    /// AC-S1-182 ⑩ 已登录且 eligible=true：只打开 InviteBackfill，参数 prefill=码；不写待绑定码，不发请求（由用户点【确认绑定】）。
    func testLoggedInEligibleOpensBackfillWithPrefillOnly() {
        for before in [nil, codeOld] as [String?] {
            let pending = PendingInviteCode()
            if let before {
                pending.set(before)
            }
            var opened: [(String, [String: String])] = []
            let decision = InviteLinkDispatcher.dispatch(
                InviteLinkInput(rawCode: codeK, consented: true, guest: false, ownCode: "T3ST22", eligible: true),
                pending: pending
            ) { opened.append(($0, $1)) }
            XCTAssertEqual(decision.kindRaw, InviteLinkDecision.inviteBackfill)
            XCTAssertEqual(decision.code, codeK)
            XCTAssertEqual(opened.count, 1)
            XCTAssertEqual(opened.first?.0, "InviteBackfill")
            XCTAssertEqual(opened.first?.1, ["prefill": codeK])
            XCTAssertEqual(pending.peek(), before, "已登录不写待绑定码")
        }
    }

    /// 已登录但 eligible=false：只打开 Home，参数为空（不提示、不带码），不写也不清待绑定码（原无 / 原有旧码两组，第 2 版 review r1 S2）。
    func testLoggedInNotEligibleOpensHomeSilently() {
        for before in [nil, codeOld] as [String?] {
            let pending = PendingInviteCode()
            if let before {
                pending.set(before)
            }
            var opened: [(String, [String: String])] = []
            let decision = InviteLinkDispatcher.dispatch(
                InviteLinkInput(rawCode: codeK, consented: true, guest: false, ownCode: "T3ST22", eligible: false),
                pending: pending
            ) { opened.append(($0, $1)) }
            XCTAssertEqual(decision.kindRaw, InviteLinkDecision.home)
            XCTAssertNil(decision.code)
            XCTAssertEqual(opened.count, 1)
            XCTAssertEqual(opened.first?.0, "Home")
            XCTAssertEqual(opened.first?.1, [:], "不提示、不带码")
            XCTAssertEqual(pending.peek(), before, "已登录不写也不清待绑定码")
        }
    }
}
