import Foundation
@testable import HomeCore
import XCTest

/// specs/home-sdui-vectors.json 的执行器（三端共用一份向量；数据来源是 Codex 早先写的向量，APP-11-ios 测试作者逐条核对过，结论见
/// NATIVE/APP-11/ios-tests-handback.md「向量核对」）。执行写法照 Codex 原稿（NATIVE/APP-11/codex/HomeVectorTests.swift），改动：
/// - `preview` 组不在这里跑：HomePreviewPolicy 只在 App 的 Debug / Staging 源码里（类名含 debug_only 路由名 HomePreview，进不了包，
///   release-scan 按路由名查），对应执行器在 AppTests/HomePreviewVectorTests.swift；
/// - 生产侧的 JSON 入口照原稿（只做类型转换，生产内部用强类型模型）：
///   - `HomeJson.decode(pageJson:platform:appVersion:)` → `pageValid / kept[{id,type,itemCount}] /
/// skipped[{id,reasonRaw}] /
///     dropped[{id,type,version,reasonRaw}] / popupId`；
///   - `HomeSectionFilter.keep(minAppVersionJsonOrNull:absent:platform:appVersion:)`；
///   - `HomeSourcePolicy()` + `on(event:arg:)` → `actionsRaw / showing / refreshDisabledMs`；
///   - `HomeLkgScope.of(level:userId:env:)`、`HomeLocalData.clearsOn(event:item:)`；
///   - `NoticeFilter.visible(sectionId:itemsJson:closedKeys:nowMs:)` → `visibleItemIds / closable / cardHidden /
/// nextExpiryMs`，
///     `NoticeFilter.closeKey(sectionId:itemId:contentVersion:)`；
///   - `PopupPolicy.decide(popupJson:level:nowMs:shownToday:coldStartShown:blockers:imageLoaded:)` → `decisionRaw /
/// countAfter`；
///   - `RouteTargetCheck.decode(json:)`、`HomeSpm.of(sectionId:slot:)`、`HomeAdLabel.of(sectionLabel:itemLabel:)`；
///   - `ExposureTracker(sectionId:slot:)` + `onVisible(tMs:ratio:stay:)`、`CardErrorDedupe()` +
/// `shouldSend(pageVersion:sectionId:reason:)`。
/// 时刻一律带 +08:00 转绝对毫秒，不读系统时钟；版本比较由生产复用 `UpdateGate.compareVersions`，这里不另写比较器。
final class HomeVectorTests: XCTestCase {
    typealias JSONObject = [String: Any]

    private let groups = [
        "pageDecode", "minAppVersion", "sourcePolicy", "lkgScope", "localDataClear", "notice", "noticeCloseKey",
        "popup", "action", "spm", "adLabel", "exposure", "cardErrorDedupe",
    ]

    func testManifest() throws {
        let root = try HomeVectors.root()
        let version: Int = try field(root, "version")
        XCTAssertEqual(version, 1)
        let sources: [String] = try field(root, "sources")
        let gaps: [String] = try field(root, "gaps")
        XCTAssertFalse(sources.isEmpty)
        XCTAssertFalse(gaps.isEmpty)
        for group in groups + ["preview"] {
            let rows: [JSONObject] = try field(root, group)
            XCTAssertFalse(rows.isEmpty, group)
            var names = Set<String>()
            for row in rows {
                let name: String = try field(row, "name")
                XCTAssertTrue(names.insert(name).inserted, "\(group): \(name) 重名")
                if group == "sourcePolicy" {
                    let steps: [JSONObject] = try field(row, "steps")
                    XCTAssertFalse(steps.isEmpty, name)
                    for step in steps {
                        let _: JSONObject = try field(step, "expect")
                    }
                } else {
                    let _: JSONObject = try field(row, "expect")
                }
            }
        }
        // 每个 golden 都进解码测试（fixture 与截图一一对应，共性第 15 条）
        let golden: JSONObject = try field(root, "goldenPages")
        let rows: [JSONObject] = try field(root, "pageDecode")
        // test-change(APP-11v)：旧判定向量原样保留；两张视觉页由 HomeVisualFixtureTests 经真实控制器解码。
        XCTAssertEqual(golden.count, 17)
        XCTAssertEqual(Set(golden.keys).subtracting(["main_v3", "guest_v3"]),
                       Set(rows.compactMap { $0["page"] as? String }))
    }

