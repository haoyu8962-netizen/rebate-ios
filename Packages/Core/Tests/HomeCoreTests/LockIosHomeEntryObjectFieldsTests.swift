import Foundation
@testable import HomeCore
import XCTest

/// 金刚区条目的 icon / image / badge 对象字段（FU-IOS-HOME-ENTRY-OBJECT-FIELDS；契约 home-schema.json 6c97062 的
/// icon_grid_item、icon_asset、badge；D10-2998 (a)(b)、D10-3054、D10-3069、D10-3076 (1)、D10-3092）。
/// 只经生产 HomeController 渲染出的 HomeItemUi（title / image / badge / 条数）断言，不引用实现方新增的符号。
/// 「丢这一条」都带一条可用 icon_asset 的对照条与一条普通条，断言剩下的正是这两条；
/// 「只丢徽标」都带一条合法 text 徽标的对照条，断言对照条显示、其余条目都还在且无徽标。
@MainActor
final class LockIosHomeEntryObjectFieldsTests: HomeRigTestCase {
    private typealias JSONObject = [String: Any]

    private func render(_ entries: [JSONObject]) async -> [HomeItemUi] {
        let controller = await show(EntryKit.page(entries))
        return controller.state.section("icons")?.items ?? []
    }

    /// 被测条 + 对照条（icon_asset）+ 普通条；被测条应整条丢掉。
    private func assertDropped(_ name: String, _ fields: JSONObject, line: UInt = #line) async {
        let items = await render([
            EntryKit.entry("对照", ["icon": EntryKit.asset()]), EntryKit.entry("被测", fields), EntryKit.entry("普通"),
        ])
        XCTAssertEqual(items.compactMap(\.title), ["对照", "普通"], "\(name)：应只丢这一条", line: line)
        XCTAssertEqual(items.first?.image, EntryKit.png, "\(name)：对照条取 icon_asset 的 url", line: line)
    }

    /// 被测条 + 普通条；被测条保留，图片为 expected。
    private func assertKept(_ name: String, _ fields: JSONObject, image expected: String, line: UInt = #line) async {
        let items = await render([EntryKit.entry("被测", fields), EntryKit.entry("普通")])
        XCTAssertEqual(items.compactMap(\.title), ["被测", "普通"], "\(name)：条目应保留", line: line)
        XCTAssertEqual(items.first?.image, expected, "\(name)：图片地址", line: line)
    }

    /// 每个徽标值一条（标题 格0、格1…）+ 对照条（合法 text 徽标）；返回 [标题: 徽标]，并断言条目一条不少。
    private func renderBadges(_ values: [Any], line: UInt = #line) async -> [String: String?] {
        var entries = values.enumerated().map { index, badge in
            EntryKit.entry("格\(index)", ["icon": EntryKit.plain, "badge": badge])
        }
        let control: JSONObject = ["kind": "text", "text": "新"]
        entries.append(EntryKit.entry("对照", ["icon": EntryKit.plain, "badge": control]))
        let items = await render(entries)
        let titles = entries.compactMap { $0["title"] as? String }
        XCTAssertEqual(items.compactMap(\.title), titles, "徽标不合法只丢徽标、条目都在", line: line)
        XCTAssertEqual(items.last?.badge, "新", "对照条：合法 text 徽标显示 text", line: line)
        var result: [String: String?] = [:]
        for item in items {
            result[item.title ?? ""] = .some(item.badge)
        }
        return result
    }

    private func assertNoBadge(_ name: String, _ values: [Any], line: UInt = #line) async {
        let shown = await renderBadges(values, line: line)
        for index in values.indices {
            XCTAssertEqual(shown["格\(index)"], .some(nil), "\(name)：第 \(index) 个徽标 \(values[index]) 应只丢徽标", line: line)
        }
    }

    // MARK: - icon 对象（icon_asset）

    /// 合 icon_asset 的 png 对象取 url（目录可有可无、可多层；url 恰好 2048 字符仍合法；首页不做摘要校验）。
    func testIconAssetWithPngUrlIsUsedAsImage() async {
        let urls = [
            EntryKit.png, "https://img.example.com/\(EntryKit.hex).png",
            "https://img.example.com/a/b/c/\(EntryKit.hex).png", EntryKit.longUrl(2048),
        ]
        XCTAssertEqual(EntryKit.longUrl(2048).count, 2048, "前提：夹具长度")
        for url in urls {
            await assertKept("icon_asset \(url.prefix(40))…", ["icon": EntryKit.asset(url)], image: url)
        }
    }

    /// .svg（合 pattern）只丢这一条（D10-3092 / D10-3076 (1)）。
    func testIconAssetWithSvgUrlDropsTheEntry() async {
        await assertDropped("svg", ["icon": EntryKit.asset("https://img.example.com/home/\(EntryKit.hex).svg")])
    }

