import CryptoKit
import Foundation
import Generated
import XCTest

/// DS-02-iOS-1（brief §3.1–§3.2）：生成物与锁定令牌源逐值比对，补上 ContractConformanceTests 不比的段
/// （深色、组件整数 / 非整数、阴影浅深、行高、字重、焦点、命中区）。既有 ContractConformanceTests 不动（brief §4-2）。
/// 钉 0.5.1 与 couli f088f04 的断言：DSX-120 升 v0.6.0 时按 #24 换值（只换值，判据不放宽）。
final class DesignTokensFullConformanceTests: XCTestCase {
    private typealias JSONObject = [String: Any]

    /// 快照里的一层阴影（ShadowLayer 的成员构造器不公开，且 Release 下不能 @testable）。
    private struct Layer {
        let offsetX: Int
        let offsetY: Int
        let blur: Int
        let spread: Int
        let color: String
        let opacity: Double
    }

    /// D10-665 ①：iOS 令牌锁直接升到 v0.5.1（couli #276）。
    private static let lockedCommit = "f088f0473230d1e70232b8a246b92ef53d723929"
    /// `git -C couli show f088f04:design/tokens/design-tokens.json | shasum -a 256`（测试作者实测，交回 §2 附原始输出）。
    private static let lockedBlobSHA256 = "97d2bf83ada062959987f348bc695c63fabc4adb3647f03e5c0895e2548e491c"
    private static let lockedVersion = "0.5.1"

