@testable import Couli
import CryptoKit
import Foundation
import XCTest

/// APP-12w-b 逻辑零改动守卫（brief §0.1、§5；隐私红线页）：底版 ffd404c 绿，实现后必须仍绿；变了走「需要编排裁定」，不许改基线。
/// 执行器、纯规则钉文件哈希；视图允许改版式，只钉回调结构体的文件段与接线字面（实现者可以拆文件，按整个功能目录找）。
final class PrivacyVisualGuardTests: XCTestCase {
    private let featurePath = "Packages/Features/Sources/Me/"

    private func read(_ path: String) throws -> Data {
        try Data(contentsOf: WalletVisualData.repo().appendingPathComponent(path))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func featureFiles() throws -> [(name: String, text: String)] {
        let url = WalletVisualData.repo().appendingPathComponent(featurePath)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertFalse(names.isEmpty, "功能目录读不到（守卫失效）")
        return try names.map { try ($0, String(contentsOf: url.appendingPathComponent($0), encoding: .utf8)) }
    }

    /// 本组三个页面（含实现者新拆的 Privacy* / About* / Cs* 文件）。
    private func pageSource(_ prefix: String...) throws -> String {
        try featureFiles().filter { file in prefix.contains { file.name.hasPrefix($0) } }.map(\.text)
            .joined(separator: "\n")
    }

    private func folded(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func segment(_ text: String, from start: String) throws -> String {
        let begin = try XCTUnwrap(text.range(of: start), "找不到 \(start)").lowerBound
        let end = try XCTUnwrap(text.range(of: "\n}\n", range: begin..<text.endIndex), "\(start) 没有结束").upperBound
        return String(text[begin..<end])
    }

    /// 执行器、纯规则、撤回协调器、向量、契约逐字节不变。
    func testRedLineFilesByteIdentical() throws {
        let pinned: [String: String] = [
            "Packages/Core/Sources/MeCore/PrivacyCenterController.swift":
                "d0e5470b1673c430399dd1add5b6f0123a427408cb56ef5d9ec55b32d16550a5",
            "Packages/Core/Sources/MeCore/PrivacyCenterView.swift":
                "71874283bb504603af43609dfafecba0e5cf96c6f40f7574e6e29c61a4ecbafb",
            "Packages/Core/Sources/MeCore/AboutController.swift":
                "86bb750f85f78c31a5d253aa3dc1f147ab07a82be61cef7b217b530384221bfb",
            "Packages/Core/Sources/MeCore/AboutRules.swift":
                "4427e9f53af0794d43c26f1d49b9b8351bf4876a9e44d13a55c3cf9d63023a60",
            "Packages/Core/Sources/MeCore/CsRules.swift":
                "94bb0bf72a41dd03230ae4fc40b20b29a22c9209374f8527e1dbd091b83159e9",
            "Packages/Core/Sources/MeCore/CustomerServiceEntry.swift":
                "7596cfc8831a223a9732acfc2e7adc817c580b399da60b73095ad03e38d17132",
            "Packages/Core/Sources/Privacy/PrivacyGate.swift":
                "b0d6a7e2efc675ac3ed7e671ba2c9a20fef77724fbe48c184248a96db19f5d4f",
            "App/Sources/Privacy/PrivacyController.swift":
                "ac0d9d6853b0ce16beeb74a080d8f8e2e704a7517e5a6bb9df920d95f3a94c4f",
            "App/Sources/Me/MeRouteViews.swift":
                "3a32258056218f8c4b0f97f86ed93f02c1302a14740bd5de27d3990b11da9a72",
            "App/Sources/Me/AppMe+Flows.swift":
                "ea68a8bf4c9aa02761e024d35eb8101e32360887ebe6d4fe524f69e386e639f1",
            "contract.lock":
                "1734695f1b3b186be02520bcf8606f4a3d7a2510b63f5ad0862e60c437bdc5da",
            "contracts/snapshot/specs/system-permissions.json":
                "bd7c09ae405d0ed5493704be0a51e59ec2628bf7a0c24c2433c39acfe8175b2f",
            "specs/me-vectors.json":
                "c40b21e1e9da5a12c0ba5b2401f593c3fb258d4e8a46d028b4c8485b64dff05d",
        ]
        for (path, expected) in pinned.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(digest(try read(path)), expected, "\(path) 被改（brief §0.1）")
        }
    }

    /// 回调结构体：渲染时捕获执行器、版本、半屏编号（共性第 6、7、13、20 条），换控件也不改这两段。
    func testActionStructsKept() throws {
        let source = try featureFiles().map(\.text).joined(separator: "\n")
        let pinned = [
            "public struct PrivacyCenterActions {": "8c4b71b7b39070c157e843aef2d146223fbbb16d11c9a1fd01a0308142450d4f",
            "public struct CsActions {": "43e0f14d74b65b3beec53501617d108f8135523d71e18d6369feb4a343294434",
        ]
        for (start, expected) in pinned.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(digest(Data(try segment(source, from: start).utf8)), expected, "\(start) 被改")
        }
    }

