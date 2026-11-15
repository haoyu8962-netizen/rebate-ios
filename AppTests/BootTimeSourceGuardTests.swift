import Foundation
import XCTest

/// FU-IOS-PRIVACY-MANIFEST-BOOTTIME（D10-1754 ①）源码守卫：隐私清单按 35F9.1 登记 SystemBootTime——开机时刻、系统运行时长
/// 及其派生值只在本机计算间隔 / 计时，不外传；唯一允许外传的是 App 内事件经过的时长（link_jump 的 duration_ms）。
/// 去掉注释后匹配，只扫产品源码。
/// - 网络层与埋点：一个相关符号都不许出现（无白名单）。
/// - 全部产品源码：相关符号只许出现在白名单文件里（每个文件写明理由）；白名单里的文件不再命中也要报，免得名单过期。
/// - 开机标识 `ClipboardBoot.current` 只作为 ClipboardBootScopedRecord 的 `boot` 默认值传入，不被别处直接读取。
/// - TradeJumpExecutor：systemUptime 派生的 elapsedMillis 只以「两次读数之差」进 link_jump。
final class BootTimeSourceGuardTests: XCTestCase {
    /// 取开机时刻 / 运行时长的 API，以及本仓库的开机标识符号。
    private static let needles = [
        "systemUptime", "mach_absolute_time", "mach_continuous_time", "kern.boottime", "KERN_BOOTTIME", "sysctl",
        "CACurrentMediaTime", "clock_gettime", "CLOCK_UPTIME", "CLOCK_MONOTONIC",
        "ClipboardBoot", "bootSuffix", "bootKey", "\"_boot\"",
    ]

    /// 产品源码（含契约生成物）。
    private static let productRoots = [
        "App/Sources",
        "Packages/Core/Sources",
        "Packages/Features/Sources",
        "Packages/DesignSystem/Sources",
        "Packages/Generated/Sources",
    ]

    /// 网络层（请求体、请求头、签名）与埋点（事件定义、队列、上报、诊断）、link_jump 上报接线。
    private static let egressPaths = [
        "Packages/Core/Sources/CouliNetwork",
        "App/Sources/Network",
        "Packages/Core/Sources/ClientCore/TrackerQueue.swift",
        "Packages/Core/Sources/ClientCore/TrackerUploadTimer.swift",
        "Packages/Core/Sources/ClientCore/TrackAttribution.swift",
        "Packages/Core/Sources/ClientCore/EventDiagnostics.swift",
        "App/Sources/ClientCore/AppTracker.swift",
        "App/Sources/Trade/AppJumpPorts.swift",
        "Packages/Generated/Sources/Generated/TrackerEvents.swift",
    ]

