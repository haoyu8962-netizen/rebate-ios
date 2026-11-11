@testable import Couli
import DesignSystem
import SwiftUI
import UIKit
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-ADAPT-CHECK ②（QA-11 iOS #5：`WithdrawStepUp-font200-w320-light` / `-short-light`「验证并提交」被截掉下半、按钮下方大片留白）。
/// 截图那一镜：提现页 → 10003 → 二次验证半屏（窗口特征 AX3）→ 输入「38」，生产代码 300ms 后把焦点给验证码框，系统键盘弹起。
/// 进程内截图（drawHierarchy 只画 App 窗口）不含键盘窗口，键盘占的那一块显示成半屏底色——这就是「按钮下方留白」。
/// - `testBlankBelowSubmitIsKeyboardArea`：把这个结论钉成事实（键盘确实弹起；留白区 = 键盘顶到半屏底，整块是半屏底色）。
/// - `testSubmitFullyVisibleAboveKeyboardAndTappable`：按结论钉「按钮完整可见可点」——键盘弹起时，【验证并提交】要么本来就完整在键盘之上，
///   要么用户把半屏滚到底后完整在键盘之上；命中 ≥ 44，按钮中心点得到（命中测试落在半屏里）。
@MainActor
final class StepUpKeyboardReachTests: StepUpVisualTestCase {
    /// tests v2 编译修（Swift 6 数据竞争，判据不变）：通知回调是 @Sendable，不能捕获测试实例；键盘框记在一个只在主队列（queue: .main）读写的盒子里。
    private final class KeyboardBox: @unchecked Sendable {
        var frame: CGRect?
    }

    private let box = KeyboardBox()
    private var keyboard: CGRect? {
        get { box.frame }
        set { box.frame = newValue }
    }

    private var observers: [NSObjectProtocol] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        keyboard = nil
        let center = NotificationCenter.default
        let box = box
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidShowNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                box.frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            })
        }
        observers.append(center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil,
                                            queue: .main) { _ in
                box.frame = nil
            })
    }

    override func tearDown() async throws {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        try await super.tearDown()
    }

    /// 键盘顶（窗口坐标；宿主窗口在原点，与屏幕坐标一致）。键盘没弹或在窗口外时 nil。
    private func keyboardTop(_ sheet: CGRect) -> CGFloat? {
        guard let keyboard, keyboard.height > 100, keyboard.minY < sheet.maxY else { return nil }
        return keyboard.minY
    }

    private func openKeyboardSheet(width: CGFloat, height: CGFloat) async throws -> (WithdrawVisualHost, UIImage) {
        let opened = try await openSheet(code: "38", canvas: .init(width: width, height: height), large: Self.ax3,
                                         waitFor: "stepUp.cell.5")
        await waitUntil("键盘没有弹起（验证码框没拿到焦点）", timeout: 5) { self.keyboard != nil }
        let image = try await settled(opened.0, waitFor: "stepUp.submit")
        return (opened.0, image)
    }

    func testBlankBelowSubmitIsKeyboardArea() async throws {
        let (_, image) = try await openKeyboardSheet(width: 320, height: 844)
        XCTAssertEqual(presentedCategory, Self.ax3, "前提：半屏真 200%")
        XCTAssertTrue(sheetField()?.isFirstResponder == true, "验证码框拿到焦点")
        let sheet = try sheetFrame()
        let top = try XCTUnwrap(keyboardTop(sheet), "键盘确实弹起、压在半屏上（键盘框 \(String(describing: keyboard))）")
        let blank = CGRect(x: sheet.minX + 4, y: top + 4, width: sheet.width - 8, height: max(0, sheet.maxY - top - 8))
        let surface = pixel(CouliColor.backgroundSurface, dark: false)
        let total = max(1, ProductVisualPixels(image).count(in: blank, step: 3) { _ in true })
        let plain = ProductVisualPixels(image).count(in: blank, step: 3) { $0.near(surface, tolerance: 6) }
        XCTAssertGreaterThan(Double(plain) / Double(total), 0.97,
                             "键盘顶 \(top) 以下（\(blank)）是半屏底色占位（键盘窗口不进截图）")
        XCTContext.runActivity(named: "键盘与半屏") { activity in
            activity.add(XCTAttachment(string: "sheet=\(sheet) keyboard=\(String(describing: keyboard)) "
                    + "submit=\(String(describing: page?.probes["stepUp.submit"]?.rect)) "
                    + "fallback=\(has("stepUp.fallback"))"))
            activity.add(XCTAttachment(image: image))
        }
    }

    func testSubmitFullyVisibleAboveKeyboardAndTappable() async throws {
        for (width, height) in [(CGFloat(320), CGFloat(844)), (320, 568), (390, 844)] {
            let (host, _) = try await openKeyboardSheet(width: width, height: height)
            let name = "\(Int(width))×\(Int(height)) + 200% + 键盘"
            let sheet = try sheetFrame()
            let bottom = keyboardTop(sheet) ?? sheet.maxY
            var submit = try rect("stepUp.submit")
            if submit.maxY > bottom + 0.5 || submit.minY < sheet.minY - 0.5 {
                // 用户能做的只有滚半屏：滚到底再看
                if let scroller = sheetScroller() {
                    let end = max(0, scroller.contentSize.height + scroller.adjustedContentInset.bottom
                        - scroller.bounds.height)
                    scroller.setContentOffset(CGPoint(x: 0, y: end), animated: false)
                    _ = try await settled(host, waitFor: "stepUp.submit")
                    submit = try rect("stepUp.submit")
                }
            }
            XCTAssertLessThanOrEqual(submit.maxY, bottom + 0.5,
                                     "\(name)：【验证并提交】下缘 \(submit.maxY) 在键盘顶 / 半屏底 \(bottom) 之下（滚到底后仍被截）")
            XCTAssertGreaterThanOrEqual(submit.minY, sheet.minY - 0.5, "\(name)：按钮上缘在半屏之外")
            XCTAssertGreaterThanOrEqual(submit.height, 43.5, "\(name)：按钮高 ≥ 44")
            let center = CGPoint(x: submit.midX, y: min(submit.midY, bottom - 1))
            let presented = host.window?.rootViewController?.presentedViewController?.view
            let hit = host.window?.hitTest(center, with: nil)
            XCTAssertTrue(hit.map { $0.isDescendant(of: presented ?? UIView()) } ?? false,
                          "\(name)：按钮中心点不到（命中 \(String(describing: hit))）")
        }
    }

    private func sheetScroller() -> UIScrollView? {
        guard let root = page?.window?.rootViewController?.presentedViewController?.view else { return nil }
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, !(view is UITextView), scroll.bounds.height > 60 {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found.max { $0.bounds.height < $1.bounds.height }
    }
}
