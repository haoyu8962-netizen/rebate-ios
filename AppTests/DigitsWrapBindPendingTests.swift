@testable import Couli
import DesignSystem
import Foundation
@testable import Login
import Router
import Session
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-NUM-WRAP / D10-1249 ④（tests v2 补）：绑手机页「换号待确认」卡里的新号码四档下不在数字中间断。
/// 真实 App 组合（MeAppFixture + 本地假服务）出绑定手机号页（同 BindPhoneLayoutTests 链路），把生产执行器的待确认卡
/// 置成脱敏新号码，挂进临时窗口（`BindPhoneLayoutCanvas`，安全区同截图；该宿主固定浅色，四档都是浅色）。
/// 页面没有测量钩子，判据读无障碍树里的元素框 + 整窗像素（按文字颜色取墨迹）：
/// - 摘要行「提交的手机号」：值是主文字色、标签是次文字色，行框内主文字色墨迹必须恰一行（号码没被拆到两行），
///   墨迹高够一个数字；不在横滑条里时可见墨迹宽 ≥ 号码整段宽的 85%（整段可见），在横滑条里时横滑条竖向包住墨迹、墨迹铺到可见右缘。
/// - 警示条说明句：页面文案经 `LoginTexts` 下发；这里把说明句换成只有号码、标题换成空（`PhoneOnlyTexts`），
///   使说明句那一列的警示色墨迹就是号码本身，再按同一判据核（真文案时号码前后的中文只会让号码整段换行，断不断只取决于号码宽与列宽）。
@MainActor
final class DigitsWrapBindPendingTests: MeTestCase {
    private static let masked = "138****5678"

    /// 说明句只剩号码、标题为空，其余文案照生产。
    private struct PhoneOnlyTexts: LoginTexts {
        let base: LoginTexts

        func text(_ key: String) -> String {
            key == BindPhoneKeys.pendingTitle ? "" : base.text(key)
        }

        func format(_ key: String, _ vars: [String: String]) -> String {
            key == BindPhoneKeys.pendingDesc ? vars["phone"] ?? "" : base.format(key, vars)
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaultsPendingBackend().delete()
        script.ok("POST /v1/auth/oauth-attempts", DigitsBindScript.attempt)
        script.ok("POST /v1/auth/login/wechat", DigitsBindScript.login)
        script.install()
    }

    override func tearDown() {
        UserDefaultsPendingBackend().delete()
        super.tearDown()
    }

    func testPendingNewPhoneNeverBreaksAllTiers() async throws {
        try enableDigitsAccessibilityTree()
        let fixture = make(account: nil)
        let entry = try await digitsBindEntry(fixture)
        let texts = PhoneOnlyTexts(base: fixture.login.texts)
        let phoneLabel = fixture.login.texts.text(BindPhoneKeys.pendingPhoneLabel)
        XCTAssertFalse(phoneLabel.isEmpty, "前提：摘要行标签有文案")
        for judgeTier in DigitsRunJudge.tiers {
            let tier = BindPhoneLayoutCanvas.Tier(name: judgeTier.name + "（浅）", width: judgeTier.width,
                                                  size: judgeTier.size)
            let canvas = BindPhoneLayoutCanvas(AnyView(BindPhoneScreen(entry: entry, texts: texts)), tier: tier)
            defer { canvas.close() }
            await canvas.pump()
            // 生产执行器按本机未决记录异步重读待确认卡（没有记录会清掉）：置卡后等页面真的画出号码，被清就重置
            var nodes: [Node] = []
            for _ in 0..<10 {
                if entry.controller.pending == nil {
                    entry.controller.pending = BindPendingCard(key: "pending-key-1", maskedPhone: Self.masked,
                                                               submittedAtMillis: 1_760_236_200_000)
                }
                await canvas.pump()
                nodes = Self.labelled(canvas.window)
                if entry.controller.pending != nil, nodes.contains(where: { $0.label.contains(Self.masked) }) {
                    break
                }
            }
            guard nodes.contains(where: { $0.label.contains(Self.masked) }) else {
                XCTFail("[\(tier)] 页面没有画出待确认卡（pending=\(String(describing: entry.controller.pending))；"
                    + "读屏元素 \(nodes.prefix(40).map { $0.id.isEmpty ? $0.label : $0.id })）")
                continue
            }
            var problems: [String] = []
            // 摘要行：组合元素的读屏文字含标签与号码；值是主文字色
            let row = await Self.shoot(canvas) { $0.label.contains(phoneLabel) && $0.label.contains(Self.masked) }
            if let (node, pixels) = row {
                problems += Self.lineProblems(
                    pixels,
                    region: node.frame,
                    ink: CouliColor.textPrimary,
                    on: canvas,
                    name: "[\(tier)] 摘要行新号码"
                )
            } else {
                problems.append("[\(tier)] 无障碍树里找不到摘要行（标签「\(phoneLabel)」+ 号码）")
            }
            problems += await Self.barProblems(canvas, phoneLabel: phoneLabel)
            XCTAssertEqual(problems, [], "换号待确认卡 \(tier)")
        }
    }

