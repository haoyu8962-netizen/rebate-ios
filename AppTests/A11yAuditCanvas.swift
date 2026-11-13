import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

// FU-IOS-A11Y 判据工具（续，见 A11yAuditKit.swift）：页面宿主与共用断言。

// MARK: - 宿主

@MainActor
final class A11yCanvas {
    let window: UIWindow
    private var hidden: [UIWindow] = []

    init(_ page: AnyView, width: CGFloat = 390, height: CGFloat = 844, size: DynamicTypeSize = .large,
         probe: CouliLayoutProbe? = nil) {
        let root = page
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 54) }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 34) }
            .environment(\.couliLayoutProbe, probe)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, size)
        let host = UIHostingController(rootView: root)
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = []
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = .light
        window.windowLevel = .alert + 1
        window.rootViewController = host
        hidden = (scene?.windows ?? []).filter { $0 !== window && !$0.isHidden }
        hidden.forEach { $0.isHidden = true }
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
    }

    var root: NSObject {
        window
    }

    func close() {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
        hidden.forEach { $0.isHidden = false }
        hidden = []
    }

    /// 布局几轮（onAppear / task / 绑定回写跑完）。
    func pump(_ seconds: Double = 0.4) async {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            window.rootViewController?.view.setNeedsLayout()
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 30_000_000)
        } while Date() < deadline
    }

    /// 等树里出现满足条件的元素（最多 `seconds` 秒）。
    func wait(_ seconds: Double = 6, until condition: ([A11yNode]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            await pump(0.1)
            if condition(A11yTree.nodes(window)) {
                return true
            }
        }
        return false
    }
}

// MARK: - 共用断言

@MainActor
enum A11yAudit {
    /// 装播报拦截并自检：生产 DS 的礼貌播报必须被记下（否则拦截没装上，后续「没播报」的结论不成立）。
    static func installTap(_ test: XCTestCase, voiceOver: Bool, file: StaticString = #filePath,
                           line: UInt = #line) {
        let count = A11yPostTap.install(voiceOver: voiceOver)
        test.addTeardownBlock { A11yPostTap.uninstall() }
        XCTAssertGreaterThan(count, 0, "测试设施：没有改写到任何导入槽（播报拦截没装上）", file: file, line: line)
        CouliStatusAnnouncer.polite("a11y-tap-selftest")
        XCTAssertTrue(A11yPostTap.announcements.contains { $0.text == "a11y-tap-selftest" },
                      "测试设施：生产 DS 的播报没有被拦到（\(A11yPostTap.posts)）", file: file, line: line)
        XCTAssertEqual(UIAccessibility.isVoiceOverRunning, voiceOver, "测试设施：读屏开关替身", file: file, line: line)
        A11yPostTap.clear()
    }

    /// 等一条播报（文字包含 `text`）。
    static func waitAnnouncement(containing text: String, seconds: Double = 4) async -> A11yPostTap.Post? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let hit = A11yPostTap.announcements.first(where: { $0.text?.contains(text) == true }) {
                return hit
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return nil
    }

    /// 模拟系统「播报结束」通知（读屏开着时，生产写法等它再移焦）。
    static func finishAnnouncement(_ text: String) {
        NotificationCenter.default.post(
            name: UIAccessibility.announcementDidFinishNotification, object: nil,
            userInfo: [UIAccessibility.announcementStringValueUserInfoKey: text,
                       UIAccessibility.announcementWasSuccessfulUserInfoKey: true]
        )
    }

    /// 仓库根（有 contract.lock 的目录）。
    static func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { throw XCTSkip("找不到仓库根（contract.lock）") }
            directory = parent
        }
        return directory
    }

    /// 去掉注释的产品源码。
    static func source(_ path: String) throws -> String {
        let text = try String(contentsOf: repositoryRoot().appendingPathComponent(path), encoding: .utf8)
        return ShellSystemTabBarSourceTests.stripComments(text)
    }
}
