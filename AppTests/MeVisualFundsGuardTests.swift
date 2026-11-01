@testable import Couli
import CryptoKit
import Foundation
import MeCore
import XCTest

/// APP-12v 逻辑零改动证明与金额守卫（brief §3、§5；类名含 Funds，D10-512 不吃 verify 重试）：底版 8f6a740 绿，实现后必须仍绿；变了走「需要编排裁定」，不许改基线。
/// iOS 的执行器、纯规则全在 MeCore，视图在 Features/Me，本组钉死前者、对后者做字面检查。
final class MeVisualFundsGuardTests: XCTestCase {
    private let feature = "Packages/Features/Sources/Me/"

    private func read(_ path: String) throws -> Data {
        try Data(contentsOf: WalletVisualData.repo().appendingPathComponent(path))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 「我的」功能目录全部源码（实现者可以拆文件，守卫跟着走）。
    private func featureSources() throws -> [(name: String, text: String)] {
        let url = WalletVisualData.repo().appendingPathComponent(feature)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertFalse(names.isEmpty, "功能目录读不到（守卫失效）")
        return try names.map { name in
            try (name, String(contentsOf: url.appendingPathComponent(name), encoding: .utf8))
        }
    }

    /// 只看「我的」Tab 视图的文件（设置一族里有与余额无关的写法，不连带）：实现者新拆的 MeTab* / MeHero* / MeBalance* / MeIdentity* / MeGuide* / MeGrid* 都算。
    private func tabSources() throws -> String {
        let prefixes = ["MeTab", "MeHero", "MeBalance", "MeIdentity", "MeGuide", "MeGrid", "MeToast"]
        return try featureSources().filter { file in prefixes.contains { file.name.hasPrefix($0) } }.map(\.text)
            .joined(separator: "\n")
    }

    /// 纯规则、解析、本机偏好、客服出口、App 环境与清理名单逐字节不变（brief §5）。
    /// test-change（v2）：MeTabController.swift、App/Sources/Me/AppMe.swift、AppMe+Pages.swift 解钉——编排裁定 iOS 受限会话自动读 getMe
    /// 是真缺陷，
    /// 在本任务单独修（F-X-14、followups.md:151、03 受限会话不拉取），改动点就在这三个文件。解钉后由 `testExecutorLinesKept` 钉住其余逻辑。
    func testLogicFilesByteIdentical() throws {
        let pinned: [String: String] = [
            "Packages/Core/Sources/MeCore/MeView.swift":
                "9b7e3cd3c9cad8792b59e6b5e3f9fd41a7efa131c95610c71e11b8837f4fb58c",
            "Packages/Core/Sources/MeCore/MeRepository.swift":
                "55711ac215088cd3dbe71c11c0e3add2d2c9d988284397d70b1ab206b1b75c5b",
            "Packages/Core/Sources/MeCore/MePresentation.swift":
                "3e51563efb9e7aee25f7ed5c0d4fc3883110b080c96d8f3172cc0fc223ae0609",
            "Packages/Core/Sources/MeCore/MeLocalStore.swift":
                "4862eaf040c073a016ffaf3a822823e74f544471f2cdda8963d2b67756a5bff0",
            "Packages/Core/Sources/MeCore/PushReportPolicy.swift":
                "8823ef5d27bb49952aee206bc09ac064c1c0114edf86554d5d8031db66c4200a",
            "Packages/Core/Sources/MeCore/CustomerServiceEntry.swift":
                "7596cfc8831a223a9732acfc2e7adc817c580b399da60b73095ad03e38d17132",
            "Packages/Core/Sources/MeCore/MeJSON.swift":
                "892c3dd6cb22e7fc2dfed18a64d987405696102c49229d85d358ae592189d93f",
            "Packages/Core/Sources/MeCore/MeDraftTexts.swift":
                "d10dff3d0ceae9ca36fb8ba704ca9f21a6df1329522ffa775d0e1ccd9550e751",
            "App/Sources/Me/AppMe+Env.swift": "6ddb7e4d50fead4ac0c54378ff2e2d431a144c426745f006b3b1a02f267abaae",
            "App/Sources/Me/AppMe+Flows.swift": "ea68a8bf4c9aa02761e024d35eb8101e32360887ebe6d4fe524f69e386e639f1",
            "App/Sources/Me/AppMeTexts.swift": "d0106f1080196d718715820f7f5ebd9517b04a4fe6b5d5aeee0728cfa6c887f4",
            "App/Sources/Me/MeRouteViews.swift": "3a32258056218f8c4b0f97f86ed93f02c1302a14740bd5de27d3990b11da9a72",
            "App/Sources/Me/MeSystem.swift": "e7dc880181250359f034368ef803ac2b75d0a33e620fcd644aaf480f063ffbaa",
        ]
        for (path, expected) in pinned.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(digest(try read(path)), expected, "\(path) 被改（brief §5）")
        }
    }