    /// 警示条：位置 = 卡片顶到摘要块顶（摘要块内边距 s3）；警示色墨迹只有图标与号码（标题已置空）。
    /// 号码在大字号下进横滑条时读屏组合元素里不一定带号码，所以按卡片 + 摘要行定位，不按警示条自身的读屏文字找。
    /// 图标是最左一块警示色墨迹（左右按 ≥ 3pt 空白列分块），号码那一列从图标右侧开始。
    static func barProblems(_ canvas: BindPhoneLayoutCanvas, phoneLabel: String) async -> [String] {
        let tier = canvas.tier
        guard let (card, pixels) = await shoot(canvas, where: { $0.id == "bindPhone.pending" }) else {
            return ["[\(tier)] 无障碍树里找不到待确认卡 bindPhone.pending"]
        }
        let row = smallest(labelled(canvas.window)
            .filter { $0.label.contains(phoneLabel) && $0.label.contains(masked) })
        let bottom = min(row.map { $0.frame.minY - CouliSpacing.s3 } ?? card.frame.maxY, card.frame.maxY,
                         canvas.window.bounds.maxY)
        let area = CGRect(x: card.frame.minX, y: max(card.frame.minY, 0), width: card.frame.width,
                          height: max(0, bottom - max(card.frame.minY, 0)))
        let ink = ProductVisualPixels.RGB(CouliColor.statusWarningText, dark: false)
        let scale = pixels.scale
        let xs = max(0, Int(area.minX * scale))..<min(pixels.width, Int(area.maxX * scale))
        let ys = max(0, Int(area.minY * scale))..<min(pixels.height, Int(area.maxY * scale))
        let inked = xs.filter { column in ys.contains { pixels.color(px: column, $0).near(ink, tolerance: 40) } }
        guard let first = inked.first else { return ["[\(tier)] 警示条区域 \(area) 里没有警示色墨迹"] }
        // 图标块：从最左墨迹列起，到第一段 ≥ 3pt 的空白列为止
        var iconEnd = first
        for column in inked.dropFirst() {
            if CGFloat(column - iconEnd) >= 3 * scale {
                break
            }
            iconEnd = column
        }
        let left = CGFloat(iconEnd + 1) / scale + 1
        let column = CGRect(x: left, y: area.minY, width: max(0, area.maxX - left), height: area.height)
        return lineProblems(pixels, region: column, ink: CouliColor.statusWarningText, on: canvas,
                            name: "[\(tier)] 警示条说明句新号码")
    }

