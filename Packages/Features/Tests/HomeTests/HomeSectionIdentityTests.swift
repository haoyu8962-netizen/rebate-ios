import Foundation
@testable import Home
import HomeCore
import SwiftUI
import XCTest

/// K01：检查真实渲染器交给 SwiftUI 的区段身份（显式 .id 或 ForEach 的区段键），不依赖卡片布局或漏画。
/// 不重写身份公式，也不只检查 Core 的 section.key；从 HomeSduiScreen.body 的 ForEach 调用实际行构造闭包。
@MainActor
final class HomeSectionIdentityTests: XCTestCase {
    func testSectionViewIDsAreUniqueAndFollowSectionKeysWithinOneRender() async throws {
        let suite = "home-section-identity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pages = try SnapshotKit.goldenPages()
        let page = try XCTUnwrap(pages["banner"] as? [String: Any])
        let banner = try XCTUnwrap((page["sections"] as? [[String: Any]])?.first)
        // 相同卡片类型、相同内容，只有服务端区段 id 不同，不能靠卡片类型或内容替代区段键。
        let sections = ["identity_a", "identity_b", "identity_c"].map { id in
            var section = banner
            section["id"] = id
            return section
        }
        let deps = SnapshotKit.deps(
            page: ["page_key": "home", "version": 1, "sections": sections], defaults: defaults
        )
        let controller = HomeController(
            identity: HomeIdentity(env: "test", level: .guest, userId: nil, loginEpoch: nil), deps: deps
        )
        controller.start()
        await controller.whenIdle()
        XCTAssertEqual(controller.state.source, .network)
        let keys = controller.state.sections.map(\.key)
        XCTAssertEqual(keys.count, 3, "前提：三个区段都进入同一次渲染")
        XCTAssertEqual(Set(keys).count, 3, "前提：三个区段键不同")
        let render = controller.state.render
        let rows = try XCTUnwrap(
            HomeViewIdentityProbe.rows(in: HomeSduiScreen(controller: controller).body),
            "没有找到真实渲染器的行 ForEach；探针失效必须判失败，不能跳过"
        )
        XCTAssertEqual(rows.identityRowKeys, controller.state.rowKeys)
        let keyPath = try XCTUnwrap(rows.identityKeyPath, "无法读取 ForEach 实际 id keyPath，不能推定是区段键")
        XCTAssertEqual(keyPath, \String.self, "ForEach 必须实际以区段键自身提供身份")
        let rowIDs = rows.identityRowKeys.map { $0[keyPath: keyPath] }
        XCTAssertEqual(rowIDs, controller.state.rowKeys, "ForEach 的实际身份数据必须逐项等于区段键")
        XCTAssertEqual(Set(rowIDs).count, rowIDs.count, "同一 render 内 ForEach 的全部行身份必须唯一")
        let ids = try keys.map { key in
            try sectionID(in: rows.identityRow(key), inheritedID: key[keyPath: keyPath])
        }
        XCTAssertEqual(Set(ids).count, keys.count, "K01：同一次渲染的不同区段不可共用一个 View id")
        // 同一构造闭包按反向顺序重复求值：同一个键身份稳定，换键身份不同，不接受随机 id / 递增计数。
        for index in keys.indices.reversed() {
            let repeated = try sectionID(
                in: rows.identityRow(keys[index]), inheritedID: keys[index][keyPath: keyPath]
            )
            XCTAssertEqual(repeated, ids[index], "同一渲染、同一区段键的 View id 必须稳定")
            for other in keys.indices where other != index {
                XCTAssertNotEqual(repeated, ids[other], "区段键变化时 View id 必须变化")
            }
        }
        XCTAssertEqual(controller.state.render, render, "前提：全部身份比较都在同一次渲染中")
    }

    private func sectionID(in row: Any, inheritedID: String) throws -> AnyHashable {
        let identity = HomeViewIdentityProbe.sectionIdentity(in: row, sectionType: HomeSectionView.self)
        return try XCTUnwrap(
            identity.resolvedID(inherited: AnyHashable(inheritedID)),
            "无法识别区段身份：\(identity)；只有确认无显式 id 才允许采用已验证的 ForEach 身份"
        )
    }

    /// 探针自身的三态自检，不代替真实渲染器用例：独立显式 id / 共用显式 id / 无显式 id。
    func testProbeDistinguishesIndependentSharedAndInheritedIDs() throws {
        let keys = ["a", "b", "c"]
        for mode in 0..<3 {
            let rows = ForEach(keys, id: \.self) { key in
                if mode == 0 {
                    Text(key).id(key)
                } else if mode == 1 {
                    Text(key).id(7)
                } else {
                    Text(key)
                }
            }
            let keyPath = try XCTUnwrap(rows.identityKeyPath)
            XCTAssertEqual(keyPath, \String.self)
            let rowIDs = rows.identityRowKeys.map { $0[keyPath: keyPath] }
            XCTAssertEqual(rowIDs, keys)
            XCTAssertEqual(Set(rowIDs).count, keys.count)
            let ids = try keys.map { key in
                let identity = HomeViewIdentityProbe.sectionIdentity(in: rows.content(key), sectionType: Text.self)
                switch mode {
                case 0: XCTAssertEqual(identity, .explicit(AnyHashable(key)))
                case 1: XCTAssertEqual(identity, .explicit(AnyHashable(7)))
                default: XCTAssertEqual(identity, .inherited)
                }
                return try XCTUnwrap(identity.resolvedID(inherited: AnyHashable(key[keyPath: keyPath])))
            }
            XCTAssertEqual(Set(ids).count, mode == 1 ? 1 : 3, "只有共用显式 id 应违反唯一性")
        }
    }

