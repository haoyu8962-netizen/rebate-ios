import Darwin
import DesignSystem
import Foundation
import MachO
import SwiftUI
import UIKit
import XCTest

// FU-IOS-A11Y（D10-1231，QA-12b 读屏审计）进程内判据工具：
// 1. `A11yPostTap`：把本 App（及测试包）镜像里对 `UIAccessibilityPostNotification` / `UIAccessibilityIsVoiceOverRunning` 的调用改指到
//    测试替身（按符号地址改写本进程已绑定的导入槽，只改 Couli.app、.xctest 与构建产物目录里的镜像，系统库不动），记下每一次播报与焦点通知；
//    可选「读屏开着」，让「读屏开着才播报、播完再移焦」的生产写法在进程内也走到播报那一支。用例结束还原。
// 2. `A11yTree`：打开 SwiftUI 无障碍树（同 StepUpVisualTestCase.enableAccessibilityTree）、展开元素、按标识 / 名称找、激活、擦除（Z 形返回）。
// 3. `A11yProbes`：测量桥 + 焦点转移接收方（`couliFocusProbe` 报的编号）。
// 4. `A11yCanvas`：把生产页面挂进临时窗口（宽、字号、测量桥）。

// MARK: - 播报拦截

enum A11yPostTap {
    struct Post: CustomStringConvertible {
        let notification: UInt32
        let text: String?
        /// 排队播报（`accessibilitySpeechQueueAnnouncement`）。
        let queued: Bool
        let identifier: String?

        var isAnnouncement: Bool {
            notification == UIAccessibility.Notification.announcement.rawValue
        }

        var description: String {
            "#\(notification) \(queued ? "polite" : "assertive") \(text ?? identifier ?? "-")"
        }
    }

    typealias PostFunction = @convention(c) (UInt32, UnsafeRawPointer?) -> Void
    typealias RunningFunction = @convention(c) () -> Bool

    private struct Patch {
        let slot: UnsafeMutablePointer<UInt>
        let original: UInt
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var recorded: [Post] = []
    private nonisolated(unsafe) static var patches: [Patch] = []
    private nonisolated(unsafe) static var realPost: PostFunction?
    /// 替身返回的「读屏开着」。
    nonisolated(unsafe) static var voiceOverRunning = false

    static var posts: [Post] {
        lock.withLock { recorded }
    }

    static var announcements: [Post] {
        posts.filter(\.isAnnouncement)
    }

    static func clear() {
        lock.withLock { recorded = [] }
    }

