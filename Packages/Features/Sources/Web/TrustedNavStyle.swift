import BridgeHost
import Foundation

/// 可信容器标题栏的样式（ui.setNavBar；没设置过的取设计稿默认）。背景三选一：图片 > 渐变 > 纯色（后设置的同类字段覆盖先前的）。
public struct TrustedNavStyle: Equatable, Sendable {
    public static let statusBarDark = "dark"

    public var background: BridgeColor?
    public var gradient: [BridgeColor]?
    public var image: URL?
    public var text: BridgeColor?
    /// 沉浸式：页面内容延伸到标题栏与状态栏下面，标题栏浮在页面上。
    public var immersive = false
    /// 页面内容延伸到底部安全区。
    public var hideBottomSafeArea = false

    public init() {}

    func applying(_ bar: BridgeNavBar) -> TrustedNavStyle {
        var next = self
        if let color = bar.bgColor {
            next.background = color
            next.gradient = nil
            next.image = nil
        }
        if let colors = bar.bgGradient {
            next.gradient = colors
            next.image = nil
        }
        if let image = bar.bgImage {
            next.image = image
        }
        if let text = bar.textColor {
            next.text = text
        }
        if let immersive = bar.immersive {
            next.immersive = immersive
        }
        if let hide = bar.hideBottomSafeArea {
            next.hideBottomSafeArea = hide
        }
        return next
    }
}
