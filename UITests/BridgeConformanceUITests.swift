import XCTest

/// 桥一致性页（03 §5.5）：用真实点击提供用户手势，读取 `window.__RESULT__`（App 的调试浮层 `conformance.result` 以无障碍
/// 标签暴露精简后的逐项结果）。先按 `BridgeConformanceCaseList` 校验结果的用例 ID 完整、无重复、无清单外用例（共性第 55 条），
/// 再按清单逐项断言（`BridgeConformanceExpectations`）：
/// - 本任务已实现的方法：必须 passed；
/// - 本任务不实现的方法（trade.*、share.open、media.*、ext.*、cs.open）的 normal 用例：断言规定错误码 90001；其余用例
///   （bad_params、no_gesture、trade_only、platform_link 等协议判定）必须 passed；
/// - 受环境限制的用例：只认 `environmentExceptions` 里登记的错误码（登记为未完成）；清单里的 harness 用例由测试桩控制，
///   一致性页本身不跑，必须保持待定；
/// - 清单外的任何失败、待定或错误码不符，测试失败。
/// 离页或弹系统框的用例（auth.login、nav.open、nav.close、perm.request）各自一个测试，同时断言回包与实际导航结果。
///
/// 需要本机静态服务（http://127.0.0.1:8789/conformance/，只在 Debug 构建可信），所以只在显式要求时运行：
/// `TEST_RUNNER_COULI_CONFORMANCE=1 xcodebuild test -only-testing:CouliUITests/BridgeConformanceUITests …`；
/// 平时（verify.sh）跳过。
@MainActor
final class BridgeConformanceUITests: XCTestCase {
    /// 离开页面或弹系统框的用例单独跑（各自一个用例），其余在同一会话里依次点。
    private static let separate: Set<String> = [
        "auth.login/normal",
        "nav.open/normal",
        "nav.close/normal",
        "perm.request/normal",
    ]

