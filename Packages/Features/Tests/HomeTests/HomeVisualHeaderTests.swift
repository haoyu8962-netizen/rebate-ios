import Foundation
@testable import Home
import SwiftUI
import UIKit
import XCTest

@MainActor
final class HomeVisualHeaderTests: XCTestCase {
    override func setUp() {
        HomeColorBlockImages.install()
    }

    override func tearDown() {
        HomeColorBlockImages.uninstall()
    }

    func testNativeSlotBelongsToTheSduiVerticalScrollView() async throws {
        let fixture = try HomeVisualFixture()
        await fixture.start()
        let marker = NativeHeaderMarker()
        // 新接口：默认头部为空；App 必须把真实提示条 / 价值卡 / 粘贴卡放进这个槽。
        let root = HomeSduiScreen(controller: fixture.controller) {
            VStack {
                Text("native fixture")
                marker.frame(height: 100)
            }
        }
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 480))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        try? await Task.sleep(for: .milliseconds(300))
        let view = try XCTUnwrap(descendants(host.view).first { $0.accessibilityIdentifier == "visual-native-marker" })
        var parents: [UIScrollView] = []
        var next = view.superview
        while let current = next {
            if let scroll = current as? UIScrollView {
                parents.append(scroll)
            }
            next = current.superview
        }
        XCTAssertEqual(parents.count, 1, "头部不能另包一个纵向滚动容器")
        let scroll = try XCTUnwrap(parents.first)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        let before = view.convert(view.bounds, to: window).minY
        scroll.setContentOffset(CGPoint(x: 0, y: 80), animated: false)
        host.view.layoutIfNeeded()
        XCTAssertEqual(view.convert(view.bounds, to: window).minY, before - 80, accuracy: 1)
        await fixture.close()
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

private struct NativeHeaderMarker: UIViewRepresentable {
    func makeUIView(context _: Context) -> UIView {
        let view = UIView()
        view.accessibilityIdentifier = "visual-native-marker"
        return view
    }

    func updateUIView(_: UIView, context _: Context) {}
}