    /// 隐私中心接线：逐条是红线点（§0.1）；空白不敏感，改写法也要保留语义。
    func testPrivacyWiringKept() throws {
        let source = folded(try pageSource("Privacy"))
        for literal in [
            // 换身份整页重建；撤回 / 确认框显示时藏系统返回；回前台只查
            ".id(host.serial)",
            ".navigationBarBackButtonHidden(state.dialog != nil || withdraw.busy)",
            "controller.refresh()",
            // 确认框：一次性编号、【取消】主、【确认撤回】次、关闭后焦点回按钮
            ".couliDialog(isPresented: state.dialog != nil, restoreFocusTo: $withdrawFocused)",
            "primary: CouliDialogAction(texts.text(\"privacy.withdraw.confirm.cancel\")) { "
                + "actions.cancelWithdraw(dialog)",
            "secondary: CouliDialogAction(texts.text(\"privacy.withdraw.confirm.ok\")) { "
                + "actions.confirmWithdraw(dialog) }",
            // 【撤回同意】 loading / 禁用条件、去向
            "isLoading: withdraw.busy",
            "isEnabled: !withdraw.busy",
            "action: actions.askWithdraw",
            ".accessibilityFocused($withdrawFocused)",
            // 显隐只认模型（§5「不得另读状态决定显隐」）
            "if model.enableFullButton {",
            "if model.personalizationSwitch {",
            "if model.permissionSection {",
            "if model.withdrawButton {",
            "if !model.permissionRows.isEmpty {",
            // 开启完整功能、个性化、清单、权限
            "action: actions.enableFull",
            "onChange: actions.personalization",
            "isOn: state.personalizationOn",
            "enabled: !withdraw.busy",
            "actions.document(row.type)",
            "actions.permission(row.type)",
            "DocumentRow(key: \"privacy_center.collect_list\", type: \"privacy\", id: \"privacy.list.collect\")",
            "DocumentRow(key: \"privacy_center.share_list\", type: \"sdk_list\", id: \"privacy.list.share\")",
            "DocumentRow(key: \"privacy_center.privacy_policy\", type: \"privacy\", id: \"privacy.policy\")",
            "DocumentRow(key: \"privacy_center.agreement\", type: \"agreement\", id: \"privacy.agreement\")",
            // 轻提示
            ".meToast(state.toast, texts: texts) { controller.consumeToast($0) }",
        ] {
            XCTAssertTrue(source.contains(literal), "接线被改：\(literal)")
        }
    }

