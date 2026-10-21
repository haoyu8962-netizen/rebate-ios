import CouliNetwork
import Foundation
@testable import Login
import Router
import Session
import XCTest

/// APP-17c-ios（对标鸿蒙 HM-13c）：待绑定码生命周期与 InviteLink 分流。规则口径：NATIVE/HM-13/scope.md §1 R04/R05/R08、§4 HM-13c，
/// decision.md G07、G18–G21；BR-INV-04 细则「游客的待绑定码」「邀请链接拉起 App」、BR-INV-06；AC-S1-182 ①⑧⑩。
///
/// 测试设施：真实 LoginService + ApiClient（LoginStubProtocol 本地假服务，按请求同步记录；可挂起后放行）、真实 Router、生产出口
/// RouterLoginHost（LoginHarness）。登录页状态经生产 `LoginViewModel(config:)`；分流经生产 `InviteLinkDispatcher.dispatch`。
/// 负向断言（没有请求、码仍在 / 已清）都在 `await` 登录结果之后做；等待一律条件等待并断言其结果。
@MainActor
final class PendingInviteApp17cTests: XCTestCase {
    let phone = "13800138000"
    let code = "123456"
    /// 测试用码（BR-INV-01 字符集 23456789ABCDEFGHJKLMNPQRSTUVWXYZ、6 位；与样例数据里的本人码 K7M3QX 不同）。
    let codeK = "K7M2QX"
    let codeP = "P5R8TW"
    let codeOld = "PREV23"

    // MARK: - 同一测试类的跨文件设施（短信请求与邀请链接用例复用）

    /// 登录接口按次序回答（用完后一律成功 full）；其余接口回 {}。
    func install(_ replies: [LoginStubProtocol.Reply]) {
        let queue = MutableBox(replies)
        LoginStubProtocol.install { request in
            guard request.path == Paths.login else { return okReply("{}") }
            var rest = queue.value
            guard !rest.isEmpty else { return okReply(loginData(scope: "full")) }
            let next = rest.removeFirst()
            queue.value = rest
            return next
        }
    }

    func bind(_ result: String, _ code: String = "null") -> String {
        "{\"result\":\"\(result)\",\"code\":\(code)}"
    }

    func harness() -> (LoginHarness, PendingInviteCode) {
        let env = LoginHarness()
        let pending = PendingInviteCode()
        env.service.pendingInvite = pending
        return (env, pending)
    }

    func submit(_ env: LoginHarness, invite: String = "", restricted: Bool = false,
                phone rawPhone: String? = nil, code rawCode: String? = nil,
                consent: Int64? = 1) async -> LoginOutcome {
        await env.service.login(phone: rawPhone ?? phone, code: rawCode ?? code, consentAtMillis: consent,
                                invite: invite, restricted: restricted)
    }

    var loginRequests: [LoginStubProtocol.Recorded] {
        LoginStubProtocol.requests(path: Paths.login)
    }

    func body(_ index: Int, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let all = loginRequests
        guard index < all.count else {
            XCTFail("第 \(index + 1) 次登录请求不存在（共 \(all.count) 次）", file: file, line: line)
            return [:]
        }
        return bodyObject(all[index].body)
    }

    func model(_ env: LoginHarness, restricted: Bool = false) -> LoginViewModel {
        let config = LoginPageConfig(service: env.service, texts: KeyTexts())
        config.restricted = restricted
        return LoginViewModel(config: config)
    }

    /// 游客从邀请链接拉起（已同意、格式正确、不是本人码）：经生产分流入口写入待绑定码。
    func guestLink(_ code: String, into pending: PendingInviteCode) -> InviteLinkDecision {
        var opened: [String] = []
        let decision = InviteLinkDispatcher.dispatch(
            InviteLinkInput(rawCode: code, consented: true, guest: true, ownCode: nil, eligible: false),
            pending: pending, open: { route, _ in opened.append(route) }
        )
        XCTAssertEqual(opened, ["Login"])
        return decision
    }

    // MARK: - C1 容器

    /// set 替换旧码；peek 只读不取走；remove、clear 清空；consumeForRequest 取一次即空。
    func testContainerSetReplacesPeekKeepsRemoveAndConsumeClear() {
        let pending = PendingInviteCode()
        XCTAssertNil(pending.peek())
        XCTAssertNil(pending.consumeForRequest(), "空容器取出为 nil")
        pending.set(codeOld)
        pending.set(codeK)
        XCTAssertEqual(pending.peek(), codeK, "新码替换旧码")
        XCTAssertEqual(pending.peek(), codeK, "peek 不取走")
        XCTAssertEqual(pending.consumeForRequest(), codeK)
        XCTAssertNil(pending.peek(), "取出即清空")
        XCTAssertNil(pending.consumeForRequest())
        pending.set(codeP)
        pending.remove()
        XCTAssertNil(pending.peek(), "【移除】即丢弃")
        pending.set(codeP)
        pending.clear()
        XCTAssertNil(pending.peek())
    }

    /// 进程内有效、只在内存：实例之间不共享（没有静态共享状态，「重启」= 新实例为空）。
    func testInstancesAreIndependentNoSharedStaticState() {
        let first = PendingInviteCode()
        first.set(codeK)
        let second = PendingInviteCode()
        XCTAssertNil(second.peek(), "新实例为空")
        second.set(codeP)
        XCTAssertEqual(first.peek(), codeK, "互不影响")
        second.clear()
        XCTAssertEqual(first.peek(), codeK)
    }

    // MARK: - 登录页小字行（R04、G13、G20）

    /// 登录页顶部的小字行：login.pending_invite（{code}）+【移除】login.pending_invite.remove；读取不消费；【移除】后行消失、容器为空。
    func testRowShowsPendingCodeWithRemoveAndReadingDoesNotConsume() throws {
        install([])
        let (env, pending) = harness()
        let page = model(env)
        XCTAssertNil(page.pendingInviteRow, "没有待绑定码不显示")
        pending.set(codeK)
        let row = try XCTUnwrap(page.pendingInviteRow, "有待绑定码就显示（现读容器）")
        XCTAssertEqual(row.code, codeK)
        XCTAssertEqual(row.textKey, "login.pending_invite")
        XCTAssertEqual(row.removeKey, "login.pending_invite.remove")
        XCTAssertEqual(page.pendingInviteRow?.code, codeK, "再读一次仍在")
        XCTAssertEqual(pending.peek(), codeK, "建行不消费")
        pending.set(codeP)
        XCTAssertEqual(page.pendingInviteRow?.code, codeP, "新码替换后行显示新码")
        page.removePendingInvite()
        XCTAssertNil(page.pendingInviteRow, "移除后行消失")
        XCTAssertNil(pending.peek(), "移除即丢弃")
        XCTAssertTrue(loginRequests.isEmpty)
    }

    /// G20：受限登录（从强更页进入）不显示小字行，码保留（G07）。对照：同一容器在普通登录页显示。
    func testRowHiddenOnRestrictedLoginButCodeKept() {
        let (env, pending) = harness()
        pending.set(codeK)
        let restricted = model(env, restricted: true)
        XCTAssertNil(restricted.pendingInviteRow, "受限登录不显示业务输入")
        XCTAssertEqual(pending.peek(), codeK, "不清")
        XCTAssertEqual(model(env).pendingInviteRow?.code, codeK, "对照：普通登录页显示")
    }
}