    /// 多个匹配（外层容器也可能带同样的读屏文字）时取面积最小的那个。
    static func smallest(_ nodes: [Node]) -> Node? {
        nodes.filter { $0.frame.width > 0 && $0.frame.height > 0 }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// 把匹配的元素滚到首屏顶部（大字号下卡片可能在首屏之外），重读元素框并截整窗。
    static func shoot(_ canvas: BindPhoneLayoutCanvas,
                      where match: (Node) -> Bool) async -> (Node, ProductVisualPixels)? {
        guard let first = smallest(labelled(canvas.window).filter(match)) else { return nil }
        if let scroll = canvas.mainScroll() {
            let local = scroll.convert(first.frame, from: nil)
            let limit = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            // 滚动视图自身坐标就是内容坐标：元素顶减去顶栏下的留白
            let target = min(limit, max(0, local.minY - BindPhoneLayoutCanvas.top - 8))
            scroll.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            await canvas.pump()
        }
        guard let node = smallest(labelled(canvas.window).filter(match)) else { return nil }
        return (node, ProductVisualPixels(render(canvas.window)))
    }

    // MARK: - 判据

    /// 区域里某文字色的墨迹：恰一行、高够一个数字；不在横滑条里时整段可见（宽 ≥ 号码整段宽 85%），
    /// 在横滑条里时横滑条竖向包住墨迹、墨迹铺到可见右缘。
    static func lineProblems(_ pixels: ProductVisualPixels, region: CGRect, ink color: Color,
                             on canvas: BindPhoneLayoutCanvas, name: String) -> [String] {
        let ink = ProductVisualPixels.RGB(color, dark: false)
        let size = bodySize(canvas.tier.size)
        let window = canvas.window
        let rows = inkRows(pixels, region: region, ink: ink)
        guard let row = rows.first else { return ["\(name)：区域 \(region) 里没有该文字色的墨迹"] }
        var found: [String] = []
        if rows.count != 1 {
            found.append("\(name)：号码墨迹分成 \(rows.count) 行 \(rows)——被拆开（区域 \(region)）")
        }
        if row.upperBound - row.lowerBound < size * 0.5 {
            found.append("\(name)：墨迹高 \(row.upperBound - row.lowerBound) 不够一个数字（字号 \(size)），上下被裁")
        }
        let band = CGRect(
            x: region.minX,
            y: row.lowerBound,
            width: region.width,
            height: row.upperBound - row.lowerBound
        )
        guard let span = inkSpan(pixels, region: band, ink: ink) else { return found }
        let inkRect = CGRect(x: span.lowerBound, y: row.lowerBound, width: span.upperBound - span.lowerBound,
                             height: row.upperBound - row.lowerBound)
        let whole = DigitsRunJudge.width(masked, size: size, weight: .regular)
        if let scroll = DigitsRunJudge.horizontalScroller(around: inkRect, inside: region, window: window) {
            let visible = scroll.convert(scroll.bounds, to: nil)
            if inkRect.minY < visible.minY - 0.5 || inkRect.maxY > visible.maxY + 0.5 {
                found.append("\(name)：横滑条可见框 \(visible) 竖向没包住号码墨迹 \(inkRect)（上下被裁）")
            }
            if span.upperBound < min(visible.maxX, region.maxX) - size * 0.5 {
                found.append("\(name)：横滑内容墨迹右端 \(span.upperBound) 没铺到可见右缘 \(visible.maxX)（缺字）")
            }
        } else if span.upperBound - span.lowerBound < whole * 0.85 {
            found.append("\(name)：可见墨迹宽 \(span.upperBound - span.lowerBound) < 号码整段宽 \(whole) 的 85%"
                + "——号码被截 / 缩 / 拆开")
        }
        return found
    }

    /// 接近文字色（容差 40：主文字 #28251F 与次文字 #655E57 差 61，不混）的像素按空白行切出的墨迹行（点坐标上下范围）。
    static func inkRows(_ pixels: ProductVisualPixels, region: CGRect,
                        ink: ProductVisualPixels.RGB) -> [ClosedRange<CGFloat>] {
        let scale = pixels.scale
        let xs = max(0, Int(region.minX * scale))..<min(pixels.width, Int(region.maxX * scale))
        let ys = max(0, Int(region.minY * scale))..<min(pixels.height, Int(region.maxY * scale))
        guard !xs.isEmpty, !ys.isEmpty else { return [] }
        var result: [ClosedRange<CGFloat>] = []
        var start: Int?
        for row in Array(ys) + [ys.upperBound] {
            let hit = ys.contains(row) && xs.contains { pixels.color(px: $0, row).near(ink, tolerance: 40) }
            if hit, start == nil {
                start = row
            } else if !hit, let top = start {
                result.append((CGFloat(top) / scale)...(CGFloat(row) / scale))
                start = nil
            }
        }
        return result
    }

    /// 区域里该文字色墨迹的左右范围（点坐标）。
    static func inkSpan(_ pixels: ProductVisualPixels, region: CGRect,
                        ink: ProductVisualPixels.RGB) -> ClosedRange<CGFloat>? {
        let scale = pixels.scale
        let xs = max(0, Int(region.minX * scale))..<min(pixels.width, Int(region.maxX * scale))
        let ys = max(0, Int(region.minY * scale))..<min(pixels.height, Int(region.maxY * scale))
        let columns = xs.filter { column in ys.contains { pixels.color(px: column, $0).near(ink, tolerance: 40) } }
        guard let first = columns.first, let last = columns.last else { return nil }
        return (CGFloat(first) / scale)...(CGFloat(last + 1) / scale)
    }
}

// MARK: - 宿主

extension DigitsWrapBindPendingTests {
    static func bodySize(_ size: DynamicTypeSize) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(
            for: CouliTextStyle.body.baseSize,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        )
    }

