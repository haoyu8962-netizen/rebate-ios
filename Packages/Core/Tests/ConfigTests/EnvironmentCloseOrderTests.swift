@testable import Config
import Foundation
import XCTest

/// FU-IOS-0711：切换环境的关闭步骤（`EnvironmentSwitchClosing`）在读取保留项、运行任何清理器之前执行；
/// 启动对账、手动切换两条清理路径都一样。关闭步骤只关闭、不清理。
@MainActor
final class EnvironmentCloseOrderTests: XCTestCase {
    private final class Log {
        var entries: [String] = []
    }

    /// 读取保留项时记一笔。
    private final class LoggingDefaults: UserDefaults, @unchecked Sendable {
        var log: Log?

        override func object(forKey defaultName: String) -> Any? {
            if AppNamespace.preservedOnEnvironmentSwitchKeys.contains(defaultName) {
                log?.entries.append("preserved")
            }
            return super.object(forKey: defaultName)
        }
    }

    private final class ClosingCleaner: EnvironmentSwitchClosing {
        let cleanerName: String
        let log: Log

        init(name: String, log: Log) {
            cleanerName = name
            self.log = log
        }

        func closeForEnvironmentSwitch() {
            log.entries.append("close:\(cleanerName)")
        }

        func cleanForEnvironmentSwitch() throws {
            log.entries.append("clean:\(cleanerName)")
        }
    }

    private final class PlainCleaner: EnvironmentSwitchCleaning {
        let cleanerName = "plain"
        let log: Log

        init(log: Log) {
            self.log = log
        }

        func cleanForEnvironmentSwitch() throws {
            log.entries.append("clean:plain")
        }
    }

    private var suiteName = ""
    private var defaults: LoggingDefaults!
    private let log = Log()

    override func setUp() async throws {
        suiteName = "EnvironmentCloseOrderTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(LoggingDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.log = nil
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeApplier() -> EnvironmentApplier {
        let registry = EnvironmentSwitchCleanerRegistry(cleaners: [
            PlainCleaner(log: log), ClosingCleaner(name: "network", log: log),
        ])
        return EnvironmentApplier(defaults: defaults, registry: registry)
    }

    func testApplyClosesBeforeReadingPreservedKeysAndCleaning() throws {
        let applier = makeApplier()
        defaults.log = log

        try applier.apply(environmentID: "staging") { [log] in
            log.entries.append("publish")
        }

        XCTAssertEqual(log.entries.first, "close:network", "关闭是第一步 \(log.entries)")
        XCTAssertEqual(log.entries.dropFirst().first, "publish", "关闭完成之后才发布 switching \(log.entries)")
        let firstPreserved = try XCTUnwrap(log.entries.firstIndex(of: "preserved"))
        let firstClean = try XCTUnwrap(log.entries.firstIndex { $0.hasPrefix("clean:") })
        XCTAssertLessThan(1, firstPreserved, "发布 switching 之后才读取保留项")
        XCTAssertLessThan(firstPreserved, firstClean)
        XCTAssertEqual(log.entries.filter { $0 == "publish" || $0.hasPrefix("close:") }.count, 2, "只关闭、发布各一次")
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("clean:") }, ["clean:plain", "clean:network"])
    }

    func testLaunchReconcileClosesBeforeReadingPreservedKeysAndCleaning() throws {
        defaults.set("prod", forKey: AppNamespace.appliedEnvironmentKey)
        let applier = makeApplier()
        defaults.log = log

        XCTAssertEqual(applier.reconcileAtLaunch(environmentID: "test"), .cleaned(previous: "prod"))

        let firstClose = try XCTUnwrap(log.entries.firstIndex(of: "close:network"))
        let afterAppliedRead = log.entries.dropFirst(firstClose)
        XCTAssertTrue(afterAppliedRead.contains("preserved"), "\(log.entries)")
        let firstClean = try XCTUnwrap(log.entries.firstIndex { $0.hasPrefix("clean:") })
        let preservedBeforeClean = log.entries[..<firstClean].lastIndex(of: "preserved")
        XCTAssertNotNil(preservedBeforeClean)
        XCTAssertLessThan(firstClose, preservedBeforeClean ?? -1, "关闭先于读取保留项")
    }

    func testUnchangedLaunchDoesNotClose() {
        defaults.set("test", forKey: AppNamespace.appliedEnvironmentKey)
        let applier = makeApplier()
        defaults.log = log

        XCTAssertEqual(applier.reconcileAtLaunch(environmentID: "test"), .unchanged)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("close:") || $0.hasPrefix("clean:") })
    }

    func testRegistryCloseOnlyClosesAndRunsNoCleaner() {
        let registry = EnvironmentSwitchCleanerRegistry(cleaners: [
            PlainCleaner(log: log), ClosingCleaner(name: "a", log: log), ClosingCleaner(name: "b", log: log),
        ])

        registry.closeForEnvironmentSwitch()

        XCTAssertEqual(log.entries, ["close:a", "close:b"])
    }
}
