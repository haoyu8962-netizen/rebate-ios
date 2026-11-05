import Config
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Router
import XCTest

/// FU-X-STAGING-HOSTS-ios（D10-598、notices 11-04 00:06）：staging 连真实主机。
/// E 组：环境表；D 组：深链主机；X 组：主机只许写在 App target 的 `#if DEBUG` 里；另核 AppNetwork 把 stream 基址与 api 一起交给网络层。
/// 对应安卓 S/X/D 组、鸿蒙 E/S/D/H 组。
@MainActor
final class StagingHostsEnvironmentTests: HomeAppTestCase {
    static let stagingApi = "https://api-stg.couliapp.cn"
    static let stagingH5 = "https://h5-stg.couliapp.cn"
    static let stagingStream = "https://stream-stg.couliapp.cn"
    static let deepLinkHost = "l-stg.couliapp.cn"

    // MARK: - E 组 环境表

    /// E01 staging 的 api / h5 / stream 恰为三个真实主机：https、无端口、无路径、无结尾斜杠，不含 .invalid。
    func testStagingUsesTheRealHosts() throws {
        let endpoints = AppEnvironment.staging.endpoints
        XCTAssertEqual(endpoints.apiBaseURL.absoluteString, Self.stagingApi)
        XCTAssertEqual(endpoints.h5BaseURL.absoluteString, Self.stagingH5)
        XCTAssertEqual(endpoints.streamBaseURL?.absoluteString, Self.stagingStream)
        for url in [endpoints.apiBaseURL, endpoints.h5BaseURL, try XCTUnwrap(endpoints.streamBaseURL)] {
            XCTAssertEqual(url.scheme, "https")
            XCTAssertNil(url.port)
            XCTAssertEqual(url.path, "")
            XCTAssertFalse(url.absoluteString.contains(".invalid"))
        }
    }

    /// E02 local / test 与底版逐字相同；stream 为 nil 或仍是 .couli.invalid 占位。
    func testLocalAndTestStayPlaceholders() throws {
        let expected = [
            "local": ("https://api.local.couli.invalid", "https://h5.local.couli.invalid"),
            "test": ("https://api.test.couli.invalid", "https://h5.test.couli.invalid"),
        ]
        for environment in [AppEnvironment.local, .test] {
            let (api, h5) = try XCTUnwrap(expected[environment.id])
            XCTAssertEqual(environment.endpoints.apiBaseURL.absoluteString, api)
            XCTAssertEqual(environment.endpoints.h5BaseURL.absoluteString, h5)
            if let stream = environment.endpoints.streamBaseURL {
                XCTAssertTrue(
                    stream.host?.hasSuffix(".couli.invalid") ?? false,
                    "\(environment.id) 的 stream 不是占位：\(stream)"
                )
            }
        }
    }

    /// E03 prod 逐字不变，stream 为 nil（Release 的 stream 恒为空，安卓评审 S2-2）。
    func testProdIsUnchangedAndHasNoStream() {
        XCTAssertEqual(AppEnvironment.prod.endpoints.apiBaseURL.absoluteString, "https://api.prod.couli.invalid")
        XCTAssertEqual(AppEnvironment.prod.endpoints.h5BaseURL.absoluteString, "https://h5.prod.couli.invalid")
        XCTAssertNil(AppEnvironment.prod.endpoints.streamBaseURL)
    }

    /// E04 两参数构造时 stream 为 nil；三参数时原样。
    func testTwoArgumentEndpointsHaveNoStream() {
        XCTAssertNil(EnvironmentEndpoints(api: "https://a.couli.invalid", h5: "https://h.couli.invalid").streamBaseURL)
        let three = EnvironmentEndpoints(api: "https://a.couli.invalid", h5: "https://h.couli.invalid",
                                         stream: "https://s.couli.invalid")
        XCTAssertEqual(three.streamBaseURL?.absoluteString, "https://s.couli.invalid")
    }

    /// E05 AppNetwork 的网络状态把 stream 与 api 在同一个就绪条件下一起交出；切换环境两者一起换（S09 的 App 侧）。
    func testNetworkContextCarriesStreamWithApi() throws {
        let fixture = make()
        var context = fixture.network.source.snapshot()
        XCTAssertEqual(context.apiBaseURL?.absoluteString, "https://api.test.couli.invalid")
        XCTAssertEqual(context.streamBaseURL, AppEnvironment.test.endpoints.streamBaseURL)
        try fixture.environment.switchTo(.staging)
        context = fixture.network.source.snapshot()
        XCTAssertEqual(context.apiBaseURL?.absoluteString, Self.stagingApi)
        XCTAssertEqual(context.streamBaseURL?.absoluteString, Self.stagingStream)
        try fixture.environment.switchTo(.prod)
        context = fixture.network.source.snapshot()
        XCTAssertEqual(context.apiBaseURL?.absoluteString, "https://api.prod.couli.invalid")
        XCTAssertNil(context.streamBaseURL)
    }

    // MARK: - D 组 深链

    /// D01 DEBUG 的深链主机只有 l-stg；https 链接能解析，couli-debug 照常。
    func testDebugDeepLinkHostIsLStg() {
        let config = AppRouting.deepLinkConfig
        XCTAssertEqual(config.hosts, [Self.deepLinkHost])
        XCTAssertEqual(config.schemes, ["couli-debug"])
        let https = DeepLinkParser.parse(url: "https://l-stg.couliapp.cn/r/Home", config: config,
                                         routes: AppRouting.routeTable)
        XCTAssertEqual(https?.route, "Home")
        XCTAssertEqual(DeepLinkParser.parse(url: "couli-debug://r/Home", config: config,
                                            routes: AppRouting.routeTable)?.route, "Home")
    }

