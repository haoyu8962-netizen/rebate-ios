import XCTest

/// APP-06v-a 测试 v2：评审 r1 S2-4 的读屏缺口（头图加载失败、加载骨架）。真实 App + 注入卡（ProductVisualUITestSupport）。
@MainActor
final class ProductVisualReviewR1UITests: XCTestCase, ProductVisualUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// S2-4-2：图片 404 时仍是一项图片角色「商品图片，{标题}」，阶段标识 failed（假服务对 `…/broken.png` 回 404，§2.2）。
    func testFailedHeroIsStillOneNamedImage() throws {
        let app = try launchProduct(visualCard("tb_coupon_range", overrides: [
            "image": "https://img.example.test/product-v/broken.png",
        ]))
        let failed = node(app, "product.image.failed")
        XCTAssertTrue(failed.waitForExistence(timeout: 10), "失败时阶段标识 product.image.failed")
        XCTAssertFalse(node(app, "product.image.loaded").exists, "失败不能报成已加载")
        XCTAssertEqual(failed.elementType, .image, "失败占位仍是图片角色")
        XCTAssertEqual(failed.label, "商品图片，全脂纯牛奶 250ml × 24 盒 整箱装 早餐奶 学生奶", "读名不变")
        let items = try readingOrder(app)
        XCTAssertEqual(items.filter { $0.label.contains("商品图片，") }.count, 1, "头图只读一次")
    }

    /// S2-4-3：加载中详情页容器内只有一项读屏「加载中」；骨架不进读屏；没有可读的金额或商品文字。
    ///
    /// v3：只统计详情页容器（`product.loading` 的子树，加上框完全落在它里面的叠加项）内的读屏项。App 根节点（Debug 下读名
    /// 「凑狸调试」）等祖先节点的框包住整页、不在容器内，不再被算进来；判据不变：容器内恰好一项「加载中」，别的一项都不能有。
    func testLoadingSkeletonHasExactlyOneLoadingItem() throws {
        let app = try launchProduct(visualCard("tb_coupon_range"), hold: true)
        Thread.sleep(forTimeInterval: 0.8)
        let root = try app.snapshot()
        let items = try readingOrder(app)
        keep(items, "product-loading-tree")
        // 加载容器可能是嵌套的同标识节点（外层包装 + 带读名的那一层），全部取来，框取并集
        let containers = Self.all("product.loading", in: root)
        XCTAssertFalse(containers.isEmpty, "缺详情页加载容器 product.loading")
        let frame = containers.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        XCTAssertFalse(frame.isNull || frame.isEmpty, "加载容器有实际框")
        var inside: [ProductVisualA11yItem] = []
        for item in containers.flatMap(Self.labeled) + Self.labeled(root)
            where frame.insetBy(dx: -0.5, dy: -0.5).contains(item.frame) || containers.contains(where: {
                Self.labeled($0).contains { $0.label == item.label && $0.frame == item.frame }
            }) {
            if !inside.contains(where: { $0.label == item.label && $0.frame == item.frame && $0.id == item.id }) {
                inside.append(item)
            }
        }
        XCTAssertEqual(inside.filter { $0.label == "加载中" }.count, 1,
                       "详情页容器内恰好一项「加载中」：\(inside.map(\.label))")
        XCTAssertTrue(inside.allSatisfy { $0.label == "加载中" },
                      "详情页容器内除「加载中」外不应有别的读屏项（骨架不进读屏）：\(inside.map(\.label))")
        XCTAssertFalse(items.contains { $0.label.contains("¥") || $0.label.contains("全脂纯牛奶") },
                       "加载中整页不读金额、不读商品名")
    }

    private static func all(_ id: String, in node: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        (node.identifier == id ? [node] : []) + node.children.flatMap { all(id, in: $0) }
    }

    /// 子树里有读名的节点（含自身）。
    private static func labeled(_ node: XCUIElementSnapshot) -> [ProductVisualA11yItem] {
        var result: [ProductVisualA11yItem] = []
        func walk(_ element: XCUIElementSnapshot) {
            if !element.label.isEmpty {
                result.append(ProductVisualA11yItem(type: element.elementType, id: element.identifier,
                                                    label: element.label, frame: element.frame))
            }
            element.children.forEach(walk)
        }
        walk(node)
        return result
    }
}