    func testVectors() throws {
        let root = try HomeVectors.root()
        var executed = 0
        for group in groups where group != "lkgScope" && group != "noticeCloseKey" {
            let rows: [JSONObject] = try field(root, group)
            for row in rows {
                let name: String = try field(row, "name")
                let label = "\(group).\(name)"
                do {
                    try run(group, row, root, label)
                    executed += 1
                } catch {
                    XCTFail("\(label): \(error)")
                }
            }
        }
        // 防「组名写错、一条都没跑」的假绿：除两组关系向量与 preview 外的行数（23+21+16+28+11+18+17+2+8+6+1）
        XCTAssertEqual(executed, 151)
    }

    func testScopeRelations() throws {
        try checkRelations(HomeVectors.root(), group: "lkgScope", key: "scope")
    }

    func testNoticeKeyRelations() throws {
        try checkRelations(HomeVectors.root(), group: "noticeCloseKey", key: "key")
    }

    // MARK: - 执行器

    private func run(_ group: String, _ row: JSONObject, _ root: JSONObject, _ label: String) throws {
        if group == "sourcePolicy" {
            try runSourcePolicy(row, label)
            return
        }
        let expected: JSONObject = try field(row, "expect")
        switch group {
        case "pageDecode": try runPageDecode(row, root, expected, label)
        case "notice": try runNotice(row, root, expected, label)
        case "action": try runAction(row, expected, label)
        case "exposure": try runExposure(row, expected, label)
        case "popup": try runPopup(row, expected, label)
        case "cardErrorDedupe": try runDedupe(row, expected, label)
        default: try runSimple(group, row, expected, label)
        }
    }

    /// 一行一个纯函数的组（门槛、清理口径、spm、推广标识）。
    private func runSimple(_ group: String, _ row: JSONObject, _ expected: JSONObject, _ label: String) throws {
        let actual: JSONObject
        switch group {
        case "minAppVersion":
            let absent = (row["minAppVersion"] as? String) == "absent"
            actual = ["keep": HomeSectionFilter.keep(
                minAppVersionJsonOrNull: absent ? nil : row["minAppVersion"], absent: absent,
                platform: try field(row, "platformRaw"), appVersion: try field(row, "appVersion")
            )]
        case "localDataClear":
            actual = ["clear": HomeLocalData.clearsOn(event: try field(row, "event"), item: try field(row, "item"))]
        case "spm":
            actual = ["spm": HomeSpm.of(sectionId: try field(row, "sectionId"), slot: try field(row, "slot"))]
        case "adLabel":
            let value = HomeAdLabel.of(
                sectionLabel: labelInput(row["sectionAdLabel"]), itemLabel: labelInput(row["itemAdLabel"])
            )
            actual = ["label": value.map { $0 as Any } ?? NSNull()]
        default:
            XCTFail("\(label): 未登记执行器")
            return
        }
        try match(actual, expected, label)
    }

    private func runPopup(_ row: JSONObject, _ expected: JSONObject, _ label: String) throws {
        let actual = PopupPolicy.decide(
            popupJson: try field(row, "popup"), level: try field(row, "levelRaw"),
            nowMs: try HomeVectors.millis(try field(row, "nowIso")), shownToday: try field(row, "shownToday"),
            coldStartShown: try field(row, "coldStartShown"), blockers: try field(row, "blockers"),
            imageLoaded: try field(row, "imageLoaded")
        )
        try match(actual, expected, label)
    }

    private func runDedupe(_ row: JSONObject, _ expected: JSONObject, _ label: String) throws {
        var dedupe = CardErrorDedupe()
        var sent: [Int] = []
        let events: [JSONObject] = try field(row, "events")
        for (index, event) in events.enumerated() where dedupe.shouldSend(
            pageVersion: try field(event, "pageVersion"), sectionId: try field(event, "sectionId"),
            reason: try field(event, "reasonRaw")
        ) {
            sent.append(index)
        }
        try match(["sentIndexes": sent], expected, label)
    }