    /// 不合 icon_asset 的对象（多余键、缺键、sha256 大写 / 长度不对 / 非字符串、url 非 https / 文件名不是 64 位小写 hex /
    /// 扩展名不对 / 带查询 / 超 2048 / 非字符串、空对象）→ 丢这一条。
    func testInvalidIconAssetDropsTheEntry() async {
        let hex = EntryKit.hex
        let base = "https://img.example.com/home/"
        let cases: [(String, Any)] = [
            ("多余键", ["url": EntryKit.png, "sha256": hex, "size": 1] as JSONObject),
            ("缺 sha256", ["url": EntryKit.png] as JSONObject),
            ("缺 url", ["sha256": hex] as JSONObject),
            ("sha256 大写", EntryKit.asset(sha: hex.uppercased())),
            ("sha256 63 位", EntryKit.asset(sha: String(hex.dropLast()))),
            ("sha256 65 位", EntryKit.asset(sha: hex + "0")),
            ("sha256 非字符串", EntryKit.asset(sha: 1)),
            ("url http", EntryKit.asset("http://img.example.com/home/\(hex).png")),
            ("文件名大写 hex", EntryKit.asset(base + hex.uppercased() + ".png")),
            ("文件名 63 位", EntryKit.asset(base + String(hex.dropLast()) + ".png")),
            ("扩展名 jpg", EntryKit.asset(base + hex + ".jpg")),
            ("带查询", EntryKit.asset(EntryKit.png + "?v=1")),
            ("url 2049 字符", EntryKit.asset(EntryKit.longUrl(2049))),
            ("url 非字符串", ["url": 1, "sha256": hex] as JSONObject),
            ("空对象", [:] as JSONObject),
            ("空串", ""),
            ("数组", [EntryKit.png]),
        ]
        XCTAssertEqual(EntryKit.longUrl(2049).count, 2049, "前提：夹具长度")
        for (name, icon) in cases {
            await assertDropped(name, ["icon": icon])
        }
    }

    // MARK: - image 字段（icon 缺或为 null 时才取；只认 https，D10-3054）

    /// 只给 image（https）→ 取 image；"icon": null + 合法 image → 取 image。
    func testImageIsUsedWhenIconIsAbsentOrNull() async {
        let image = "https://img.example.com/only-image.png"
        await assertKept("只给 image", ["image": image], image: image)
        await assertKept("icon 为 null", ["icon": NSNull(), "image": image], image: image)
    }

    /// image 写成 builtin: / http / 非字符串、icon 与 image 都没有、icon 为 null 且无 image → 丢这一条。
    func testInvalidOrMissingImageWithoutIconDropsTheEntry() async {
        await assertDropped("image builtin:", ["image": "builtin:platform.taobao"])
        await assertDropped("icon null + image builtin:", ["icon": NSNull(), "image": "builtin:guide"])
        await assertDropped("image http", ["image": "http://img.example.com/x.png"])
        await assertDropped("image 非字符串", ["image": 1])
        await assertDropped("icon 与 image 都没有", [:])
        await assertDropped("icon null、无 image", ["icon": NSNull()])
    }

    /// icon 给了但不合法、image 合法 → 丢这一条、不回落 image（D10-3069）。
    func testInvalidIconDoesNotFallBackToValidImage() async {
        let image = "https://img.example.com/fallback.png"
        await assertDropped("坏 icon 对象", ["icon": EntryKit.asset(sha: "x"), "image": image])
        await assertDropped("svg icon", [
            "icon": EntryKit.asset("https://img.example.com/home/\(EntryKit.hex).svg"), "image": image,
        ])
        await assertDropped("http icon", ["icon": "http://img.example.com/i.png", "image": image])
        await assertDropped("未知 builtin icon", ["icon": "builtin:unknown", "image": image])
        await assertDropped("icon 数字", ["icon": 7, "image": image])
    }

    /// 可用 icon_asset + 不合法 image → 保留、用 icon；两者都合法以 icon 为准（D10-3054）。
    func testUsableIconAssetWinsOverImage() async {
        let png = EntryKit.png
        await assertKept("asset + builtin image", ["icon": EntryKit.asset(), "image": "builtin:guide"], image: png)
        await assertKept("asset + 数字 image", ["icon": EntryKit.asset(), "image": 3], image: png)
        await assertKept("asset + 合法 image", [
            "icon": EntryKit.asset(), "image": "https://img.example.com/other.png",
        ], image: EntryKit.png)
    }

    /// 可用 icon 字符串 + 不合法 / 合法 image → 保留、用 icon（现有口径，image 不参与）。
    func testUsableIconStringWinsOverImage() async {
        let icon = EntryKit.plain
        let http = "http://img.example.com/x.png"
        await assertKept("https icon + builtin image", ["icon": icon, "image": "builtin:guide"], image: icon)
        await assertKept("https icon + http image", ["icon": icon, "image": http], image: icon)
        await assertKept("builtin icon + 合法 image", [
            "icon": "builtin:platform.jd", "image": "https://img.example.com/other.png",
        ], image: "builtin:platform.jd")
    }

