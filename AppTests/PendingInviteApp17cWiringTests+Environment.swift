@testable import Couli
import XCTest

/// APP-17c Q2：环境切换的 App 接线，使用组合自带的独立清理注册表。
extension PendingInviteApp17cWiringTests {
    // MARK: - 切换环境（Q2）

    /// 真实 EnvironmentStore.switchTo → 清理注册表 → 剪贴板清理钩子：切换后 AppLogin 那份待绑定码为空。
    func testEnvironmentSwitchClearsPendingButSelectingCurrentEnvironmentKeepsIt() throws {
        let app = shell(wireEnvironmentSwitch: true)
        let fixture = app.fixture
        let environment = fixture.routing.environment
        XCTAssertEqual(environment.current, .test)
        XCTAssertTrue(fixture.environmentSwitch.registeredNames.contains(ClipboardInvalidationCleaner.name))
        XCTAssertTrue(app.clipboard.pendingInvite === fixture.login.pendingInvite)
        guestConfirms(codeK, in: app)
        assertConfirmSettled(app)
        XCTAssertEqual(fixture.login.pendingInvite.peek(), codeK)

        try environment.switchTo(.test)
        XCTAssertEqual(fixture.login.pendingInvite.peek(), codeK, "选择当前环境不清码")
        try environment.switchTo(.staging)
        XCTAssertEqual(environment.current, .staging, "切换已完成")
        XCTAssertNil(fixture.login.pendingInvite.peek(), "Q2：切换环境清掉进程内待绑定码")
        XCTAssertNil(fixture.login.service.pendingInvite?.peek(), "登录请求不会继续带旧环境的码")
        XCTAssertNil(rowCode(fixture), "登录页不再显示旧码")
    }
}