    /// 装上拦截（幂等）；返回改写的导入槽个数（0 = 没装上，用例应判失败）。
    @discardableResult
    static func install(voiceOver: Bool) -> Int {
        voiceOverRunning = voiceOver
        clear()
        if !lock.withLock({ patches.isEmpty }) {
            return lock.withLock { patches.count }
        }
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let post = dlsym(rtldDefault, "UIAccessibilityPostNotification"),
              let running = dlsym(rtldDefault, "UIAccessibilityIsVoiceOverRunning")
        else { return 0 }
        realPost = unsafeBitCast(post, to: PostFunction.self)
        let replacements: [UInt: UInt] = [
            UInt(bitPattern: post): unsafeBitCast(a11yTappedPost, to: UInt.self),
            UInt(bitPattern: running): unsafeBitCast(a11yTappedRunning, to: UInt.self),
        ]
        var made: [Patch] = []
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index).map({ String(cString: $0) }),
                  name.contains("/Couli.app/") || name.contains(".xctest/") || name.contains("/Build/Products/"),
                  let header = _dyld_get_image_header(index)
            else { continue }
            let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
            for (segment, section) in [("__DATA_CONST", "__got"), ("__DATA", "__got"), ("__DATA", "__la_symbol_ptr"),
                                       ("__AUTH_CONST", "__auth_got")] {
                made += rewrite(header64, segment, section, replacements)
            }
        }
        lock.withLock { patches = made }
        return made.count
    }

    static func uninstall() {
        let undo = lock.withLock {
            defer { patches = [] }
            return patches
        }
        for patch in undo {
            write(patch.slot, patch.original)
        }
        voiceOverRunning = false
        clear()
    }

    private static func rewrite(_ header: UnsafePointer<mach_header_64>, _ segment: String, _ section: String,
                                _ replacements: [UInt: UInt]) -> [Patch] {
        var size: UInt = 0
        guard let data = getsectiondata(header, segment, section, &size), size >= 8 else { return [] }
        let slots = UnsafeMutableRawPointer(data).bindMemory(to: UInt.self, capacity: Int(size) / 8)
        var made: [Patch] = []
        for offset in 0..<(Int(size) / 8) {
            let slot = slots.advanced(by: offset)
            if let target = replacements[slot.pointee] {
                made.append(Patch(slot: slot, original: slot.pointee))
                write(slot, target)
            }
        }
        return made
    }

    private static func write(_ slot: UnsafeMutablePointer<UInt>, _ value: UInt) {
        let page = UInt(getpagesize())
        let start = UInt(bitPattern: slot) & ~(page - 1)
        _ = mprotect(UnsafeMutableRawPointer(bitPattern: start), Int(page), PROT_READ | PROT_WRITE)
        slot.pointee = value
    }

    fileprivate static func record(_ notification: UInt32, _ argument: UnsafeRawPointer?) {
        let object = argument.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
        var text: String?
        var queued = false
        if let attributed = object as? NSAttributedString {
            text = attributed.string
            if attributed.length > 0 {
                let value = attributed.attribute(.accessibilitySpeechQueueAnnouncement, at: 0, effectiveRange: nil)
                queued = (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
            }
        } else if let string = object as? String {
            text = string
        }
        let identifier = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier
        lock.withLock {
            recorded.append(Post(notification: notification, text: text, queued: queued, identifier: identifier))
        }
    }

    fileprivate static func forward(_ notification: UInt32, _ argument: UnsafeRawPointer?) {
        realPost?(notification, argument)
    }
}

private nonisolated(unsafe) let a11yTappedPost: A11yPostTap.PostFunction = { notification, argument in
    A11yPostTap.record(notification, argument)
    A11yPostTap.forward(notification, argument)
}

private nonisolated(unsafe) let a11yTappedRunning: A11yPostTap.RunningFunction = {
    A11yPostTap.voiceOverRunning
}

// MARK: - 无障碍树

struct A11yNode: CustomStringConvertible {
    let object: NSObject
    let id: String
    let label: String
    let value: String
    let traits: UIAccessibilityTraits
    let frame: CGRect
    let isElement: Bool
    /// 祖先容器的标识（由外到内）。
    let containers: [String]

    var isButton: Bool {
        traits.contains(.button)
    }

    var isHeader: Bool {
        traits.contains(.header)
    }

    func inside(_ container: String) -> Bool {
        containers.contains(container)
    }

    var description: String {
        "[\(id.isEmpty ? "-" : id)] \"\(label)\"\(value.isEmpty ? "" : " = \(value)")\(isButton ? " 按钮" : "")"
            + "\(isHeader ? " 标题" : "")"
    }
}