    /// icon 字符串照旧：builtin 白名单与 https 保留；白名单外的 builtin、http 丢这一条。
    func testIconStringKeepsExistingRules() async {
        await assertKept("builtin 白名单", ["icon": "builtin:category.fresh"], image: "builtin:category.fresh")
        await assertKept("https", ["icon": "https://img.example.com/s.png"], image: "https://img.example.com/s.png")
        await assertDropped("白名单外 builtin", ["icon": "builtin:category.unknown"])
        await assertDropped("http", ["icon": "http://img.example.com/s.png"])
    }

    // MARK: - badge 对象（D10-2998 (a)(b)）

    /// kind = text 显示 text：1–2 个 Unicode 码点（emoji 代理对算 1 个；肤色修饰、国旗是 1 个字形 2 个码点）。
    func testTextBadgeShowsItsText() async {
        let texts = ["新", "新品", "😀", "😀😀", "👍🏻", "🇨🇳"]
        let shown = await renderBadges(texts.map { ["kind": "text", "text": $0] as JSONObject })
        for (index, text) in texts.enumerated() {
            XCTAssertEqual(shown["格\(index)"], .some(text), "text 徽标 \(text) 应显示")
        }
    }

    /// text 3 码点（含 1 个字形 5 码点的家庭 emoji）/ 空串 / 缺 text / text 为 null / 非字符串 → 只丢徽标。
    func testInvalidTextBadgeDropsOnlyTheBadge() async {
        await assertNoBadge("坏 text", [
            ["kind": "text", "text": "三个字"], ["kind": "text", "text": "😀😀😀"], ["kind": "text", "text": "👨‍👩‍👧"],
            ["kind": "text", "text": ""], ["kind": "text"], ["kind": "text", "text": NSNull()],
            ["kind": "text", "text": 12], ["kind": "text", "text": ["新"]],
        ] as [JSONObject])
    }

    /// none、dot → 条目保留、不显示徽标（dot 只解析不显示，FU-IOS-HOME-BADGE-DOT 另登）。
    func testNoneAndDotBadgesShowNothing() async {
        await assertNoBadge("none / dot", [["kind": "none"], ["kind": "dot"]] as [JSONObject])
    }

    /// none 或 dot 带 text（含 "text": null）→ 不合法、只丢徽标。
    func testNoneOrDotWithTextIsInvalid() async {
        await assertNoBadge("none / dot 带 text", [
            ["kind": "none", "text": "新"], ["kind": "dot", "text": "新"],
            ["kind": "none", "text": NSNull()], ["kind": "dot", "text": NSNull()],
        ] as [JSONObject])
    }

    /// 多余键、缺 kind、kind 不在枚举（含大小写不同、非字符串、null）→ 只丢徽标。
    func testMalformedBadgeObjectDropsOnlyTheBadge() async {
        await assertNoBadge("坏对象", [
            ["kind": "text", "text": "新", "color": "red"], ["text": "新"], ["kind": "red", "text": "新"],
            ["kind": "TEXT", "text": "新"], ["kind": 1, "text": "新"], ["kind": NSNull(), "text": "新"], [:],
        ] as [JSONObject])
    }

    /// 旧的字符串徽标契约已不允许 → 只丢徽标、条目保留。
    func testLegacyStringBadgeDropsOnlyTheBadge() async {
        await assertNoBadge("字符串徽标", ["测试", "新"])
    }

    /// 徽标是数字 / 数组 / 布尔 / null → 只丢徽标。
    func testNonObjectBadgeDropsOnlyTheBadge() async {
        await assertNoBadge("非对象徽标", [1, ["新"], true, NSNull()] as [Any])
    }
}

/// 本文件的页面夹具（金刚区一张卡 id = icons、4 列）。
private enum EntryKit {
    typealias JSONObject = [String: Any]

    /// 64 位小写 hex。
    static let hex = String(repeating: "0123456789abcdef", count: 4)
    static let png = "https://img.example.com/home/\(hex).png"
    static let plain = "https://img.example.com/plain.png"

    static func asset(_ url: String = png, sha: Any = hex) -> JSONObject {
        ["url": url, "sha256": sha]
    }

    /// 合 pattern 的 png 地址，总长 length 个 ASCII 字符（中间用 a/ 目录填充）。
    static func longUrl(_ length: Int) -> String {
        let prefix = "https://img.example.com/"
        let filler = length - prefix.count - hex.count - 4
        return prefix + (filler % 2 == 1 ? "b" : "") + String(repeating: "a/", count: filler / 2) + hex + ".png"
    }

    /// 条目：title、action 固定，其余字段照给（NSNull 原样写成 JSON null；不给 icon 就没有 icon 键）。
    static func entry(_ title: String, _ fields: JSONObject = ["icon": plain]) -> JSONObject {
        var json = fields
        json["title"] = title
        json["action"] = ["route": "Help"]
        return json
    }

    static func page(_ entries: [JSONObject]) -> JSONObject {
        HomeKit.page(version: 70, [[
            "id": "icons", "type": "icon_grid", "version": 1, "props": ["columns": 4],
            "data_source": ["kind": "static", "items": entries],
        ]])
    }
}
