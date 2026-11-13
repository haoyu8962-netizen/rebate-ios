import Foundation
import XCTest

// FU-IOS-A11Y-CODE-ERROR-FOCUS（D10-1431 ③ / D10-1432）：从 FU-IOS-A11Y 必跑名单拆出的一条。
// **本文件不进 CouliTests 编译**：project.yml 的 CouliTests sources 排除 `AppTests/Pending/**`，所以 verify / 本单跑法都不跑它；
// 不是 skip，要恢复就把排除那一行删掉（本文件是 A11yLoginTests 的扩展，用的是它的夹具与判据，重新纳入即可编译）。
// 状态：未自动验证。已排除：读屏双击接收、播报拦截、测量桥、前序用例状态、20002 映射（契约为内联错误行）、真实首登链路
// （LoginSmokeTests.testSmokeLoginResumesPendingAndLogout、LoginIntegrationTests，firstlogin.out 16 过 0 红）。
// 剩余怀疑：读屏夹具在该用例里首登时序。
extension A11yLoginTests {
    func testCodeErrorIsAnnouncedAndFocusesCodeField() async throws {
        // 拦截在发码之前装好（v7：放在双击【登录】前一刻装，登录请求没发出，按时序问题处理）
        A11yAudit.installTap(self, voiceOver: true)
        script.fail("POST /v1/auth/login/sms", 20002)
        let canvas = try await codeStep(make(account: nil))
        probes.clearFocus()
        try await tap("login.submit", in: canvas)
        try await assertAnnouncedAndFocused("login.codeError", targets: ["login.code", "login.codeError"], in: canvas)
    }
}
