import SwiftUI
import UIKit
import XCTest

/// FU-IOS-BINDPHONE-LAYOUT（D10-1223）进程内宿主：把生产页面挂进临时 UIWindow，按四档（正常 / 200% / 320 宽 + 200% / AXXXL）
/// 注入 dynamicTypeSize，安全区 顶 54 / 底 34。判据只读 UIKit 层级（系统输入框的类、字体、框）与整窗渲染像素，不依赖页面另加测量钩子。
@MainActor
final class BindPhoneLayoutCanvas {
    struct Tier: CustomStringConvertible {
        let name: String
        let width: CGFloat
        let size: DynamicTypeSize

        var description: String {
            name
        }
    }

    /// 200% = 系统「辅助功能大」（UICTContentSizeCategoryAccessibilityL，DynamicTypeSize.accessibility2），与 UITests 的 200% 档一致。
    static let tiers: [Tier] = [
        Tier(name: "正常", width: 390, size: .large),
        Tier(name: "200%", width: 390, size: .accessibility2),
        Tier(name: "320 宽 + 200%", width: 320, size: .accessibility2),
        Tier(name: "AXXXL", width: 390, size: .accessibility5),
    ]
    static let top: CGFloat = 54
    static let bottom: CGFloat = 34
    static let height: CGFloat = 844

    let window: UIWindow
    let tier: Tier
    private var hidden: [UIWindow] = []

    init(_ page: AnyView, tier: Tier) {
        self.tier = tier
        let root = page
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: Self.top) }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: Self.bottom) }
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, tier.size)
        let host = UIHostingController(rootView: root)
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = []
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: tier.width, height: Self.height)
        window.overrideUserInterfaceStyle = .light
        window.windowLevel = .alert + 1
        window.rootViewController = host
        hidden = (scene?.windows ?? []).filter { $0 !== window && !$0.isHidden }
        hidden.forEach { $0.isHidden = true }
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
    }

    func close() {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
        hidden.forEach { $0.isHidden = false }
        hidden = []
    }

    /// 布局几轮（onAppear / onChange / 绑定回写跑完）。
    func pump(rounds: Int = 8) async {
        for _ in 0..<rounds {
            window.rootViewController?.view.setNeedsLayout()
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    // MARK: - UIKit 层级

    static func all(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(all)
    }

    /// 手机号输入框：层级里键盘类型为电话键盘的系统输入控件（UITextField 或纵向轴 TextField 背后的 UITextView）。
    func phoneInputs() -> [UIView] {
        Self.all(window).filter { view in
            if let field = view as? UITextField {
                return field.keyboardType == .phonePad
            }
            if let text = view as? UITextView {
                return text.keyboardType == .phonePad
            }
            return false
        }
    }

    func rect(_ view: UIView) -> CGRect {
        view.convert(view.bounds, to: window)
    }

    /// 页面主滚动区：最高的 UIScrollView（排除 UITextView，它也是滚动视图的子类）。
    func mainScroll() -> UIScrollView? {
        Self.all(window).compactMap { $0 as? UIScrollView }.filter { !($0 is UITextView) && !$0.isHidden }
            .max { rect($0).height < rect($1).height }
    }

    func render() -> BindPhoneLayoutPixels? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return BindPhoneLayoutPixels(image)
    }
}

/// 一个系统输入控件此刻的显示状况（判据 ① ② 用）。
struct BindPhoneInputReading: CustomStringConvertible {
    let kind: String
    let text: String
    let font: UIFont?
    let frame: CGRect
    /// 纵向输入框里当前文字是否放不下一行而折行（单行 UITextField 恒为 false：系统单行框只会框内横向滚动）。
    let wrapped: Bool

    @MainActor
    init(_ view: UIView, in canvas: BindPhoneLayoutCanvas) {
        frame = canvas.rect(view)
        if let field = view as? UITextField {
            kind = "UITextField"
            text = field.text ?? ""
            font = field.font
            wrapped = false
        } else if let area = view as? UITextView {
            kind = "UITextView"
            let content = area.text ?? ""
            text = content
            let font = area.font ?? (area.attributedText.length > 0
                ? area.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont : nil)
            self.font = font
            let needed = font.map { (content as NSString).size(withAttributes: [.font: $0]).width } ?? 0
            let available = area.bounds.width - area.textContainerInset.left - area.textContainerInset.right
                - 2 * area.textContainer.lineFragmentPadding
            let tall = font.map { area.bounds.height >= 1.8 * $0.lineHeight } ?? false
            wrapped = needed > available + 0.5 || tall
        } else {
            kind = String(describing: type(of: view))
            text = ""
            font = nil
            wrapped = false
        }
    }

    var description: String {
        "\(kind) 文字「\(text)」字号 \(font?.pointSize ?? 0) 行高 \(font?.lineHeight ?? 0) 框 \(frame)"
    }
}

/// 整窗渲染的 RGBA 像素（按点坐标取色）。
struct BindPhoneLayoutPixels {
    let width: Int
    let height: Int
    let scale: CGFloat
    private let bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        width = cg.width
        height = cg.height
        scale = CGFloat(cg.width) / max(image.size.width, 1)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: cg.width,
                height: cg.height,
                bitsPerComponent: 8,
                bytesPerRow: cg.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        guard drawn else { return nil }
        bytes = buffer
    }

    /// 点坐标 (x, y)（左上为原点）的 RGB。
    func rgb(_ px: CGFloat, _ py: CGFloat) -> [Int] {
        let column = min(max(Int(px * scale), 0), width - 1)
        let row = min(max(Int(py * scale), 0), height - 1)
        let index = (row * width + column) * 4
        return [Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2])]
    }

    static func distance(_ lhs: [Int], _ rhs: [Int]) -> Int {
        zip(lhs, rhs).map { abs($0 - $1) }.max() ?? 0
    }
}
