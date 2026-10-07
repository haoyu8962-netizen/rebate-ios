import XCTest

/// 一致性判定自测（共性第 55 条，iOS 第 3 轮评审 R3-03）：不启动 App、不需要一致性页服务，直接驱动
/// `BridgeConformanceExpectations.failures`。证明结果集为空、缺任意一条必测用例（含 harness 用例）、出现重复或清单外
/// 用例时判定都会失败；完整且符合预期的结果判定通过。
final class BridgeConformanceCompletenessTests: XCTestCase {
    /// 由单独测试断言的用例（与 BridgeConformanceUITests.separate 相同）。
    private let separate: Set<String> = [
        "auth.login/normal", "nav.open/normal", "nav.close/normal", "perm.request/normal",
    ]

    func testCaseListIsWellFormed() {
        let all = BridgeConformanceCaseList.required + BridgeConformanceCaseList.harness
        XCTAssertEqual(all.count, 91, "9cd1e6f 一致性页在 iOS 上的用例数")
        XCTAssertEqual(Set(all).count, all.count, "清单本身无重复")
        XCTAssertTrue(BridgeConformanceCaseList.required.contains("clipboard.write/no_gesture"))
        XCTAssertTrue(BridgeConformanceCaseList.required.contains("frame/negative/subframe"))
        XCTAssertTrue(BridgeConformanceCaseList.completenessProblems(all).isEmpty)
    }

    func testCompleteConformingReportPasses() {
        let report = ConformanceReport(status: "done", cases: conformingCases())
        XCTAssertEqual(BridgeConformanceExpectations.failures(report, skipping: separate), [])
    }

    /// 删掉任意一条必测用例（其余全部正常通过），判定都失败，并点名缺的那一条。
    func testDroppingAnyListedCaseFails() {
        let full = conformingCases()
        for dropped in BridgeConformanceCaseList.required + BridgeConformanceCaseList.harness {
            let report = ConformanceReport(status: "done", cases: full.filter { $0.id != dropped })
            let failures = BridgeConformanceExpectations.failures(report, skipping: separate)
            XCTAssertFalse(failures.isEmpty, "缺 \(dropped) 时判定必须失败")
            XCTAssertTrue(failures.contains { $0.contains(dropped) }, "失败说明要点名 \(dropped)：\(failures)")
        }
    }

    func testEmptyDuplicateAndUnlistedResultsFail() {
        let full = conformingCases()
        let empty = ConformanceReport(status: "done", cases: [])
        XCTAssertFalse(BridgeConformanceExpectations.failures(empty, skipping: separate).isEmpty)

        let duplicated = ConformanceReport(status: "done", cases: full + [full[0]])
        let duplicateFailures = BridgeConformanceExpectations.failures(duplicated, skipping: separate)
        XCTAssertTrue(duplicateFailures.contains { $0.contains("重复") }, "\(duplicateFailures)")

        let unlisted = ConformanceReport(status: "done", cases: full + [passed("ui.toast/negative/new_row")])
        let unlistedFailures = BridgeConformanceExpectations.failures(unlisted, skipping: separate)
        XCTAssertTrue(unlistedFailures.contains { $0.contains("ui.toast/negative/new_row") }, "\(unlistedFailures)")
    }

    /// 对照：逐项断言本身仍生效（安全用例失败、harness 用例被跑了都判失败）。
    func testWrongOutcomesFail() {
        var cases = conformingCases()
        if let index = cases.firstIndex(where: { $0.id == "clipboard.write/no_gesture" }) {
            cases[index] = ConformanceCase(
                id: "clipboard.write/no_gesture", method: "clipboard.write", category: "no_gesture",
                trigger: "auto", pass: false, outcome: ["ok": true]
            )
        }
        if let index = cases.firstIndex(where: { $0.id == "auth.getUser/timeout" }) {
            cases[index] = passed("auth.getUser/timeout")
        }
        let failures = BridgeConformanceExpectations.failures(
            ConformanceReport(status: "done", cases: cases), skipping: separate
        )
        XCTAssertTrue(failures.contains { $0.contains("clipboard.write/no_gesture") }, "\(failures)")
        XCTAssertTrue(failures.contains { $0.contains("auth.getUser/timeout") }, "\(failures)")
    }

    // MARK: - 构造

    /// 清单里每条用例都按预期给出结果：harness 待定，预期例外与未实现方法给规定错误码，其余 passed。
    private func conformingCases() -> [ConformanceCase] {
        let harness = BridgeConformanceCaseList.harness.map { id in
            ConformanceCase(id: id, method: method(of: id), category: "", trigger: "harness", pass: nil, outcome: nil)
        }
        let required = BridgeConformanceCaseList.required.map { id -> ConformanceCase in
            if let exception = BridgeConformanceExpectations.environmentExceptions[id] {
                return coded(id, exception.code)
            }
            let name = method(of: id)
            if BridgeConformanceExpectations.notImplemented.contains(name), id == "\(name)/normal" {
                return coded(id, BridgeConformanceExpectations.notSupported)
            }
            return passed(id)
        }
        return (harness + required).sorted { $0.id < $1.id }
    }

    private func method(of id: String) -> String {
        id.split(separator: "/").first.map(String.init) ?? id
    }

    private func passed(_ id: String) -> ConformanceCase {
        ConformanceCase(
            id: id,
            method: method(of: id),
            category: "",
            trigger: "auto",
            pass: true,
            outcome: ["ok": true]
        )
    }

    private func coded(_ id: String, _ code: Int) -> ConformanceCase {
        ConformanceCase(
            id: id, method: method(of: id), category: "", trigger: "auto", pass: false, outcome: [
                "ok": false,
                "code": code,
            ]
        )
    }
}