@MainActor
enum A11yTree {
    /// SwiftUI 只在无障碍自动化打开时构造无障碍树（同 StepUpVisualTestCase.enableAccessibilityTree）。必须在页面挂上之前调用。
    static func enable(_ test: XCTestCase) throws {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        let handle = try XCTUnwrap(dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_NOW), "libAccessibility")
        typealias Getter = @convention(c) () -> Int32
        typealias Setter = @convention(c) (Int32) -> Void
        let getter = try XCTUnwrap(dlsym(handle, "_AXSAutomationEnabled"))
        let setter = try XCTUnwrap(dlsym(handle, "_AXSSetAutomationEnabled"))
        let set = unsafeBitCast(setter, to: Setter.self)
        let old = unsafeBitCast(getter, to: Getter.self)()
        set(1)
        test.addTeardownBlock { set(old) }
    }

    /// 展开整棵树（元素与带标识的容器都收）。
    static func nodes(_ root: NSObject) -> [A11yNode] {
        var out: [A11yNode] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: NSObject, containers: [String], depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(node)).inserted else { return }
            let key = NSSelectorFromString("accessibilityIdentifier")
            let id = node.responds(to: key) ? node.value(forKey: "accessibilityIdentifier") as? String ?? "" : ""
            let label = node.accessibilityLabel ?? ""
            if node.isAccessibilityElement || !id.isEmpty || !label.isEmpty {
                out.append(A11yNode(object: node, id: id, label: label, value: node.accessibilityValue ?? "",
                                    traits: node.accessibilityTraits, frame: node.accessibilityFrame,
                                    isElement: node.isAccessibilityElement, containers: containers))
            }
            var children = (node.accessibilityElements as? [NSObject]) ?? []
            if children.isEmpty, node.accessibilityElementCount() != NSNotFound {
                let count = max(node.accessibilityElementCount(), 0)
                children = (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
            }
            if !node.accessibilityElementsHidden {
                children += (node as? UIView)?.subviews ?? []
            }
            let inner = id.isEmpty || node.isAccessibilityElement ? containers : containers + [id]
            children.forEach { walk($0, containers: inner, depth: depth + 1) }
        }
        walk(root, containers: [], depth: 0)
        return out
    }

    /// 读屏能停留的元素（isAccessibilityElement）。
    static func elements(_ root: NSObject) -> [A11yNode] {
        nodes(root).filter(\.isElement)
    }

    static func node(_ id: String, in root: NSObject) -> A11yNode? {
        nodes(root).first { $0.id == id }
    }

    static func element(labelled label: String, in root: NSObject) -> A11yNode? {
        elements(root).first { $0.label == label }
    }

    /// 模拟 VoiceOver 擦除：从 `start` 沿无障碍容器逐级调 `accessibilityPerformEscape`，有人接住返回 true（同 StepUpVisualTestCase）。
    static func escape(from start: NSObject) -> Bool {
        var current: NSObject? = start
        while let item = current {
            if item.accessibilityPerformEscape() {
                return true
            }
            let container = NSSelectorFromString("accessibilityContainer")
            let answer = item.responds(to: container) ? item.perform(container) : nil
            let parent = answer?.takeUnretainedValue() as? NSObject
            current = parent ?? (item as? UIView)?.superview
        }
        return false
    }

    /// 读屏双击（默认动作）。
    @discardableResult
    static func activate(_ node: A11yNode) -> Bool {
        node.object.accessibilityActivate()
    }

    static func dump(_ nodes: [A11yNode]) -> String {
        nodes.map(\.description).joined(separator: "\n")
    }
}

// MARK: - 测量桥 + 焦点

@MainActor
final class A11yProbes {
    private(set) var records: [String: CouliLayoutProbeRecord] = [:]
    /// `couliFocusProbe` 报的焦点转移（按时间顺序）。
    private(set) var focused: [String] = []

    lazy var probe = CouliLayoutProbe(
        report: { [weak self] in self?.records[$0.id] = $0 },
        remove: { [weak self] in self?.records[$0] = nil },
        focus: { [weak self] in self?.focused.append($0) }
    )

    subscript(_ id: String) -> CouliLayoutProbeRecord? {
        records[id]
    }

    func recordFocus(_ id: String) {
        focused.append(id)
    }

    func clearFocus() {
        focused = []
    }

    /// 在现有宿主的测量桥上加焦点接收（测量照旧报给原接收方）。
    static func addingFocus(to original: CouliLayoutProbe, _ sink: @escaping (String) -> Void) -> CouliLayoutProbe {
        CouliLayoutProbe(report: original.report, remove: original.remove, focus: sink)
    }
}
