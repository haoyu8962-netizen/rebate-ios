@testable import Couli
import CouliNetwork
import Foundation
import Wallet
import WalletCore
import XCTest

/// 身份证号 / 姓名的隐私守卫（契约：the name and the ID number never go into logs；失败不保存；BR-ID-25）：只出现在
/// POST /v1/me/realname 的请求体里；不进其他请求、偏好、埋点、缓存文件、未决记录、剪贴板、错误条与 description；生产实名接线源码不打印。
/// 失败信息不打印哨兵本身。
final class RealnameFundsPrivacyTests: RealnameFundsTestCase {
    /// 失败（30406）→ 结果未知（断连）→ 成功：三次提交走完后逐处查哨兵。
    private func runThreeAttempts() async throws -> (WalletAppFixture, RealNameController) {
        scriptUnverifiedThenVerified()
        script.on("POST \(Self.path)", .envelope(code: 30406, data: "null", headers: [:]), .disconnect, Self.success)
        let fixture = make()
        let page = try await submitOnce(fixture)
        XCTAssertFalse(leaks("\(page.state)"), "RealNameSnapshot.description 带了明文")
        let message = page.state.error?.message(WalletDraftTexts()) ?? ""
        XCTAssertFalse(leaks(message), "错误条带了明文")
        submitWithConsent(page)
        await awaitPosts(2)
        await waitUntil("断连后没有恢复可提交") { page.submitEnabled }
        submitWithConsent(page)
        await awaitPosts(3)
        await waitUntil("成功后没有按已实名") { fixture.wallet.realnameVerified() }
        await quietWindow(0.5)
        return (fixture, page)
    }

    func testSecretsOnlyInSubmitBody() async throws {
        _ = try await runThreeAttempts()
        for request in WalletStubProtocol.requests {
            let isSubmit = request.method == "POST" && request.path == Self.path
            XCTAssertFalse(leaks(request.query) || leaks(request.path), "\(request.method) \(request.path) 的地址带了明文")
            XCTAssertFalse(request.headers.values.contains { leaks($0) }, "\(request.method) \(request.path) 的头带了明文")
            if !isSubmit {
                XCTAssertFalse(leaks(request.body), "\(request.method) \(request.path) 的请求体带了明文")
            }
        }
    }

    func testNothingPersistedOrTracked() async throws {
        let (fixture, page) = try await runThreeAttempts()
        let stored = String(describing: defaults?.dictionaryRepresentation() ?? [:])
        XCTAssertFalse(leaks(stored), "明文进了偏好")
        XCTAssertFalse(leaks(String(describing: fixture.tracked.events)), "明文进了埋点")
        XCTAssertFalse(storedFiles().contains { data in secrets.contains { data.range(of: Data($0.utf8)) != nil } },
                       "明文进了缓存文件")
        for record in fixture.pendingBackend.list(account: "user-a") {
            XCTAssertFalse(leaks(record.body) || leaks(record.summary), "明文进了未决记录（\(record.operationId)）")
        }
        XCTAssertFalse(leaks(fixture.system.last ?? ""), "明文进了剪贴板")
        XCTAssertTrue(page.state.name.isEmpty, "成功后内存清掉姓名")
        XCTAssertTrue(page.state.idNo.isEmpty, "成功后内存清掉身份证号")
    }

    /// 离开页面清空已填内容（结果未知也一样，不为重试保留到页外）。
    func testLeaveClearsInput() async throws {
        scriptAlwaysUnverified()
        script.on("POST \(Self.path)", .disconnect)
        let fixture = make()
        let page = try await submitOnce(fixture)
        page.leave()
        XCTAssertTrue(page.state.name.isEmpty)
        XCTAssertTrue(page.state.idNo.isEmpty)
        XCTAssertTrue(fixture.pendingBackend.list(account: "user-a").allSatisfy { !leaks($0.body) }, "未决记录带了明文")
    }

    /// 生产实名接线（非 Debug、非生成物）存在，且所在源码不打印；同意记录不进视图（G-W24 守卫照旧）。
    func testProductionSourcesWiredWithoutLogging() throws {
        let files = try productionSources().filter { $0.text.contains("\"submitRealname\"") }
        XCTAssertFalse(files.isEmpty, "生产源码没有接 submitRealname（N-32 空实现仍在）")
        for file in files {
            for banned in ["print(", "debugPrint(", "NSLog(", "os_log(", "Logger(", "dump("] {
                XCTAssertFalse(file.text.contains(banned), "\(file.path) 不得打印：\(banned)")
            }
            XCTAssertFalse(file.path.hasPrefix("Packages/Features/Sources/"), "实名接口不进视图层：\(file.path)")
        }
        let consent = try productionSources().filter {
            $0.text.contains("\"id_verification\"") && $0.text.contains("\"realname_sheet\"")
        }
        XCTAssertFalse(consent.isEmpty, "生产源码没有记实名单独同意（id_verification / realname_sheet）")
        XCTAssertTrue(consent.allSatisfy { !$0.path.hasPrefix("Packages/Features/Sources/") }, "同意记录不进视图层")
    }

    private func productionSources() throws -> [(path: String, text: String)] {
        let repo = WalletVisualData.repo()
        var out: [(path: String, text: String)] = []
        let roots = ["App/Sources"] + (try FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent(
            "Packages"
        ).path)).filter { $0 != "Generated" }.map { "Packages/\($0)/Sources" }
        for root in roots {
            let url = repo.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(atPath: url.path) else { continue }
            for case let name as String in walker where name.hasSuffix(".swift") {
                let path = root + "/" + name
                if path.hasPrefix("App/Sources/Debug/") || path.hasPrefix("App/Sources/Generated/") || path
                    .contains("/.build/") {
                    continue
                }
                out.append((path, try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)))
            }
        }
        return out
    }
}
