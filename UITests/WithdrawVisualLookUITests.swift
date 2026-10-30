import SnapshotTesting
import UIKit
import XCTest

/// APP-09v-c 读屏结构、说明半屏、规则链接真点（依赖实现与 `withdraw` 载荷；底版预期红）。
@MainActor
final class WithdrawVisualLookUITests: XCTestCase, WithdrawVisualUITest {
    override func setUp() async throws {
        continueAfterFailure = true
    }

    /// W37：整张余额卡一个读屏元素（标签 + 金额 + 次数），次数不单独停留。
    func testBalanceCardIsOneElement() throws {
        let app = try launchWithdraw()
        let balance = node(app, "withdraw.balance")
        let order = try spoken(app)
        keep(order, "withdraw-spoken")
        XCTAssertTrue(balance.label.contains("12.34") || balance.label.contains("12 元"), balance.label)
        XCTAssertTrue(balance.label.contains("今日还可提 1 次"), "次数读在同一元素：\(balance.label)")
        XCTAssertEqual(order.filter { $0.label.contains("今日还可提") }.count, 1, "只读一次")
        app.terminate()
    }

    /// 读屏顺序（brief §4.2）：余额卡 → 金额框 → 全部提现 → 上限 → 档位 → 估算 → 账号行 → 时效 → 提交。
    func testReadingOrder() throws {
        let app = try launchWithdraw()
        type(app, "10")
        let order = try spoken(app)
        keep(order, "withdraw-order")
        let ids = order.map(\.id)
        let wanted = ["withdraw.balance", "withdraw.input", "withdraw.all", "withdraw.max", "withdraw.quick.500",
                      "withdraw.estimate", "withdraw.payout", "withdraw.sla", "withdraw.submit"]
        let positions = wanted.map { ids.firstIndex(of: $0) ?? -1 }
        XCTAssertFalse(positions.contains(-1), "读屏树缺元素：\(zip(wanted, positions).filter { $0.1 < 0 })")
        XCTAssertEqual(positions, positions.sorted(), "顺序：\(zip(wanted, positions).map { "\($0.0)=\($0.1)" })")
        app.terminate()
    }

    /// W45 / G-W27：「预计到账」说明：正文 14、【知道了】描边；关闭零请求；整屏基准。
    func testNoteNetSheet() throws {
        let app = try launchWithdraw()
        type(app, "10")
        let before = log(app).count
        app.buttons["预计到账说明"].firstMatch.tap()
        let body = node(app, "wallet.help.text")
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.2)
        let image = app.screenshot().image
        let ok = node(app, "wallet.help.ok")
        XCTAssertFalse(isBrandFill(image, ok.frame), "【知道了】描边，不是实底")
        XCTAssertLessThan(body.frame.height / CGFloat(lines(body)), 23, "正文 14/21（不是 17）：\(body.frame)")
        withSnapshotTesting(record: ProcessInfo.processInfo
            .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98),
                               named: "WithdrawNoteNet-GW27-light")
            }
        ok.tap()
        XCTAssertTrue(body.waitForNonExistence(timeout: 3))
        XCTAssertEqual(entries(app, after: before).filter { $0.hasPrefix("route:") }, [], "不导航")
        XCTAssertEqual(writes(entries(app, after: before)), [], "不写")
        app.terminate()
    }

    /// W53：「提现规则」四边真点各恰一次 Help {article_id}，不碰【提交】。
    func testRulesLinkEdgesRealTap() throws {
        for edge in [UIRectEdge.top, .bottom, .left, .right] {
            let app = try launchWithdraw(withdraw: ["helpLinks": helpLinks()])
            let link = node(app, "withdraw.rulesLink")
            guard link.waitForExistence(timeout: 5) else {
                throw WalletVisualUIError.notInjected("withdraw.helpLinks 载荷")
            }
            type(app, "10")
            let before = log(app).count
            tapEdge(link, edge)
            waitLog(app, beyond: before)
            let after = entries(app, after: before)
            XCTAssertEqual(
                after.filter { $0.hasPrefix("route:") },
                ["route:Help?article_id=withdraw-rules-fixture"],
                "\(edge)"
            )
            XCTAssertEqual(writes(after), [], "\(edge)：不误触【提交】")
            app.terminate()
        }
    }

    /// W48 / G-W15：30309 真点【查看提现规则】恰一次 Help，零写。
    func testGuideRulesButtonRealTap() throws {
        let rules = try XCTUnwrap((visualWithdraw()["rules"] as? [String: Any])?["blocked_30309"])
        let app = try launchWithdraw(withdraw: ["rules": rules, "helpLinks": helpLinks()])
        let button = app.buttons["查看提现规则"].firstMatch
        guard button.waitForExistence(timeout: 5) else {
            throw WalletVisualUIError.notInjected("withdraw 载荷或 30309 按钮")
        }
        let before = log(app).count
        button.tap()
        waitLog(app, beyond: before)
        XCTAssertEqual(entries(app, after: before).filter { $0.hasPrefix("route:") },
                       ["route:Help?article_id=withdraw-rules-fixture"])
        XCTAssertEqual(writes(entries(app, after: before)), [])
        app.terminate()
    }

    /// 读屏可达的元素（有 label 的元素不再展开子树，同 b 组 v2 `spokenOrder`）；用 identifier 或 label 都可定位。
    private func spoken(_ app: XCUIApplication) throws -> [WalletA11yItem] {
        var items: [WalletA11yItem] = []
        func walk(_ element: XCUIElementSnapshot, root: Bool) {
            let named = !element.label.isEmpty || !element.identifier.isEmpty
            if !root, named, !element.label.isEmpty || element.elementType == .textField {
                items.append(WalletA11yItem(id: element.identifier, label: element.label, frame: element.frame))
                return
            }
            element.children.forEach { walk($0, root: false) }
        }
        try walk(app.snapshot(), root: true)
        return items
    }

    private func lines(_ body: XCUIElement) -> Int {
        let text = NSAttributedString(string: body.label, attributes: [.font: UIFont.systemFont(ofSize: 14)])
        let height = text.boundingRect(with: CGSize(width: body.frame.width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin], context: nil).height
        return max(1, Int((height / UIFont.systemFont(ofSize: 14).lineHeight).rounded(.up)))
    }

    private func isBrandFill(_ image: UIImage, _ frame: CGRect) -> Bool {
        guard let cg = image.cgImage else { return false }
        let scale = CGFloat(cg.width) / image.size.width
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        let point = CGPoint(x: (frame.minX + frame.width / 6) * scale, y: frame.midY * scale)
        context.draw(cg, in: CGRect(x: -point.x, y: -(CGFloat(cg.height) - point.y), width: CGFloat(cg.width),
                                    height: CGFloat(cg.height)))
        return abs(Int(pixel[0]) - 196) < 30 && abs(Int(pixel[1]) - 72) < 30 && abs(Int(pixel[2]) - 32) < 30
    }
}
