@testable import Couli
import CryptoKit
import Foundation
import XCTest

/// APP-12w-a 逻辑零改动守卫（brief §0、§5，G-S18）：底版 4621edd 绿，实现后必须仍绿；变了走「需要编排裁定」，不许改基线。
/// 执行器、纯规则钉文件哈希；视图文件允许改版式，只钉回调结构体的文件段与关键字面（实现者可以拆文件，按整个功能目录找）。
final class SettingsVisualGuardTests: XCTestCase {
    private func read(_ path: String) throws -> Data {
        try Data(contentsOf: WalletVisualData.repo().appendingPathComponent(path))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func digest(_ text: String) -> String {
        digest(Data(text.utf8))
    }

    /// 功能目录全部源码拼起来（空白折叠版另给，字面比较不受换行影响）。
    private func featureSource() throws -> String {
        let url = WalletVisualData.repo().appendingPathComponent("Packages/Features/Sources/Me/")
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertFalse(names.isEmpty, "功能目录读不到（守卫失效）")
        return try names.map { try String(contentsOf: url.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
    }

    private func folded(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// 从 `start` 到第一处顶格 `}`（含）的文件段。
    private func segment(_ text: String, from start: String) throws -> String {
        let begin = try XCTUnwrap(text.range(of: start), "找不到 \(start)").lowerBound
        let end = try XCTUnwrap(text.range(of: "\n}\n", range: begin..<text.endIndex), "\(start) 没有结束").upperBound
        return String(text[begin..<end])
    }

    /// 执行器与纯规则逐字节不变（MeRepository、MePresentation、MeView 等已由 `MeVisualFundsGuardTests` 钉）。
    func testLogicFilesByteIdentical() throws {
        let pinned: [String: String] = [
            "Packages/Core/Sources/MeCore/SettingsController.swift":
                "af714b1ce93fa5880ec8f7f7bbd38216a4b48f812c89e9f957d50d2e94e4ddfc",
            "Packages/Core/Sources/MeCore/SettingsItems.swift":
                "988cd419de52b5ea6b33ad3cb3304893fc2b2136c0e798417c87cbe81811347f",
            "Packages/Core/Sources/MeCore/NicknameRules.swift":
                "3978bb5552a6447a2141242688085b92f971d03df8ed761c69b9ac1f9c7cac8c",
            "Packages/Core/Sources/MeCore/MeDeps.swift":
                "e888fafe4d96c1fbec6f66a100d253be6b4da01dab04a3bd3651c3ba5a28b48a",
            "Packages/Core/Sources/MeCore/MeSupport.swift":
                "5ac5f71f68c7450b7e3c0aca9d129186334a0ff47e0b6f7de9d6ab6b266773d1",
            "Packages/Core/Sources/MeCore/MePageHost.swift":
                "6fde193124dc276c23ebb436a26eae5fc2e90e7f0b8b5639361b51632351f843",
            "App/Sources/Me/AppMe.swift": "3836bbc1e2ca7fdb7b8c927e93368d86fd27223713f51320df500ea53c60b179",
            "App/Sources/Me/AppMe+Pages.swift": "60fc0517af8fbe9de4594ad6108ea7094c328cb26a7c37e573849ec502f30d92",
        ]
        for (path, expected) in pinned.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(digest(try read(path)), expected, "\(path) 被改（brief §0）")
        }
    }

    /// 子页执行器：只许为 G-S14 多含 `systemStatus` 的行（状态字段与 `refreshSystem` 里的一次赋值），其余行逐字节不变。
    func testSubControllersOnlyAddSystemStatus() throws {
        let path = "Packages/Core/Sources/MeCore/SettingsSubControllers.swift"
        let text = try XCTUnwrap(String(bytes: read(path), encoding: .utf8))
        let kept = text.components(separatedBy: "\n").filter { !$0.contains("systemStatus") }.joined(separator: "\n")
        XCTAssertEqual(digest(kept), "9bdfd0fc97ce0da2a7d078a1887f5d639f47a6e4d35c27daa9c3b460a41dfc8a", path)
    }

    /// 已有向量（含 visualMe）逐字节不变；visualSettings 与 Android 合入版逐字节相同。
    func testVectorsByteIdentical() throws {
        let data = try read("specs/me-vectors.json")
        let cut = try XCTUnwrap(data.range(of: Data("  \"visualSettings\": {".utf8)), "缺 visualSettings").lowerBound
        XCTAssertEqual(digest(data[data.startIndex..<cut]),
                       "17aaa182f561c50793f5b8ec241c2e9dd3c1a1b859d8492bea70d0f984144e0b", "已有向量被改（G-S18）")
        XCTAssertEqual(digest(data[cut..<data.endIndex]),
                       "700839b8500a1a2627fa6c3280de450d5c1bfc7f9c27ec6eb8fc3894ac40695b",
                       "visualSettings 与 Android 不一致")
    }

    /// 回调结构体：渲染时捕获执行器与版本（共性第 6、13、20 条），换控件也不改这三段。
    func testActionStructsKept() throws {
        let source = try featureSource()
        let pinned = [
            "public struct SettingsActions {": "d17f3d65b5ba51ef8a0a6bc2c29d04b837f3d7ebeba0e3349cba0297815a749c",
            "public struct NicknameActions {": "5e4067508939a18ab7604d07d20a6b86341898caeec16f65182777770f99512c",
            "public struct NotifyActions {": "339e6207e6227b5318b60779cba57c8d087191631fbfb2eb918b7c78aa955257",
        ]
        for (start, expected) in pinned.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(digest(try segment(source, from: start)), expected, "\(start) 被改")
        }
    }

    /// 页面与执行器的接线：逐条是逻辑点，改写法也要保留语义；空白不敏感。
    func testViewWiringKept() throws {
        let source = folded(try featureSource())
        let kept = [
            // 换身份整页重建；撤回中整页禁用；有弹层时藏返回
            ".id(host.serial)",
            ".disabled(withdraw.busy)",
            ".navigationBarBackButtonHidden(state.dialog != nil || state.sheet != nil)",
            // 半屏遮罩按一次性编号关闭；三处弹层关闭后焦点回触发行
            "dismissOnScrim: { state.sheet.map(actions.closeSheet) }",
            "restoreFocusTo: $agreementFocused",
            "restoreFocusTo: $logoutFocused",
            "restoreFocusTo: $clearFocused",
            // 子页返回只关子页
            ".meSubpageBack(texts.text(\"me.back\"), action: actions.closeSub)",
            // 42901 页面层
            "retryEnabled: !controller.readBlocked",
            "enabled: !controller.resetTipBlocked",
            "enabled: !state.switching && !gate.blocked",
            // G-S10：30415 后不置灰，可点性判定不改
            "isEnabled: state.check.saveEnabled && !state.saving && !gate.blocked",
            // 回前台只查不申请
            ".onChange(of: scenePhase)",
            "controller.refreshSystem()",
            // 错误 assertive 一次、布局后移焦
            "MeAnnounce.post(error.message(texts), assertive: true)",
            "guard event != announced, let error = controller.state.error else { return }",
            "MeAnnounceProbe.focused?(\"nickname.error\")",
            // 退出、清缓存确认只走编号回调
            "actions.confirmLogout(dialog)",
            "actions.confirmClear(dialog)",
            // 通知 Release 分支（G-S13）
            "if controller.hasSwitch, let service = state.service {",
        ]
        for literal in kept {
            XCTAssertTrue(source.contains(literal), "接线被改：\(literal)")
        }
    }

    /// BR-ID-13：设置一族不走权限申请；G-S04：不拼脱敏号码；剪贴板用途说明不回来（D10-423）。
    func testForbiddenWordsAbsent() throws {
        let source = try featureSource()
        for word in [
            "requestAuthorization",
            "PermissionRequester",
            "maskedPhone",
            "stepUpPhone",
            "\"clipboard.consent.",
        ] {
            XCTAssertFalse(source.contains(word), "功能目录出现 \(word)")
        }
    }

    /// G-S12：开关行读屏「名称，开关，状态」+ 说明（iOS 现状 `.ignore` 把副标题丢了）。状态在 value、说明在 hint，XCUI 读不到 hint，这里看字面，真机批次再核。
    func testSwitchRowSpeaksSubtitle() throws {
        let body = try segment(featureSource(), from: "struct MeSwitchRow: View {")
        XCTAssertTrue(body.contains(".accessibilityHint("), "副标题要作读屏说明（G-S12）")
    }
}
