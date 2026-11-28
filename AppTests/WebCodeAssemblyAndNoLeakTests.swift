@testable import Couli
import Foundation
import Trade
import XCTest

/// FU-IOS-TB-WEBCODE-A：web_code 装配与不泄露守卫。
/// - 装配（scope-ios 差距表 #9；仿安卓甲 v01–v02）：`AppTrade.makeWebCode()` 在 Release 视图（DEBUG 为假）下只构造真实授权器
///   `WebAuthSessionWebCodeAuthorizer(launcher: SystemWebAuthSessionLauncher(),
///   attempts: UserDefaultsWebCodeAttempts…)`，
///   不再返回 `UnavailableWebCodeAuthorizer`（今天红）；App 源码里不再出现 `UnavailableWebCodeAuthorizer`（保留给测试）；
///   DEBUG 视图仍先走假服务 `DebugFakeTrade.webCodeAuthorizer()`（不倒退，今天绿）；运行时（Debug 构建、没开假服务）
///   `AppTrade.webCode` 是真实授权器（今天红）。
/// - 不泄露（差距表 #31；仿安卓甲 s00–s04）：新文件去注释后没有日志调用；经手 code 的文件不写 UserDefaults / 文件 / Keychain、
///   不碰路由；包内新文件不写 DEBUG 条件；`WebCodeCallback` 的 description / 反射 / dump 不带 code、state 原文（底座已是
///   最终值，今天绿）。
@MainActor
final class WebCodeAssemblyAndNoLeakTests: XCTestCase {
    private static let assemblyFile = "App/Sources/Trade/AppTrade.swift"
    /// 本单新增的产品源码（扫描范围；s00 钉住它们都在）。
    private static let newFiles = [
        "Packages/Core/Sources/Trade/WebCodeCallback.swift",
        "Packages/Core/Sources/Trade/WebCodeInbox.swift",
        "Packages/Core/Sources/Trade/WebCodeAttempts.swift",
        "App/Sources/Trade/WebAuthSessionWebCodeAuthorizer.swift",
        "App/Sources/Trade/UserDefaultsWebCodeAttempts.swift",
    ]
    /// 经手 code / 回跳原文的文件。
    private static let codeHandlingFiles = [
        "Packages/Core/Sources/Trade/WebCodeCallback.swift",
        "Packages/Core/Sources/Trade/WebCodeInbox.swift",
        "App/Sources/Trade/WebAuthSessionWebCodeAuthorizer.swift",
    ]

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "WebCodeAssemblyAndNoLeakTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        AppStubProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default
            .removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName))
        AppStubProtocol.reset()
    }

    // MARK: - 源码读取

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { throw XCTSkip("找不到仓库根（contract.lock）") }
            directory = parent
        }
        return directory
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    /// 去掉 /* */ 与 // 注释（字符串里的 "//" 会截断该行余下部分，对本守卫只会更宽松）。
    private func stripComments(_ text: String) -> String {
        let noBlock = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        return noBlock.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let range = line.range(of: "//") else { return line }
            return line[..<range.lowerBound]
        }.joined(separator: "\n")
    }

    /// 按 `debug` 取舍 `#if` / `#elseif` / `#else` / `#endif`：条件里提到 DEBUG 的按 `debug` 判（`!DEBUG` 取反），
    /// 别的条件一律当成立。返回保留下来的行。
    private func conditionalView(_ text: String, debug: Bool) -> String {
        struct Frame {
            let active: Bool
            let taken: Bool
        }
        var stack: [Frame] = []
        var kept: [Substring] = []
        func evaluate(_ condition: Substring) -> Bool {
            guard condition.contains("DEBUG") else { return true }
            return condition.contains("!DEBUG") ? !debug : debug
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("#if ") {
                let value = evaluate(trimmed.dropFirst(4))
                stack.append(Frame(active: value, taken: value))
            } else if trimmed.hasPrefix("#elseif "), let top = stack.popLast() {
                let value = !top.taken && evaluate(trimmed.dropFirst(8))
                stack.append(Frame(active: value, taken: top.taken || value))
            } else if trimmed.hasPrefix("#else"), let top = stack.popLast() {
                stack.append(Frame(active: !top.taken, taken: true))
            } else if trimmed.hasPrefix("#endif") {
                _ = stack.popLast()
            } else if stack.allSatisfy(\.active) {
                kept.append(line)
            }
        }
        return kept.joined(separator: "\n")
    }

    /// `makeWebCode()` 的函数体（去注释后按花括号配对）。
    private func makeWebCodeBody() throws -> String {
        let code = stripComments(try source(Self.assemblyFile))
        let head = try XCTUnwrap(code.range(of: "func makeWebCode("), "AppTrade.swift 里找不到 makeWebCode()")
        let open = try XCTUnwrap(code[head.upperBound...].firstIndex(of: "{"))
        var depth = 0
        var index = open
        while index < code.endIndex {
            if code[index] == "{" {
                depth += 1
            } else if code[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return String(code[code.index(after: open)..<index])
                }
            }
            index = code.index(after: index)
        }
        XCTFail("makeWebCode() 花括号不配对")
        return ""
    }

    // MARK: - 装配

    func testReleaseBranchBuildsOnlyTheRealAuthorizer() throws {
        let release = conditionalView(try makeWebCodeBody(), debug: false)
        XCTAssertTrue(release.contains("WebAuthSessionWebCodeAuthorizer("), "Release 应构造真实授权器：\(release)")
        XCTAssertTrue(release.contains("SystemWebAuthSessionLauncher()"), "Release 用系统会话端口")
        XCTAssertTrue(release.contains("UserDefaultsWebCodeAttempts("), "Release 用 UserDefaults 尝试记录")
        XCTAssertFalse(release.contains("UnavailableWebCodeAuthorizer"), "Release 不再返回 UnavailableWebCodeAuthorizer")
        XCTAssertFalse(release.contains("DebugFake"), "Release 视图里没有调试假服务")
    }

    func testAppSourcesNoLongerUseTheUnavailableAuthorizer() throws {
        let root = try repositoryRoot()
        let base = root.appendingPathComponent("App/Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
        var hits: [String] = []
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let code = stripComments(try String(contentsOf: url, encoding: .utf8))
            if code.contains("UnavailableWebCodeAuthorizer") {
                hits.append(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        XCTAssertGreaterThan(scanned, 50, "扫描范围：App/Sources")
        XCTAssertEqual(hits, [], "App 里 DEBUG 末尾分支也换成真实授权器；UnavailableWebCodeAuthorizer 只留给测试")
    }

    func testDebugBranchStillPrefersTheFakeService() throws {
        let debug = conditionalView(try makeWebCodeBody(), debug: true)
        let fake = try XCTUnwrap(debug.range(of: "DebugFakeTrade.webCodeAuthorizer()"), "DEBUG 仍先走假服务（不倒退）")
        if let real = debug.range(of: "WebAuthSessionWebCodeAuthorizer(") {
            XCTAssertLessThan(fake.lowerBound, real.lowerBound, "假服务判在真实授权器之前")
        }
    }

    func testDebugBuildWithoutFakeServiceWiresTheRealAuthorizer() throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains(DebugFakeLoginServer.launchArgument) else {
            throw XCTSkip("本进程开着假服务：装配走 DebugFakeTrade，这条不适用")
        }
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        let trade = AppTrade(
            network: fixture.network, config: fixture.config, privacy: fixture.privacy, routing: fixture.routing,
            login: fixture.login, credentialsReadable: { true }, track: { _, _ in }
        )
        XCTAssertTrue(trade.webCode is WebAuthSessionWebCodeAuthorizer, "实际是 \(type(of: trade.webCode))")
        XCTAssertTrue(trade.webCode.available, "web_code 本端可执行")
    }

    // MARK: - 不泄露

    func testScanScopeCoversTheNewFiles() throws {
        for file in Self.newFiles {
            XCTAssertFalse(try source(file).isEmpty, "扫描范围缺 \(file)")
        }
    }

    func testNewFilesHaveNoLogging() throws {
        let pattern = #"\b(print|debugPrint|NSLog|os_log|dump|fputs|os_signpost)\s*\(|\bLogger\b|\bOSLog\b|"#
            + #"FileHandle\.standard(Error|Output)|\bTimber\b"#
        for file in Self.newFiles {
            let code = stripComments(try source(file))
            XCTAssertNil(code.range(of: pattern, options: .regularExpression), "\(file) 里有日志 / 打印调用")
        }
    }

    func testCodeHandlingFilesNeverPersistOrRoute() throws {
        let pattern = #"\bUserDefaults\b|@AppStorage|@SceneStorage|\bFileManager\b|\.write\(to:|"#
            + #"\bData\(contentsOf|\bSecItem\w*|\bKeychain\w*|NSUbiquitousKeyValueStore|NSKeyedArchiver|"#
            + #"\bUIPasteboard\b|\bHTTPCookieStorage\b|\bURLCache\b|\b(Router|AppRouting|DeepLinkParser)\b"#
        for file in Self.codeHandlingFiles {
            let code = stripComments(try source(file))
            let hit = code.range(of: pattern, options: .regularExpression).map { String(code[$0]) }
            XCTAssertNil(hit, "\(file) 经手 code：不落盘、不交给路由")
        }
    }

    func testPackageFilesHaveNoDebugCondition() throws {
        for file in Self.newFiles where file.hasPrefix("Packages/") {
            let code = try source(file)
            XCTAssertNil(
                code.range(of: #"#(if|elseif)\b[^\n]*\bDEBUG\b"#, options: .regularExpression),
                "\(file)：包在 Staging 按 Release 编译，不写 DEBUG 条件"
            )
        }
    }

    func testCallbackDescriptionsCarryNoSecrets() {
        let callbacks: [WebCodeCallback] = [
            .code(code: "SECRETcode42", state: "SECRETstate42"), .incomplete(state: "SECRETstate42"),
        ]
        for callback in callbacks {
            var dumped = ""
            dump(callback, to: &dumped)
            let renderings = [
                String(describing: callback), String(reflecting: callback), "\(callback)", callback.description,
                callback.debugDescription, String(describing: [callback]), String(describing: Optional(callback)),
                dumped, Mirror(reflecting: callback).children.map { "\($0.label ?? ""):\($0.value)" }.joined(),
            ]
            for text in renderings {
                XCTAssertFalse(text.contains("SECRETcode42"), "不带 code 原文：\(text)")
                XCTAssertFalse(text.contains("SECRETstate42"), "不带 state 原文：\(text)")
            }
        }
    }
}