    static func render(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    struct Node {
        let id: String
        let label: String
        let frame: CGRect
    }

    /// 无障碍树里带标识或读屏文字的元素（SwiftUI 元素不是 UIView，要走 accessibilityElements；框是屏幕坐标，宿主窗口在原点）。
    static func labelled(_ root: NSObject) -> [Node] {
        var out: [Node] = []
        func walk(_ node: NSObject, depth: Int) {
            guard depth < 60 else { return }
            let id = node.responds(to: NSSelectorFromString("accessibilityIdentifier"))
                ? node.value(forKey: "accessibilityIdentifier") as? String ?? "" : ""
            let label = node.accessibilityLabel ?? ""
            if !id.isEmpty || !label.isEmpty {
                out.append(Node(id: id, label: label, frame: node.accessibilityFrame))
            }
            var children = (node.accessibilityElements as? [NSObject]) ?? []
            if children.isEmpty, node.accessibilityElementCount() != NSNotFound {
                let count = max(node.accessibilityElementCount(), 0)
                children = (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
            }
            children += (node as? UIView)?.subviews ?? []
            children.forEach { walk($0, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return out
    }
}

/// 绑手机页数字用例共用（`DigitsWrapBindPendingTests`、`DigitsWrapBindMergeTests`）：假服务报文、第三方新号链路、读屏树开关。
enum DigitsBindScript {
    static let attempt = "{\"attempt_id\":\"att-1\",\"nonce\":\"nonce-for-test-0001\","
        + "\"expire_at\":\"2099-01-01T00:10:00+08:00\"}"
    static let login = "{\"user_id\":\"user-oauth\",\"is_new_user\":true,\"tokens\":{\"access_token\":\"at-o\","
        + "\"refresh_token\":\"rt-o\",\"session_scope\":\"full\"}}"
}

extension MeTestCase {
    /// 第三方新号 → 引导【去绑定】→ 绑手机页的导航实例（与 BindPhoneLayoutTests / OAuthBindPhoneWiringTests 同一条真实链路）。
    func digitsBindEntry(_ fixture: MeAppFixture) async throws -> BindPhoneEntry {
        let wechat = AppFakeAuthorizer(OAuthProvider.wechat)
        fixture.login.oauth.authorizers = [OAuthProvider.wechat: wechat]
        fixture.router.open(RouteRequest(route: "InviteShare", from: .inApp))
        let model = LoginViewModel(config: fixture.login.pageConfig(restricted: false))
        model.toggleAgreement()
        model.startOAuth(OAuthProvider.wechat)
        await waitUntil("没有拉起授权") { wechat.authorizing }
        wechat.complete(.credential(.wechat(code: "code-from-sdk")))
        await waitUntil("没有弹绑手机引导") { fixture.login.bindGuide != nil }
        let guide = try XCTUnwrap(fixture.login.bindGuide)
        fixture.login.goBindPhone(guide.id)
        let top = try XCTUnwrap(fixture.router.path.last)
        XCTAssertEqual(top.route, RoutePolicy.bindPhone)
        return fixture.login.bindEntry(for: top)
    }

    /// 打开进程内无障碍树（同 StepUpVisualTestCase：`_AXSSetAutomationEnabled`，不开时 SwiftUI 不建读屏元素）；用例结束复原。
    func enableDigitsAccessibilityTree() throws {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        let handle = try XCTUnwrap(dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_NOW), "libAccessibility")
        typealias Getter = @convention(c) () -> Int32
        typealias Setter = @convention(c) (Int32) -> Void
        let getter = try XCTUnwrap(dlsym(handle, "_AXSAutomationEnabled"))
        let setter = try XCTUnwrap(dlsym(handle, "_AXSSetAutomationEnabled"))
        let set = unsafeBitCast(setter, to: Setter.self)
        let old = unsafeBitCast(getter, to: Getter.self)()
        set(1)
        addTeardownBlock { set(old) }
    }
}