    /// 允许出现相关符号的文件与理由。
    private static let allowlist: [String: String] = [
        "App/Sources/Web/AppWeb.swift":
            "awaitUpdate 的 5 秒截止时刻（systemUptime + 5），只在本地循环里比较",
        "Packages/Features/Sources/Web/WebContainerSupport.swift":
            "WebTapRecorder 的单调时钟，只算距上次有效点击是否在 1 秒内",
        "Packages/Core/Sources/Trade/TradeJumpExecutor.swift":
            "每步耗时：elapsedMillis 两次读数之差进 link_jump 的 duration_ms（35F9.1 允许外传 App 内事件间隔）",
        "App/Sources/Debug/DebugHomeVisual+LongFeed.swift":
            "#if DEBUG 性能基准：CACurrentMediaTime 只算滚动时长；sysctl 读的是 KERN_PROC 进程启动时刻，不是开机时刻",
        "Packages/Core/Sources/Clipboard/ClipboardBootScope.swift":
            "开机标识的定义：sysctl kern.boottime，只落本机剪贴板记录文件用于比对是否同一次开机",
        "Packages/Core/Sources/Clipboard/ClipboardRecords.swift":
            "ClipboardWriteLedger 持有 ClipboardBootScopedRecord，传入 boot 默认值",
        "App/Sources/Clipboard/AppClipboard.swift":
            "AppClipboard 持有 ios_change_seen 的 ClipboardBootScopedRecord，传入 boot 默认值",
    ]

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { throw XCTSkip("找不到仓库根（contract.lock）") }
            directory = parent
        }
        return directory
    }

    /// 去掉 /* */ 与 // 注释（字符串里的 "//" 会截断该行余下部分，对本守卫的匹配只会更宽松）。
    private func stripComments(_ text: String) -> String {
        let noBlock = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        return noBlock.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let range = line.range(of: "//") else { return line }
            return line[..<range.lowerBound]
        }.joined(separator: "\n")
    }

    /// 相对路径下的全部 .swift（目录递归，文件直接取）；路径不存在则失败，免得改名后守卫悄悄落空。
    private func swiftFiles(_ relative: String, root: URL) throws -> [URL] {
        let url = root.appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            XCTFail("扫描路径不存在：\(relative)")
            return []
        }
        guard isDirectory.boolValue else { return [url] }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func relativePath(_ file: URL, root: URL) -> String {
        file.path.replacingOccurrences(of: root.path + "/", with: "")
    }

    /// 文件相对路径 → 命中的符号。
    private func hits(in paths: [String]) throws -> [String: [String]] {
        let root = try repositoryRoot()
        var found: [String: [String]] = [:]
        for path in paths {
            for file in try swiftFiles(path, root: root) {
                let code = stripComments(try String(contentsOf: file, encoding: .utf8))
                let matched = Self.needles.filter { code.contains($0) }
                if !matched.isEmpty {
                    found[relativePath(file, root: root)] = matched
                }
            }
        }
        return found
    }

    private func code(_ relative: String) throws -> String {
        let root = try repositoryRoot()
        return stripComments(try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8))
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testNetworkAndTrackerSourcesNeverTouchBootTime() throws {
        let found = try hits(in: Self.egressPaths)
        XCTAssertEqual(found, [:], "网络层 / 埋点 / link_jump 接线里出现了开机时刻或运行时长相关符号")
    }

    func testBootTimeSymbolsOnlyInAllowlistedFiles() throws {
        let found = try hits(in: Self.productRoots)
        let unexpected = found.keys.filter { Self.allowlist[$0] == nil }.sorted()
        XCTAssertEqual(unexpected.map { "\($0): \(found[$0] ?? [])" }, [],
                       "新的开机时刻 / 运行时长读取：核对是否只在本机计算间隔，确认后加白名单并同步隐私清单注释")
        let stale = Self.allowlist.keys.filter { found[$0] == nil }.sorted()
        XCTAssertEqual(stale, [], "白名单里的文件已不再命中，删掉对应条目")
    }

    func testBootIdentifierOnlyFeedsBootScopedRecord() throws {
        let root = try repositoryRoot()
        var direct: [String] = []
        for path in Self.productRoots {
            for file in try swiftFiles(path, root: root) {
                let text = stripComments(try String(contentsOf: file, encoding: .utf8))
                let reads = occurrences(of: "ClipboardBoot.current", in: text)
                let defaults = occurrences(of: "{ ClipboardBoot.current }", in: text)
                if reads != defaults {
                    direct.append(relativePath(file, root: root))
                }
            }
        }
        XCTAssertEqual(direct, [], "ClipboardBoot.current 只许写成 ClipboardBootScopedRecord 的 boot 默认闭包")
        let scope = try code("Packages/Core/Sources/Clipboard/ClipboardBootScope.swift")
        XCTAssertFalse(scope.contains("print("), "开机标识不进日志")
        XCTAssertFalse(scope.contains("NSLog"), "开机标识不进日志")
        XCTAssertFalse(scope.contains("Logger"), "开机标识不进日志")
        XCTAssertFalse(scope.contains("import CouliNetwork"), "开机标识模块不直接接网络层")
    }

    func testTradeJumpReportsOnlyElapsedDifference() throws {
        let text = try code("Packages/Core/Sources/Trade/TradeJumpExecutor.swift")
        XCTAssertEqual(occurrences(of: "elapsedMillis()", in: text), 2, "elapsedMillis 只读两次：步骤开始与上报时求差")
        XCTAssertTrue(text.contains("let started = elapsedMillis()"))
        XCTAssertTrue(text.contains("\"duration_ms\": max(0, elapsedMillis() - started)"),
                      "link_jump 只上报两次读数之差，不上报运行时长本身")
    }
}