    /// 关于、客服接线。
    func testAboutAndCsWiringKept() throws {
        let about = folded(try pageSource("About"))
        for literal in ["if let filing = controller.filing {", "controller.copyDiagnostics()",
                        ".meToast(controller.toast, texts: texts) { controller.consumeToast($0) }"] {
            XCTAssertTrue(about.contains(literal), "关于接线被改：\(literal)")
        }
        let sheet = folded(try pageSource("Cs"))
        for literal in [
            "let actions = CsActions.make(entry, sheet)",
            "ForEach(sheet.decision.buttons, id: \\.self)",
            "case CsEntryDecision.openWechat:",
            "case CsEntryDecision.retry:",
            "case CsEntryDecision.copyLink:",
            "action: actions.openWechat",
            "action: actions.copyLink",
            "action: actions.goHelp",
            "Button(action: actions.close)",
            "if let toast = entry.toast {",
            ".task(id: toast.id)",
            "MeAnnounce.post(toast.message(texts), assertive: false)",
            ".accessibilityFocused($titleFocused)",
            "titleFocused = true",
        ] {
            XCTAssertTrue(sheet.contains(literal), "客服接线被改：\(literal)")
        }
        XCTAssertEqual(sheet.components(separatedBy: "action: actions.openWechat").count - 1, 2, "打开微信、重试两处")
    }

    /// 遮罩不关闭：`couliDialog` 恒走 `dismissOnScrim: nil`。
    func testDialogScrimStaysInert() throws {
        let path = "Packages/DesignSystem/Sources/DesignSystem/Components/Modals.swift"
        let source = folded(try XCTUnwrap(String(bytes: read(path), encoding: .utf8)))
        XCTAssertTrue(source.contains("modifier(ModalOverlayModifier(isPresented: isPresented, alignment: .center, "
                + "dismissOnScrim: nil, restoreFocus: restoreFocusTo, panel: dialog))"), "couliDialog 遮罩语义被改")
    }

    /// 本组页面不发请求、不申请权限、不直接开外链 / 剪贴板；隐私中心没有注销入口（§0.1 红线 ③）；说明句不是链接；不写色值。
    func testForbiddenWordsAbsent() throws {
        let pages = try pageSource("Privacy", "About", "Cs")
        for word in [
            "requestAuthorization", "PermissionRequester", "UIPasteboard", "UIApplication", "openURL", "api.send",
            "getMe", "DeleteAccount", "deleteAccount", "delete_account", "Color(red:", "UIColor(", "Color(hex",
        ] {
            XCTAssertFalse(pages.contains(word), "本组页面出现 \(word)")
        }
        let privacy = try pageSource("Privacy")
        for word in ["onTapGesture", "Link(", "AttributedString", "openURL", "TextLink"] {
            XCTAssertFalse(privacy.contains(word), "隐私中心说明句不得变成可点（§0.1）：\(word)")
        }
    }

    /// G-P08：基本模式卡不再渲染副句（草稿键保留）。
    func testBasicDescNotRendered() throws {
        XCTAssertFalse(try pageSource("Privacy").contains("privacy_center.basic_desc"), "G-P08")
        let table = try XCTUnwrap(String(
            bytes: read("Packages/Core/Sources/MeCore/MeDraftTable.swift"),
            encoding: .utf8
        ))
        XCTAssertTrue(table.contains("\"privacy_center.basic_desc\":"), "键保留不删")
    }

    /// K2：隐私中心的个性化行仍把说明交给 `MeSwitchRow`（`.accessibilityHint`），状态不被说明覆盖。XCUI 读不到 hint，这里看字面，真机批次再核。
    func testPersonalizationSpeaksDescription() throws {
        let source = folded(try pageSource("Privacy"))
        XCTAssertTrue(source.contains("subtitle: texts.text(\"privacy_center.personalization_desc\")"), "说明进读屏")
        let row = try segment(
            try featureFiles().map(\.text).joined(separator: "\n"),
            from: "struct MeSwitchRow: View {"
        )
        XCTAssertTrue(row.contains(".accessibilityHint(Text(verbatim: subtitle ?? \"\"))"), "K2")
        XCTAssertTrue(row.contains(".accessibilityLabel(Text(verbatim: title))"), "名称不被说明覆盖")
    }
}
