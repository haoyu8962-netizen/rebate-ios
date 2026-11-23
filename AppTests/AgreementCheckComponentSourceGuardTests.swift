import Foundation
import XCTest

/// FU-IOS-AGREEMENT-CHECK-COMPONENT 源码守卫（口径「组件改一处同步所有页面」）：去注释后匹配（工具同 ShellSystemTabBarSourceTests.stripComments）。
/// - Features 与 App 下不得再有私有勾选画法（登录 `CheckBox` 圆角方框、收款 `CheckMark`、注销 SF Symbol 方框）；
/// - 登录协议行、收款勾选行（实名同意 / 劳务协议）、注销 waiver 三处都引用组件库件（`CouliCheckGlyph`，或包着它的行容器 `CouliAgreementCheckRow`）。
/// 524f89e 上两条都红：三种私有画法都在，三处页面都没引用组件库件。
final class AgreementCheckComponentSourceGuardTests: XCTestCase {
    private static let component = #"(?<![\w.])(CouliCheckGlyph|CouliAgreementCheckRow)\b"#

    /// 私有勾选画法清单：Features + App 都查的，与只查 Features 的（App 调试面板 DebugPanelView 的列表选中勾不是协议勾选，不算）。
    func testNoPrivateCheckDrawingsInFeaturesOrApp() throws {
        let everywhere = [
            #"\bstruct\s+(CheckBox|CheckMark)\b"#,
            #"(?<![\w.])(CheckBox|CheckMark)\s*[(.]"#,
            #""checkmark\.(square|circle)[\w.]*""#,
            #"systemName:[^\n]*"(square|square\.fill|circle|circle\.fill)""#,
        ]
        let featuresOnly = [
            #"systemName:\s*"checkmark""#,
        ]
        var found: [String] = []
        for (directory, patterns) in [
            ("Packages/Features/Sources", everywhere + featuresOnly),
            ("App/Sources", everywhere),
        ] {
            for file in try AgreementCheckComponentSource.files(under: directory) {
                for pattern in patterns where file.code.range(of: pattern, options: .regularExpression) != nil {
                    found.append(file.path + ": " + pattern)
                }
            }
        }
        XCTAssertEqual(found, [], "协议勾选统一用 DesignSystem 的 CouliCheckGlyph，页面里不再自画方框 / 圆 / 系统勾符号")
    }

    /// 三处页面都引用组件库件；若另有行容器 `CouliAgreementCheckRow`，它自己必须用 `CouliCheckGlyph` 画圆（同一个外观来源）。
    func testThreePagesUseDesignSystemGlyph() throws {
        func uses(_ path: String) throws -> Bool {
            try AgreementCheckComponentSource.code(path).range(of: Self.component, options: .regularExpression) != nil
        }
        XCTAssertTrue(try uses("Packages/Features/Sources/Login/LoginView+Fields.swift"),
                      "登录协议行（LoginView+Fields.swift agreementRow）引用组件库 CouliCheckGlyph")
        XCTAssertTrue(try uses("Packages/Features/Sources/Me/DeleteAccountScreen+Form.swift"),
                      "注销 waiverRow（DeleteAccountScreen+Form.swift）引用组件库 CouliCheckGlyph")
        let wallet = "Packages/Features/Sources/Wallet/"
        let payout = try uses(wallet + "PayoutVisualParts.swift")
            || (uses(wallet + "IdentityScreens.swift") && uses(wallet + "LaborAgreementScreen.swift"))
        XCTAssertTrue(payout, "收款勾选行：PayoutVisualParts.swift 的 CheckRow，或实名同意 / 劳务协议两处调用点，引用组件库 CouliCheckGlyph")
        if let row = try AgreementCheckComponentSource.typeSource("CouliAgreementCheckRow") {
            XCTAssertNotNil(row.range(of: #"(?<![\w.])CouliCheckGlyph\("#, options: .regularExpression),
                            "行容器 CouliAgreementCheckRow 用 CouliCheckGlyph 画圆，不另画")
        }
    }
}
