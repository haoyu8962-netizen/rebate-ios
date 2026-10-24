import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 系统粘贴控件（iOS 16 UIPasteControl，经 UIViewRepresentable 嵌进 SwiftUI；BR-ID-16、CAP-X-02「UIPasteControl 免提示」）。
/// 文字与读屏名由系统提供（「粘贴」），旁边的说明文字由调用方放。用户点了它，系统才把剪贴板内容交给接收方——不出现系统「允许粘贴」
/// 弹窗；接收方只收纯文本与 URL（`UIPasteConfiguration`）。读到的文本只交给 `onBegin` 返回的交付回调，本组件不保存。
/// `isEnabled = false` 时控件置灰、也不交回任何内容（42901 限流、在途等，执行层另有拦截）。
///
/// 系统交付文本是异步的（NSItemProvider）：用户点击时 UIKit 同步调接收方，组件此刻调 `onBegin`，调用方在这里捕获发起页、世代等票据并返回
/// 交付回调（nil = 这次点击不读）；文本到达后只交给这个回调，由它复核票据、失效即丢弃（APP-07 共性第 28 条），不用交付时的「当前页」
/// 重新归属。
public struct SystemPasteControl: UIViewRepresentable {
    public enum Style: Sendable {
        /// 白底胶囊、品牌色字（首页提示条、首页「去粘贴」卡）。
        case capsule
        /// 品牌浅底、品牌色字、图标 + 文字（SearchTyping 整行入口）。
        case tinted
        /// 只有文字（登录页邀请码行的文字链位置）。
        case plain
        /// 主按钮：品牌主色底、白字、图标 + 文字、胶囊（首页常驻粘贴卡，Main-v3 / HomeGuest-v3；APP-11v）。
        case primary
    }

    let style: Style
    let isEnabled: Bool
    let identifier: String
    let onBegin: @MainActor () -> PasteDelivery?

    public init(
        style: Style = .capsule,
        isEnabled: Bool = true,
        identifier: String,
        onBegin: @escaping @MainActor () -> PasteDelivery?
    ) {
        self.style = style
        self.isEnabled = isEnabled
        self.identifier = identifier
        self.onBegin = onBegin
    }

    public func makeUIView(context _: Context) -> PasteReceiverView {
        PasteReceiverView(configuration: Self.configuration(style))
    }

    public func updateUIView(_ view: PasteReceiverView, context _: Context) {
        view.onBegin = onBegin
        view.setEnabled(isEnabled)
        view.control.accessibilityIdentifier = identifier
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasteReceiverView, context _: Context) -> CGSize? {
        let natural = uiView.control.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 200))
        // 系统安全控件放不下文字时不绘制内容（只剩底色）：最小尺寸随字号放大（intrinsicContentSize 首次布局时可能还是 0）
        let traits = uiView.traitCollection
        let minWidth = UIFontMetrics.default.scaledValue(for: Self.minimumWidth, compatibleWith: traits)
        let height = max(
            natural.height,
            UIFontMetrics.default.scaledValue(for: CouliHitTarget.minimum, compatibleWith: traits)
        )
        if style == .primary {
            // 首页粘贴卡主按钮：命中区下限 44 再留 1pt（所在卡可能落在非整像素位置，量出的高度不因舍入低于 44）
            return CGSize(width: max(natural.width, minWidth), height: max(height, CouliHitTarget.minimum + 1))
        }
        if style == .tinted, let width = proposal.width, width.isFinite {
            return CGSize(width: width, height: max(height, CouliComponentMetric.buttonMinHeight))
        }
        return CGSize(width: max(natural.width, minWidth), height: height)
    }

    /// 胶囊 / 文字样式的最小宽度（pt）：intrinsicContentSize 首次布局时可能还是 0。
    static let minimumWidth: CGFloat = 72

    static func configuration(_ style: Style) -> UIPasteControl.Configuration {
        let configuration = UIPasteControl.Configuration()
        switch style {
        case .capsule:
            configuration.displayMode = .labelOnly
            configuration.cornerStyle = .capsule
            configuration.baseBackgroundColor = UIColor(CouliColor.backgroundSurface)
            configuration.baseForegroundColor = UIColor(CouliColor.brandEmphasis)
        case .tinted:
            configuration.displayMode = .iconAndLabel
            configuration.cornerStyle = .medium
            configuration.baseBackgroundColor = UIColor(CouliColor.brandSubtle)
            configuration.baseForegroundColor = UIColor(CouliColor.brandEmphasis)
        case .plain:
            configuration.displayMode = .labelOnly
            configuration.cornerStyle = .capsule
            configuration.baseBackgroundColor = UIColor(CouliColor.backgroundMuted)
            configuration.baseForegroundColor = UIColor(CouliColor.textLink)
        case .primary:
            configuration.displayMode = .iconAndLabel
            configuration.cornerStyle = .capsule
            configuration.baseBackgroundColor = UIColor(CouliColor.brandPrimary)
            configuration.baseForegroundColor = UIColor(CouliColor.textInverse)
        }
        return configuration
    }
}

/// 系统粘贴的交付回调（点击时由调用方给出，绑定点击时的票据）。
public typealias PasteDelivery = @MainActor (String?) -> Void

/// UIPasteControl 的接收方（`UIPasteConfigurationSupporting`）：只收纯文本与 URL，取第一项交回点击时拿到的交付回调。
public final class PasteReceiverView: UIView {
    let control: UIPasteControl
    var onBegin: (@MainActor () -> PasteDelivery?)?

    init(configuration: UIPasteControl.Configuration) {
        control = UIPasteControl(configuration: configuration)
        super.init(frame: .zero)
        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [UTType.plainText.identifier, UTType.url.identifier]
        )
        control.target = self
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    func setEnabled(_ enabled: Bool) {
        control.isEnabled = enabled
        control.target = enabled ? self : nil
    }

    override public func canPaste(_: [NSItemProvider]) -> Bool {
        control.isEnabled
    }

    override public func paste(itemProviders: [NSItemProvider]) {
        guard control.isEnabled, let provider = itemProviders.first,
              let delivery = onBegin?() else { return }
        // 系统在后台队列回调：显式 @Sendable，回到主线程再交给点击时拿到的回调。回调随交付持有，不依赖本视图还在
        // （提示条点击后即收起，视图可能先释放；调用方的忙碌状态要等到交付或作废才解除）
        let box = PasteDeliveryBox(delivery)
        let deliver: @Sendable (String?) -> Void = { text in
            Task { @MainActor in box.deliver(text) }
        }
        if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { @Sendable text, _ in deliver(text) }
        } else if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in deliver(url?.absoluteString) }
        } else {
            deliver(nil)
        }
    }
}

/// 点击时拿到的交付回调：只在主线程取用，最多交付一次。
private final class PasteDeliveryBox: @unchecked Sendable {
    private var delivery: PasteDelivery?

    init(_ delivery: @escaping PasteDelivery) {
        self.delivery = delivery
    }

    @MainActor
    func deliver(_ text: String?) {
        let once = delivery
        delivery = nil
        once?(text)
    }
}
