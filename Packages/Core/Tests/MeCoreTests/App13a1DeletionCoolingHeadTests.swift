import Foundation
@testable import MeCore
import XCTest

/// APP-13a-1-ios 写测（独立写测方）：冷静期卡片的徽标与标题键（编排 D10-2126 ②）。
/// can_cancel=true 仍是「冷静期中」+「注销申请已提交」；can_cancel=false 改用时间线「注销处理」一组现有契约键，
/// 标题带 {process_workdays}（页面用 format 渲染），不再说「冷静期」。键的文字读 contracts/snapshot/contracts/texts.default.json。
final class App13a1DeletionCoolingHeadTests: XCTestCase {
    private struct RootNotFound: Error {}

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { throw RootNotFound() }
            directory = parent
        }
        return directory
    }

    /// 快照 texts.default.json 的键 → 文字。
    private func contractTexts() throws -> [String: String] {
        let url = try repositoryRoot().appendingPathComponent("contracts/snapshot/contracts/texts.default.json")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "texts.default.json 不是对象"
        )
        // 文案在顶层 texts 对象里（同级还有 version、fallbacks）
        let texts = try XCTUnwrap(root["texts"] as? [String: Any], "texts.default.json 缺 texts 对象")
        XCTAssertFalse(texts.isEmpty, "texts.default.json 为空（守卫失效）")
        return texts.compactMapValues { $0 as? String }
    }

    /// 两种取值逐字钉住。
    func testHeadKeysFollowShowCancel() {
        let cooling = DeletionCoolingHead.of(showCancel: true)
        XCTAssertEqual(cooling.badgeKey, "deletion.cooling.badge")
        XCTAssertEqual(cooling.titleKey, "deletion.cooling.title")
        XCTAssertFalse(cooling.titleNeedsWorkdays, "冷静期标题不带占位，用 text 取")

        let processing = DeletionCoolingHead.of(showCancel: false)
        XCTAssertEqual(processing.badgeKey, "deletion.timeline.processing")
        XCTAssertEqual(processing.titleKey, "deletion.timeline.processing_desc")
        XCTAssertTrue(processing.titleNeedsWorkdays, "处理中标题带 {process_workdays}，用 format 渲染")
        XCTAssertNotEqual(cooling, processing)
    }

    /// can_cancel=false 用的两个键在契约字典里：标题含 {process_workdays}、不含「冷静期」；徽标是「注销处理」。
    func testProcessingHeadKeysExistInContractTexts() throws {
        let texts = try contractTexts()
        let head = DeletionCoolingHead.of(showCancel: false)
        let title = try XCTUnwrap(texts[head.titleKey], "契约缺 \(head.titleKey)")
        XCTAssertTrue(title.contains("{process_workdays}"), "标题要带 {process_workdays}：\(title)")
        XCTAssertFalse(title.contains("冷静期"), "can_cancel=false 的标题不说冷静期：\(title)")
        let badge = try XCTUnwrap(texts[head.badgeKey], "契约缺 \(head.badgeKey)")
        XCTAssertEqual(badge, "注销处理")
        XCTAssertFalse(badge.contains("冷静期"))

        let cooling = DeletionCoolingHead.of(showCancel: true)
        XCTAssertNotNil(texts[cooling.badgeKey], "契约缺 \(cooling.badgeKey)")
        XCTAssertNotNil(texts[cooling.titleKey], "契约缺 \(cooling.titleKey)")
    }

    /// 从显示规则的现有输入走一遍：冷静期记录 can_cancel=false → showCancel=false → 处理中那一组。
    func testCoolingRecordWithoutCancelUsesProcessingHead() {
        let funds = DeletionFunds(withdrawableFen: 1000, estimatedFen: 1019, negativeFen: 0)
        let record = Deletion(
            status: Deletion.cooling, applyAtMillis: 1_790_904_600_000, coolingUntilMillis: 1_791_509_400_000,
            canCancel: false, cancelledAtMillis: nil, cancelReason: nil
        )
        let view = DeletionPresentation.view(DeletionInput(read: .record(record), funds: funds, phoneBound: true))
        XCTAssertEqual(view.kind, .cooling)
        XCTAssertFalse(view.showCancel, "can_cancel=false：没有【撤回注销】")
        let head = DeletionCoolingHead.of(showCancel: view.showCancel)
        XCTAssertEqual(head.badgeKey, "deletion.timeline.processing")
        XCTAssertEqual(head.titleKey, "deletion.timeline.processing_desc")
        XCTAssertTrue(head.titleNeedsWorkdays)
    }
}