    func testProbeNeverTreatsUnknownWrappersAsInheritedIdentity() {
        // 不能因为递归找到了 Text，就假定中间不认识的包装没有改变身份。
        let identity = HomeViewIdentityProbe.sectionIdentity(in: AnyView(Text("a")), sectionType: Text.self)
        guard case .unrecognized = identity else { return XCTFail("未知包装必须明确报告无法识别") }
        XCTAssertNil(identity.resolvedID(inherited: AnyHashable("a")))
    }
}

/// 只在测试 target 中擦除 ForEach 的 Content 类型；调用的是生产渲染器创建的 content 闭包。
@MainActor
private protocol HomeIdentityRows {
    var identityRowKeys: [String] { get }
    var identityKeyPath: KeyPath<String, String>? { get }
    func identityRow(_ key: String) -> Any
}

extension ForEach: HomeIdentityRows where Data == [String], ID == String {
    fileprivate var identityRowKeys: [String] {
        data
    }

    /// 读取 ForEach 实际身份生成器，而非只根据 data 是字符串就假定 id 为 \.self。
    fileprivate var identityKeyPath: KeyPath<String, String>? {
        let mirror = Mirror(reflecting: self)
        guard let generator = mirror.children.first(where: { $0.label == "idGenerator" })?.value else { return nil }
        let fields = Array(Mirror(reflecting: generator).children)
        guard fields.count == 1, fields[0].label == "keyPath" else { return nil }
        return fields[0].value as? KeyPath<String, String>
    }

    fileprivate func identityRow(_ key: String) -> Any {
        content(key)
    }
}

/// SwiftUI 没有公开读取 .id 的接口，测试用 Mirror 读取包装值。
/// 明确区分显式身份、已确认没有显式身份、无法识别；不展开卡片 body。
/// 只穿过已知的条件分支包装，未知类型 / 字段 / 分支一律报无法识别，不按“没有 id”放行。
@MainActor
private enum HomeViewIdentityProbe {
    static func rows(in value: Any, depth: Int = 0) -> (any HomeIdentityRows)? {
        if let rows = value as? any HomeIdentityRows {
            return rows
        }
        guard depth < 32 else { return nil }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != .class else { return nil }
        for child in mirror.children {
            if let rows = rows(in: child.value, depth: depth + 1) {
                return rows
            }
        }
        return nil
    }

    enum SectionIdentity: Equatable {
        case explicit(AnyHashable)
        case inherited
        case unrecognized(String)

        func resolvedID(inherited id: AnyHashable) -> AnyHashable? {
            switch self {
            case let .explicit(value): value
            case .inherited: id
            case .unrecognized: nil
            }
        }
    }

    static func sectionIdentity<Section: View>(
        in value: Any, sectionType: Section.Type, depth: Int = 0
    ) -> SectionIdentity {
        guard depth < 32 else { return .unrecognized("包装深度超限") }
        if value is Section {
            return .inherited
        }
        let mirror = Mirror(reflecting: value)
        let type = String(describing: Swift.type(of: value))
        if type.hasPrefix("IDView<") {
            let fields = Array(mirror.children)
            guard fields.count == 2,
                  let content = fields.first(where: { $0.label == "content" })?.value,
                  let id = fields.first(where: { $0.label == "id" })?.value as? AnyHashable
            else { return .unrecognized("IDView 字段无法识别") }
            let child = sectionIdentity(in: content, sectionType: sectionType, depth: depth + 1)
            guard child == .inherited else { return .unrecognized("显式 id 内部包装无法确认：\(child)") }
            return .explicit(id)
        }
        if type.hasPrefix("_ConditionalContent<") {
            let fields = Array(mirror.children)
            guard fields.count == 1, fields[0].label == "storage" else {
                return .unrecognized("条件包装的 storage 无法识别")
            }
            let storage = Mirror(reflecting: fields[0].value)
            let branches = Array(storage.children)
            guard storage.displayStyle == .enum, branches.count == 1,
                  branches[0].label == "trueContent" || branches[0].label == "falseContent"
            else { return .unrecognized("条件包装的活动分支无法识别") }
            return sectionIdentity(in: branches[0].value, sectionType: sectionType, depth: depth + 1)
        }
        return .unrecognized("未知区段包装：\(type)")
    }
}
