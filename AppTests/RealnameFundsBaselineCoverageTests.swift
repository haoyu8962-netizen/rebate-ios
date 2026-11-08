@testable import Couli
import Foundation
import XCTest

/// 资金零改动基线的覆盖面（v1.5，编排：RealNameController+Idempotency.swift 拆出后跑出了守卫）：WithdrawVisualBaseline.logicFiles 的口径是
/// 「WalletCore 全部源文件（除文案表 WalletDraftTable*.swift、WalletTexts.swift）」——目录里的逻辑文件必须一个不少都在基线里，
/// 以后拆文件、加文件都要走 #24 登记摘要。
final class RealnameFundsBaselineCoverageTests: XCTestCase {
    func testEveryWalletCoreLogicFileIsInBaseline() throws {
        let root = "Packages/Core/Sources/WalletCore/"
        let names = try FileManager.default.contentsOfDirectory(
            atPath: WalletVisualData.repo().appendingPathComponent(root).path
        )
        let logic = Set(names.filter {
            $0.hasSuffix(".swift") && !$0.hasPrefix("WalletDraftTable") && $0 != "WalletTexts.swift"
        }.map { root + $0 })
        let baseline = Set(WithdrawVisualBaseline.logicFiles.keys)
        XCTAssertEqual(logic.subtracting(baseline).sorted(), [], "WalletCore 逻辑文件不在资金基线里")
        XCTAssertEqual(baseline.subtracting(logic).sorted(), [], "资金基线里有已不存在的文件")
    }
}