    private func runSourcePolicy(_ row: JSONObject, _ label: String) throws {
        var policy = HomeSourcePolicy()
        let steps: [JSONObject] = try field(row, "steps")
        for (index, step) in steps.enumerated() {
            let actual = policy.on(event: try field(step, "event"), arg: step["arg"] as? JSONObject ?? [:])
            let expected: JSONObject = try field(step, "expect")
            let path = "\(label)[\(index)]"
            let actualActions: [String] = try field(actual, "actionsRaw")
            let expectedActions: [String] = try field(expected, "actionsRaw")
            // actionsRaw 无顺序规定，按多重集合精确比较
            XCTAssertEqual(actualActions.sorted(), expectedActions.sorted(), path)
            try match(actual, expected.filter { $0.key != "actionsRaw" }, path)
        }
    }

    private func runPageDecode(_ row: JSONObject, _ root: JSONObject, _ expected: JSONObject, _ label: String) throws {
        let page: JSONObject = if let key = row["page"] as? String {
            try HomeVectors.golden(key, root)
        } else {
            try field(row, "page")
        }
        let actual = HomeJson.decode(
            pageJson: page, platform: try field(row, "platformRaw"), appVersion: try field(row, "appVersion")
        )
        let kept: [JSONObject] = try field(actual, "kept")
        let popupId = actual["popupId"] as? String
        // G14：第二个合法 popup 是否留在 kept 未规定；只比较普通卡 + popupId 指定的那一个（popupId 单独精确断言）
        var projected: [JSONObject] = []
        for card in kept {
            let id: String = try field(card, "id")
            let type: String = try field(card, "type")
            if type != "popup" || id == popupId {
                projected.append(["id": id, "type": type])
            }
        }
        var observed = actual
        observed["kept"] = projected
        if let counts = expected["itemCounts"] as? JSONObject {
            var actualCounts: JSONObject = [:]
            for id in counts.keys {
                let card = try XCTUnwrap(kept.first { ($0["id"] as? String) == id }, "\(label): itemCounts 找不到 \(id)")
                let count: Int = try field(card, "itemCount")
                actualCounts[id] = count
            }
            observed["itemCounts"] = actualCounts
        }
        try match(observed, expected, label)
    }

    private func runNotice(_ row: JSONObject, _ root: JSONObject, _ expected: JSONObject, _ label: String) throws {
        let closed: [String] = try field(row, "closedKeys")
        let actualKeys = try closed.map { try mappedCloseKey($0, root) }
        let actual = NoticeFilter.visible(
            sectionId: try field(row, "sectionId"), itemsJson: try field(row, "items"), closedKeys: actualKeys,
            nowMs: try HomeVectors.millis(try field(row, "nowIso"))
        )
        var wanted = expected
        wanted.removeValue(forKey: "nextExpiryIso")
        if let iso = expected["nextExpiryIso"] as? String {
            wanted["nextExpiryMs"] = try HomeVectors.millis(iso)
        } else {
            wanted["nextExpiryMs"] = NSNull()
        }
        try match(actual, wanted, label)
    }

    private func runAction(_ row: JSONObject, _ expected: JSONObject, _ label: String) throws {
        let actual = RouteTargetCheck.decode(json: row["json"] as? JSONObject)
        let ok: Bool = try field(expected, "ok")
        XCTAssertEqual(actual != nil, ok, label)
        guard ok else { return }
        let target = try XCTUnwrap(actual, label)
        XCTAssertTrue(
            Set(target.keys).isSubset(of: ["route", "params"]), "\(label): 不得输出脚本或其他动作字段"
        )
        try match(target, expected.filter { $0.key != "ok" }, label, exact: expected["params"] != nil)
    }

    private func runExposure(_ row: JSONObject, _ expected: JSONObject, _ label: String) throws {
        var tracker = ExposureTracker(sectionId: try field(row, "sectionId"), slot: try field(row, "slot"))
        var fires: [Int64] = []
        var stay = 0
        let steps: [JSONObject] = try field(row, "steps")
        for step in steps {
            if let value = step["stay"] as? Int {
                stay = value
            }
            let time: Int = try field(step, "tMs")
            let ratio: Double = try field(step, "visibleRatio")
            if tracker.onVisible(tMs: Int64(time), ratio: ratio, stay: stay) {
                fires.append(Int64(time))
            }
        }
        try match(["fireAtMs": fires], expected, label)
    }
}