    override func setUp() async throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["COULI_CONFORMANCE"] == "1" else {
            throw XCTSkip("需要本机一致性页服务；设置 TEST_RUNNER_COULI_CONFORMANCE=1 时运行")
        }
    }

    // MARK: - 用例

    func testTapCasesInOneSession() throws {
        let app = launch()
        let web = app.webViews.firstMatch
        let ids = web.buttons.allElementsBoundByIndex.map(\.label).filter { !Self.separate.contains($0) }
        XCTAssertFalse(ids.isEmpty)
        for id in ids {
            let button = web.buttons[id]
            guard button.exists else { continue }
            button.tap()
            if id.hasPrefix("clipboard.read") {
                allowPaste(app)
            }
            sleep(1)
        }
        // 等到清单里该有结果的用例都有结果（harness 与单独测试的除外）。
        let report = try waitForReport(app) { report in
            report.cases.allSatisfy { item in
                Self.separate.contains(item.id) || BridgeConformanceCaseList.harness.contains(item.id)
                    || item.outcome != nil
            }
        }
        attach("logged-in-after-taps")
        assertCases(report, skipping: Self.separate)
    }

    func testNavOpen() throws {
        let app = launch()
        let before = routerState(app)
        app.webViews.firstMatch.buttons["nav.open/normal"].tap()
        let report = try waitForReport(app) { $0.item("nav.open/normal")?.outcome != nil }
        attach("nav-open-home-after-tap")
        assertPassed(report, "nav.open/normal")
        // 实际导航结果：经 Router 打开 Home（Tab 根，清空导航栈），Router 确实发布了这次变化。
        let after = routerState(app)
        XCTAssertEqual(after["tabRoot"], "Home", "\(after)")
        XCTAssertEqual(after["path"], "0", "\(after)")
        XCTAssertGreaterThan(Int(after["changes"] ?? "") ?? 0, Int(before["changes"] ?? "") ?? 0, "Router 发生了导航")
    }

    func testAuthLogin() throws {
        let app = launch()
        app.webViews.firstMatch.buttons["auth.login/normal"].tap()
        XCTAssertTrue(app.staticTexts["route.placeholder.name"].waitForExistence(timeout: 10))
        attach("auth-login-opens-login-placeholder")
        let report = try waitForReport(app) { $0.item("auth.login/normal")?.outcome != nil }
        assertPassed(report, "auth.login/normal")
        XCTAssertEqual(routerState(app)["path"], "1", "登录占位路由已压栈")
    }

    func testNavClose() throws {
        let app = launch()
        app.webViews.firstMatch.buttons["nav.close/normal"].tap()
        XCTAssertTrue(app.staticTexts["conformance.closed"].waitForExistence(timeout: 10))
        attach("nav-close-after-tap")
        let report = try waitForReport(app) { $0.item("nav.close/normal")?.outcome != nil }
        assertPassed(report, "nav.close/normal")
    }

    func testPermRequest() throws {
        let app = launch()
        app.webViews.firstMatch.buttons["perm.request/normal"].tap()
        // perm.request 只走 PermissionRequester：先出用途说明（只有【继续】），之后才是系统授权框。
        let proceed = app.buttons["继续"]
        if proceed.waitForExistence(timeout: 5) {
            attach("perm-request-rationale")
            proceed.tap()
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "允许"] where springboard.buttons[label].waitForExistence(timeout: 3) {
            springboard.buttons[label].tap()
        }
        let report = try waitForReport(app) { $0.item("perm.request/normal")?.outcome != nil }
        assertPassed(report, "perm.request/normal")
    }

    // MARK: - 断言

    /// 先校验用例 ID 完整，再逐项断言（见类注释）。
    private func assertCases(_ report: ConformanceReport, skipping: Set<String>) {
        for failure in BridgeConformanceExpectations.failures(report, skipping: skipping) {
            XCTFail(failure)
        }
    }

    private func assertPassed(_ report: ConformanceReport, _ id: String) {
        guard let item = report.item(id) else {
            XCTFail("__RESULT__ 里没有 \(id)")
            return
        }
        XCTAssertEqual(item.pass, true, "\(id) 应通过：\(item)")
        XCTAssertEqual(item.ok, true, "\(id) 回包应为成功：\(item)")
    }

    // MARK: - 读取

    /// 读调试浮层里的 `__RESULT__`（App 每秒导出一次），直到满足条件；超时则测试失败。
    private func waitForReport(
        _ app: XCUIApplication,
        timeout: TimeInterval = 60,
        until ready: (ConformanceReport) -> Bool
    ) throws -> ConformanceReport {
        let element = app.staticTexts["conformance.result"]
        XCTAssertTrue(element.waitForExistence(timeout: 10), "缺少调试浮层 conformance.result")
        let deadline = Date().addingTimeInterval(timeout)
        var last: ConformanceReport?
        while Date() < deadline {
            if let report = ConformanceReport(element.label) {
                last = report
                if ready(report) {
                    return report
                }
            }
            sleep(1)
        }
        let pending = last?.cases.filter {
            $0.outcome == nil && !BridgeConformanceCaseList.harness.contains($0.id)
        }.map(\.id) ?? []
        XCTFail("等待 __RESULT__ 超时，仍待定：\(pending)")
        return try XCTUnwrap(last, "没有读到 __RESULT__")
    }

    /// 剪贴板读取：系统的「允许粘贴」框，最多等 8 秒。框弹出期间 App 主线程阻塞在读取剪贴板上，查询 App 的界面会卡住，
    /// 所以只在 SpringBoard 里找。
    private func allowPaste(_: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            for label in ["Allow Paste", "允许粘贴"] where springboard.buttons[label].exists {
                springboard.buttons[label].tap()
                return
            }
            usleep(200_000)
        }
    }

    /// Router 状态（`tabRoot=… path=… changes=…`）。
    private func routerState(_ app: XCUIApplication) -> [String: String] {
        let element = app.staticTexts["conformance.router"]
        _ = element.waitForExistence(timeout: 5)
        var fields: [String: String] = [:]
        for part in element.label.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                fields[pair[0]] = pair[1]
            }
        }
        return fields
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CouliPrivacyPreset", "consented", "-CouliBridgeConformance", "logged_in",
            "-CouliUpdateScenario", "normal",
        ]
        app.launch()
        let summary = app.staticTexts["conformance.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
        let done = NSPredicate(format: "label CONTAINS 'done'")
        expectation(for: done, evaluatedWith: summary)
        waitForExpectations(timeout: 60)
        return app
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