    /// 解钉的三个文件：F-X-14 只加自动路径的受限判定（`autoRefresh`），这些行（快照版本与身份核对、离开撤销、引导条、进入判定）一字不改。
    func testExecutorLinesKept() throws {
        let kept: [String: [String]] = [
            "Packages/Core/Sources/MeCore/MeTabController.swift": [
                // refresh 本身不加 guard：受限判定只在自动路径的 autoRefresh
                "guard alive, identity.member else { return false }\n"
                    + "        return deps.repo.refresh(identity, page: self, pull: pull)",
                "guard alive, snapshot.version == version, snapshot.identity == identity, "
                    + "snapshot.me?.inviteCode == code else {",
                "guard alive, snapshot.version == version, snapshot.identity == identity, "
                    + "snapshot.me != nil else { return }",
                "deps.env.open(MeView.wallet, params: [:], from: nil)",
                "deps.env.openNotificationSettings()",
                "deps.local?.markGuideClosed(deps.env.nowMillis())",
                "deps.repo.release(self)",
                "guard grid.contains(cell) else { return }",
            ],
            "App/Sources/Me/AppMe+Pages.swift": [
                "guard tabVisible, !tabEntered else { return }",
                "if tabHost.controller.hasLeft || tabHost.controller.identity != identity {",
                "tabHost.controller.checkGuideBar()",
                "tabHost.controller.leave()",
                "router.tabRoot.route == Self.me && router.path.isEmpty && sceneActive",
            ],
            "App/Sources/Me/AppMe.swift": ["rebuildPages(next)", "deps.repo.reset(next)", "pushTracker.sync()"],
        ]
        for (path, lines) in kept.sorted(by: { $0.key < $1.key }) {
            let text = try XCTUnwrap(String(bytes: read(path), encoding: .utf8))
            for line in lines {
                XCTAssertTrue(text.contains(line), "\(path) 改了 F-X-14 以外的逻辑：\(line)")
            }
        }
    }

    /// `specs/me-vectors.json` 已有 25 组逐字节不变（visualMe 之前的全部字节，尾部逗号是追加时带来的）。
    func testExistingVectorsByteIdentical() throws {
        let data = try read("specs/me-vectors.json")
        let marker = Data("  \"visualMe\": {".utf8)
        let cut = try XCTUnwrap(data.range(of: marker), "缺 visualMe").lowerBound
        XCTAssertEqual(digest(data[data.startIndex..<cut]),
                       "96d9a9d6333e48c350df050f745c49126008655fb04594c317152d03c01ec464", "已有向量被改（G-M18）")
    }

    /// 草稿表只新增（me.amount_shown，G-M16）：去掉这一行后与底版逐字节一致。
    func testDraftTableOnlyAdds() throws {
        let path = "Packages/Core/Sources/MeCore/MeDraftTable.swift"
        let text = try XCTUnwrap(String(bytes: read(path), encoding: .utf8))
        let kept = text.components(separatedBy: "\n").filter { !$0.contains("\"me.amount_shown\"") }
        XCTAssertEqual(digest(Data(kept.joined(separator: "\n").utf8)),
                       "1188ce7f79435b7ee164a4000b170665b54296f0353faa2287ba165788a669f1", "已有草稿被改")
    }

    /// 回调捕获渲染时值（共性第 63 条）：版本与码在渲染时取出，【提现】、复制带它们执行。
    func testActionsCaptureRenderedValues() throws {
        let source = try tabSources()
        for literal in ["let version = snapshot.version",
                        "let code = snapshot.identity == controller.identity ? snapshot.me?.inviteCode : nil",
                        "controller?.copyInviteCode(version: version, code: code)",
                        "controller?.withdraw(version: version)"] {
            XCTAssertTrue(source.contains(literal), "渲染时回调被改：\(literal)")
        }
    }

    /// 金额不用浮点（硬规则 3）：Tab 视图禁字面 `Float(`、`Double(`（`CGFloat(` 也命中，尺寸换算用令牌，同钱包口径）。
    func testNoFloatingPointInTabSources() throws {
        let source = try tabSources()
        XCTAssertFalse(source.isEmpty, "Tab 视图源码读不到（守卫失效）")
        for literal in ["Float(", "Double("] {
            XCTAssertFalse(source.contains(literal), "Tab 视图出现 \(literal)")
        }
    }

    /// 余额卡只取服务端两个显示字段：视图不碰 available、不做加减、不接钱包摘要与待抵扣推算（G-M02 / G-M03）。
    func testBalanceNeverDerived() throws {
        let source = try tabSources()
        for word in ["availableFen", "available_fen", "wallet/summary", "WalletSummary", "negativeFen",
                     "negative_fen"] {
            XCTAssertFalse(source.contains(word), "Tab 视图出现 \(word)")
        }
        let arithmetic = #"(withdrawable|estimated)\w*\s*[-+*/]\s*\S"#
            + #"|\S\s*[-+*/]\s*(view\.)?(withdrawable|estimated)\w*"#
        XCTAssertNil(source.range(of: arithmetic, options: .regularExpression), "金额字段上出现算术")
    }

    /// 宫格只经 Router：Tab 视图不直接开 Withdraw（G-M05），引导条不走权限申请（BR-ID-13）。
    func testTabSourcesKeepExits() throws {
        let source = try tabSources()
        for word in ["\"Withdraw\"", "requestAuthorization", "PermissionRequester"] {
            XCTAssertFalse(source.contains(word), "Tab 视图出现 \(word)")
        }
    }
}