    /// D02 拒绝 http、子域、后缀伪装、带端口、分享域 s-stg、正式 l. 子域。
    func testDeepLinkRejectsLookalikes() {
        let config = AppRouting.deepLinkConfig
        for url in [
            "http://l-stg.couliapp.cn/r/Home",
            "https://a.l-stg.couliapp.cn/r/Home",
            "https://l-stg.couliapp.cn.evil.example/r/Home",
            "https://evil-l-stg.couliapp.cn/r/Home",
            "https://l-stg.couliapp.cn:8443/r/Home",
            "https://s-stg.couliapp.cn/r/Home",
            "https://l.couliapp.cn/r/Home",
        ] {
            XCTAssertNil(DeepLinkParser.parse(url: url, config: config, routes: AppRouting.routeTable), url)
        }
    }

    /// D03 Release 分支仍是 `.empty`（源码层核对：AppRouting.deepLinkConfig 的 #else 分支）。
    func testReleaseDeepLinkConfigStaysEmpty() throws {
        let text = try SourceScan.read("App/Sources/Routing/AppRouting.swift")
        let body = try XCTUnwrap(text.range(of: "static var deepLinkConfig: DeepLinkConfig {"), "找不到 deepLinkConfig")
        let tail = String(text[body.upperBound...])
        let elseRange = try XCTUnwrap(tail.range(of: "#else"))
        let endRange = try XCTUnwrap(tail.range(of: "#endif"))
        let releaseBranch = SourceScan.code(String(tail[elseRange.upperBound..<endRange.lowerBound]))
        XCTAssertEqual(releaseBranch.trimmingCharacters(in: .whitespacesAndNewlines), ".empty")
    }

    // MARK: - X 组 源码位置

    /// X01 `-stg.couliapp.cn`（不区分大小写）只许出现在 App target 的 `#if DEBUG` 块里，且只在环境表与深链两个文件；
    /// Packages 的 Sources、Info.plist、project.yml、xcconfig 一律不许。
    func testStagingHostsOnlyInsideDebugBlocks() throws {
        let allowedFiles: Set = [
            "App/Sources/Environment/AppEnvironment+Endpoints.swift", "App/Sources/Routing/AppRouting.swift",
        ]
        var found: Set<String> = []
        for path in try SourceScan.productFiles() {
            let text = try SourceScan.read(path)
            guard text.range(of: "-stg.couliapp.cn", options: .caseInsensitive) != nil else { continue }
            found.insert(path)
            XCTAssertTrue(allowedFiles.contains(path), "\(path) 里出现了 staging 主机")
            for line in SourceScan.lines(text)
                where line.text.range(of: "-stg.couliapp.cn", options: .caseInsensitive) != nil {
                XCTAssertTrue(line.debug, "\(path):\(line.number) 的 staging 主机不在 #if DEBUG 里")
            }
        }
        XCTAssertEqual(found, allowedFiles, "两处配置点都要有 staging 主机")
    }

    /// X02 产品源码里不再有旧占位 staging.couli.invalid，也不出现分享域 s-stg.couliapp.cn（由 /v1/config 下发，客户端不手写）。
    func testNoOldPlaceholderAndNoShareDomainInProductSources() throws {
        for path in try SourceScan.productFiles() {
            let text = try SourceScan.read(path)
            XCTAssertNil(text.range(of: "staging.couli.invalid", options: .caseInsensitive), path)
            XCTAssertNil(text.range(of: "s-stg.couliapp.cn", options: .caseInsensitive), path)
        }
    }
}

/// 读仓库源码（AppTests 运行在模拟器上，#filePath 指向本机工作树）。
enum SourceScan {
    static func root() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw NSError(domain: "SourceScan", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到仓库根"])
            }
            directory = parent
        }
        return directory
    }

    static func read(_ path: String) throws -> String {
        try String(contentsOf: root().appendingPathComponent(path), encoding: .utf8)
    }

    /// 产品源码与工程定义：App/Sources、Packages/*/Sources 下的 .swift / .json / .plist，App/Info.plist、project.yml、全部 .xcconfig。
    static func productFiles() throws -> [String] {
        let base = try root()
        var result: [String] = ["App/Info.plist", "project.yml"]
        let manager = FileManager.default
        var roots = ["App/Sources", "App/Config"]
        let packages = try manager.contentsOfDirectory(atPath: base.appendingPathComponent("Packages").path)
        roots += packages.map { "Packages/\($0)/Sources" }
        for folder in roots {
            let url = base.appendingPathComponent(folder)
            guard let walker = manager.enumerator(atPath: url.path) else { continue }
            for case let item as String in walker {
                let path = folder + "/" + item
                if [".swift", ".json", ".plist", ".xcconfig", ".strings"].contains(where: { path.hasSuffix($0) }) {
                    result.append(path)
                }
            }
        }
        XCTAssertGreaterThan(result.count, 100, "扫到的产品文件太少，扫描范围有误")
        return result
    }

    /// 逐行给出「行号、内容、是否在 #if DEBUG 分支里」（#else 分支不算）。
    struct Line {
        let number: Int
        let text: String
        let debug: Bool
    }

    static func lines(_ text: String) -> [Line] {
        var stack: [Bool] = []
        var output: [Line] = []
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if ") {
                stack.append(line == "#if DEBUG")
                continue
            }
            if line.hasPrefix("#else") || line.hasPrefix("#elseif") {
                if !stack.isEmpty {
                    stack[stack.count - 1] = false
                }
                continue
            }
            if line.hasPrefix("#endif") {
                _ = stack.popLast()
                continue
            }
            output.append(Line(number: index + 1, text: raw, debug: stack.contains(true)))
        }
        return output
    }

    /// 去掉 // 注释（只用于取分支内的代码）。
    static func code(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }
}