    // 先去掉文件名，再从 GeneratedTests 向上四级到仓库根。
    private var repoRoot: URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 {
            directory.deleteLastPathComponent()
        }
        return directory
    }

    private var snapshotURL: URL {
        repoRoot.appendingPathComponent("contracts/snapshot/design/design-tokens.json")
    }

    // MARK: - 锁与版本

    /// 计划验收 ②：DesignTokens.version ≥ 0.5.1，且等于快照 metadata.version。
    func testVersionIsLockedReleaseAndMatchesMetadata() throws {
        let metadata = try object(try root()["metadata"], "design.metadata")
        XCTAssertEqual(DesignTokens.version, try string(metadata["version"], "metadata.version"))
        XCTAssertEqual(DesignTokens.version, Self.lockedVersion, "令牌锁应在 v0.5.1（D10-665 ①）")
        let parts = DesignTokens.version.split(separator: ".").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 3, "版本号应是三段数字：\(DesignTokens.version)")
        XCTAssertFalse(parts.lexicographicallyPrecedes([0, 5, 1]), "DesignTokens.version 应 ≥ 0.5.1")
    }

    /// brief §3.2：contract.lock 的 design_tokens 指向 f088f04；快照与 lock files 哈希都等于该提交里 blob 的 sha256。
    func testLockPinsReleaseCommitAndSnapshotBlob() throws {
        let lockData = try Data(contentsOf: repoRoot.appendingPathComponent("contract.lock"))
        let lock = try XCTUnwrap(try JSONSerialization.jsonObject(with: lockData) as? JSONObject)
        let design = try object(lock["design_tokens"], "contract.lock.design_tokens")
        XCTAssertEqual(try string(design["commit"], "design_tokens.commit"), Self.lockedCommit)
        XCTAssertEqual(try string(design["repo"], "design_tokens.repo"), "../couli")
        XCTAssertEqual(try string(design["path"], "design_tokens.path"), "design/tokens/design-tokens.json")
        let files = try object(lock["files"], "contract.lock.files")
        XCTAssertEqual(try string(files["design/design-tokens.json"], "files[design]"), Self.lockedBlobSHA256)
        let digest = SHA256.hash(data: try Data(contentsOf: snapshotURL)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.lockedBlobSHA256, "快照必须逐字节等于锁定提交里的 blob，不得格式化（brief §5-4）")
    }

    // MARK: - 颜色

    /// colors 对 value、colorsDark 对 dark：键集合双向相等、值逐字相等（保留源大小写与 8 位 #RRGGBBAA，不换位）。
    func testColorsAndColorsDarkMatchEveryLeaf() throws {
        let leaves = try tokenLeaves(try object(try tokens()["color"], "tokens.color"), context: "tokens.color")
        var light: [String: String] = [:]
        var dark: [String: String] = [:]
        for (path, leaf) in leaves {
            light[path] = try string(leaf["value"], "tokens.color.\(path).value")
            dark[path] = try string(leaf["dark"], "tokens.color.\(path).dark（缺 dark 必须生成失败，不回落浅色）")
        }
        XCTAssertEqual(leaves.count, 49, "f088f04 共 49 个颜色叶子")
        assertTable(DesignTokens.colors, equals: light, context: "DesignTokens.colors")
        assertTable(DesignTokens.colorsDark, equals: dark, context: "DesignTokens.colorsDark")
        XCTAssertEqual(Set(DesignTokens.colors.keys), Set(DesignTokens.colorsDark.keys), "colors 与 colorsDark 键集合必须相同")

        // 点检（源：couli f088f04 design/tokens/design-tokens.json）：8 位色原样、浅深不同的遮罩、v0.5.1 新键。
        XCTAssertEqual(DesignTokens.colors["overlay.scrim"], "#28251F66")
        XCTAssertEqual(DesignTokens.colorsDark["overlay.scrim"], "#0000008C")
        XCTAssertEqual(DesignTokens.colors["overlay.on-image"], "#0000008C")
        XCTAssertEqual(DesignTokens.colorsDark["button.inverse.text"], "#A83B1F")
        XCTAssertEqual(DesignTokens.colorsDark["border.active"], "#F2EEE6")
        for (platform, hex) in [("taobao", "#D53D00"), ("tmall", "#EA0031"), ("jd", "#E02018"), ("pdd", "#EB0007")] {
            XCTAssertEqual(DesignTokens.colors["platform.tag.\(platform)"], hex, "platform.tag.\(platform)")
            XCTAssertEqual(DesignTokens.colorsDark["platform.tag.\(platform)"], hex, "platform.tag.\(platform) 深浅同值")
        }
    }

    // MARK: - 组件

    /// component（整数）+ componentNumber（type number）的键并集等于 tokens.component 全部叶子，且没有交集。
    func testComponentSegmentsPartitionEveryLeaf() throws {
        let leaves = try tokenLeaves(
            try object(try tokens()["component"], "tokens.component"),
            context: "tokens.component"
        )
        var integers: [String: Int] = [:]
        var numbers: [String: Double] = [:]
        for (path, leaf) in leaves {
            let value = try XCTUnwrap(leaf["value"] as? NSNumber, "tokens.component.\(path).value 应为数值")
            if leaf["type"] as? String == "number" {
                numbers[path] = value.doubleValue
            } else {
                XCTAssertEqual(value.doubleValue, value.doubleValue.rounded(), "\(path) 是 dimension，应为整数")
                integers[path] = value.intValue
            }
        }
        XCTAssertEqual(leaves.count, 23, "f088f04 共 23 个组件叶子")
        assertTable(DesignTokens.component, equals: integers, context: "DesignTokens.component")
        assertTable(DesignTokens.componentNumber, equals: numbers, context: "DesignTokens.componentNumber")
        XCTAssertTrue(
            Set(DesignTokens.component.keys).isDisjoint(with: DesignTokens.componentNumber.keys),
            "同一路径不能同时出现在 component 与 componentNumber"
        )
        XCTAssertEqual(
            Set(DesignTokens.component.keys).union(DesignTokens.componentNumber.keys), Set(leaves.map(\.path)),
            "两段键并集必须等于 tokens.component 全部叶子"
        )
        XCTAssertEqual(DesignTokens.componentNumber["checkbox.max-scale"], 1.5, "非整数 max-scale 原值保留")
        XCTAssertNil(DesignTokens.component["checkbox.max-scale"])
    }

    // MARK: - 阴影

    /// shadows / shadowsDark 逐层比 x / y / blur / spread / color / opacity；键集合相同，none 两段都是空数组。
    func testShadowsAndShadowsDarkMatchEveryLayer() throws {
        let shadow = try object(try tokens()["shadow"], "tokens.shadow")
        XCTAssertEqual(Set(DesignTokens.shadows.keys), Set(shadow.keys), "shadows 键集合")
        XCTAssertEqual(Set(DesignTokens.shadowsDark.keys), Set(shadow.keys), "shadowsDark 键集合与 shadows 相同")
        for key in shadow.keys.sorted() {
            let leaf = try object(shadow[key], "tokens.shadow.\(key)")
            let light = try layers(leaf["value"], "tokens.shadow.\(key).value")
            let dark = leaf["dark"] == nil ? light : try layers(leaf["dark"], "tokens.shadow.\(key).dark")
            if leaf["dark"] == nil {
                XCTAssertTrue(light.isEmpty, "只有空档位（none）可以没有 dark：\(key)")
            }
            assertLayers(DesignTokens.shadows[key], equals: light, context: "shadows.\(key)")
            assertLayers(DesignTokens.shadowsDark[key], equals: dark, context: "shadowsDark.\(key)")
        }
        XCTAssertEqual(DesignTokens.shadowsDark["none"], [])
        XCTAssertEqual(DesignTokens.shadowsDark["card"]?.first?.color, "#000000")
        XCTAssertEqual(DesignTokens.shadowsDark["floating"]?.first?.opacity, 0.45)
    }

    // MARK: - 其余标量段

    /// lineHeight、fontWeight、focus、interactionTarget、radius（含 v0.5.1 新增 tag / avatar）逐值。
    func testRemainingScalarGroupsMatch() throws {
        let tokens = try tokens()
        let font = try object(tokens["font"], "tokens.font")
        let interaction = try object(tokens["interaction"], "tokens.interaction")
        assertTable(DesignTokens.lineHeight, equals: try doubles(font["line-height"], "tokens.font.line-height"),
                    context: "DesignTokens.lineHeight")
        assertTable(DesignTokens.fontWeight, equals: try integers(font["weight"], "tokens.font.weight"),
                    context: "DesignTokens.fontWeight")
        assertTable(DesignTokens.focus, equals: try integers(tokens["focus"], "tokens.focus"),
                    context: "DesignTokens.focus")
        assertTable(
            DesignTokens.interactionTarget,
            equals: try integers(interaction["target"], "tokens.interaction.target"),
            context: "DesignTokens.interactionTarget"
        )
        assertTable(
            DesignTokens.radius,
            equals: try integers(tokens["radius"], "tokens.radius"),
            context: "DesignTokens.radius"
        )
        XCTAssertEqual(DesignTokens.radius["tag"], 4, "v0.5.1 radius.tag")
        XCTAssertEqual(DesignTokens.radius["avatar"], 10, "v0.5.1 radius.avatar")
    }

    // MARK: - 读快照

    private func root() throws -> JSONObject {
        let data = try Data(contentsOf: snapshotURL)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? JSONObject, "设计令牌快照应为对象")
    }

    private func tokens() throws -> JSONObject {
        try object(try root()["tokens"], "design.tokens")
    }

    /// 叶子（带 value 的对象）按点分路径展开，路径按字典序。
    private func tokenLeaves(_ node: JSONObject, context: String, prefix: String = "") throws
        -> [(path: String, leaf: JSONObject)] {
        if node["value"] != nil {
            XCTAssertFalse(prefix.isEmpty, "\(context) 叶子没有相对路径")
            return [(prefix, node)]
        }
        var result: [(path: String, leaf: JSONObject)] = []
        for key in node.keys.sorted() {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            result += try tokenLeaves(
                try object(node[key], "\(context).\(key)"),
                context: "\(context).\(key)",
                prefix: path
            )
        }
        return result
    }

    private func integers(_ node: Any?, _ context: String) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for (path, leaf) in try tokenLeaves(try object(node, context), context: context) {
            result[path] = try XCTUnwrap(leaf["value"] as? NSNumber, "\(context).\(path)").intValue
        }
        return result
    }

    private func doubles(_ node: Any?, _ context: String) throws -> [String: Double] {
        var result: [String: Double] = [:]
        for (path, leaf) in try tokenLeaves(try object(node, context), context: context) {
            result[path] = try XCTUnwrap(leaf["value"] as? NSNumber, "\(context).\(path)").doubleValue
        }
        return result
    }

    private func layers(_ node: Any?, _ context: String) throws -> [Layer] {
        let rows = try XCTUnwrap(node as? [JSONObject], "\(context) 应为数组")
        return try rows.enumerated().map { index, row in
            func number(_ key: String) throws -> NSNumber {
                try XCTUnwrap(row[key] as? NSNumber, "\(context)[\(index)].\(key)")
            }
            return Layer(
                offsetX: try number("x").intValue, offsetY: try number("y").intValue, blur: try number("blur").intValue,
                spread: try number("spread").intValue, color: try string(row["color"], "\(context)[\(index)].color"),
                opacity: try number("opacity").doubleValue
            )
        }
    }

    private func object(_ value: Any?, _ context: String) throws -> JSONObject {
        try XCTUnwrap(value as? JSONObject, "\(context) 应为对象")
    }

    private func string(_ value: Any?, _ context: String) throws -> String {
        try XCTUnwrap(value as? String, "\(context) 应为字符串")
    }

    private func assertTable<Value: Equatable>(
        _ actual: [String: Value], equals expected: [String: Value], context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let missing = Set(expected.keys).subtracting(actual.keys).sorted()
        let extra = Set(actual.keys).subtracting(expected.keys).sorted()
        XCTAssertTrue(missing.isEmpty, "\(context) 缺键：\(missing)", file: file, line: line)
        XCTAssertTrue(extra.isEmpty, "\(context) 多键：\(extra)", file: file, line: line)
        for key in expected.keys.sorted() where actual[key] != nil {
            XCTAssertEqual(actual[key], expected[key], "\(context)[\(key)]", file: file, line: line)
        }
    }

    private func assertLayers(
        _ actual: [DesignTokens.ShadowLayer]?, equals expected: [Layer], context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("\(context) 缺失", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.count, expected.count, "\(context) 层数", file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            XCTAssertEqual(pair.0.x, pair.1.offsetX, "\(context)[\(index)].x", file: file, line: line)
            XCTAssertEqual(pair.0.y, pair.1.offsetY, "\(context)[\(index)].y", file: file, line: line)
            XCTAssertEqual(pair.0.blur, pair.1.blur, "\(context)[\(index)].blur", file: file, line: line)
            XCTAssertEqual(pair.0.spread, pair.1.spread, "\(context)[\(index)].spread", file: file, line: line)
            XCTAssertEqual(pair.0.color, pair.1.color, "\(context)[\(index)].color", file: file, line: line)
            XCTAssertEqual(pair.0.opacity, pair.1.opacity, accuracy: 1e-12, "\(context)[\(index)].opacity",
                           file: file, line: line)
        }
    }
}
