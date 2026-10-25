import SwiftUI
import UIKit

// MARK: - EmptyState / ErrorState

/// 空态（GUIDE §3「空态 / 错误态」）：96 占位块 + 32 图标 → 说明 17/600 → 辅助 14 → 一个按钮（可省）。
public struct EmptyState: View {
    private let icon: CouliIcon
    private let title: String
    private let message: String?
    private let actionTitle: String?
    private let action: () -> Void

    public init(
        icon: CouliIcon = .search,
        title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        action: @escaping () -> Void = {}
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        StateLayout(icon: icon, title: title, message: message, actionTitle: actionTitle, action: action)
    }
}

/// 错误态：同空态结构，三角图标。出现时立即播报「标题，说明」，播报完把读屏焦点移到【重试】
/// （adaptation-a11y-spec §10「加载失败：立即读，焦点到【重试】」）。
/// 先播报再移焦：移焦会打断正在读的播报，所以等系统的「播报结束」通知（只认本错误态那一条）再移；
/// 通知没来时按兜底时长移焦；读屏没开时不等。规则见 `ErrorStateFocusCoordinator`。
public struct ErrorState: View {
    private let title: String
    private let message: String?
    private let retryTitle: String
    private let retry: () -> Void
    @AccessibilityFocusState private var retryFocused: Bool
    @State private var coordinator = ErrorStateFocusCoordinator()

    public init(title: String, message: String? = nil, retryTitle: String, retry: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.retryTitle = retryTitle
        self.retry = retry
    }

    private var announcement: String {
        ErrorStateFocusCoordinator.announcement(title: title, message: message)
    }

    public var body: some View {
        StateLayout(
            icon: .alert,
            title: title,
            message: message,
            actionTitle: retryTitle,
            action: retry,
            actionFocus: $retryFocused
        )
        // 标题 / 说明变化（换了一次错误）视为新的错误态：重新播报、重新移焦；同一错误重绘不重复。
        .task(id: announcement) {
            let effects = coordinator.appear(
                announcement: announcement,
                voiceOverRunning: UIAccessibility.isVoiceOverRunning
            )
            apply(effects)
            guard coordinator.isWaitingForAnnouncement else {
                return
            }
            try? await Task.sleep(nanoseconds: ErrorStateFocusCoordinator.fallbackDelayNanos)
            guard !Task.isCancelled else {
                return
            }
            apply(coordinator.fallbackElapsed())
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.announcementDidFinishNotification)) {
            let finished = $0.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String
            apply(coordinator.announcementFinished(finished))
        }
    }

    private func apply(_ effects: [ErrorStateFocusCoordinator.Effect]) {
        for effect in effects {
            switch effect {
            case let .announce(text):
                // 默认（非排队）播报：立即读，打断当前朗读。
                UIAccessibility.post(notification: .announcement, argument: text)
            case .focusRetry:
                retryFocused = true
            }
        }
    }
}

/// ErrorState 的播报与移焦顺序（纯逻辑，单测覆盖）：
/// 1. 出现（或换成新的错误内容）：播报一次「标题，说明」；读屏没开时同时移焦（无需等待）。
/// 2. 读屏开着：等本条播报的「播报结束」通知再移焦到【重试】（不认别的播报的结束通知）；
///    通知丢失时兜底时长到了也移焦。移焦只做一次，之后的通知 / 兜底都不再动焦点。
/// 3. 同一内容重绘不重复播报、不重复移焦。
struct ErrorStateFocusCoordinator: Equatable {
    enum Effect: Equatable {
        case announce(String)
        case focusRetry
    }

    enum Phase: Equatable {
        case idle
        case waitingForAnnouncement(String)
        case focused(String)
    }

    /// 兜底：播报结束通知迟迟不来时（被系统丢弃等），过这么久也把焦点移到【重试】。
    static let fallbackDelayNanos: UInt64 = 8_000_000_000

    private(set) var phase: Phase = .idle

    static func announcement(title: String, message: String?) -> String {
        [title, message].compactMap(\.self).joined(separator: PriceTerms.spokenPause)
    }

    var isWaitingForAnnouncement: Bool {
        if case .waitingForAnnouncement = phase {
            return true
        }
        return false
    }

    mutating func appear(announcement: String, voiceOverRunning: Bool) -> [Effect] {
        switch phase {
        case let .waitingForAnnouncement(current) where current == announcement:
            return []
        case let .focused(current) where current == announcement:
            return []
        default:
            break
        }
        if voiceOverRunning {
            phase = .waitingForAnnouncement(announcement)
            return [.announce(announcement)]
        }
        phase = .focused(announcement)
        return [.announce(announcement), .focusRetry]
    }

    mutating func announcementFinished(_ finished: String?) -> [Effect] {
        guard case let .waitingForAnnouncement(current) = phase, finished == current else {
            return []
        }
        phase = .focused(current)
        return [.focusRetry]
    }

    mutating func fallbackElapsed() -> [Effect] {
        guard case let .waitingForAnnouncement(current) = phase else {
            return []
        }
        phase = .focused(current)
        return [.focusRetry]
    }
}

private struct StateLayout: View {
    let icon: CouliIcon
    let title: String
    let message: String?
    let actionTitle: String?
    let action: () -> Void
    /// 按钮的读屏焦点绑定（ErrorState 用来把焦点移到【重试】）；nil 时不绑定。
    var actionFocus: AccessibilityFocusState<Bool>.Binding?

    var body: some View {
        VStack(spacing: CouliSpacing.s3) {
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(CouliColor.backgroundMuted)
                .frame(width: CouliGuideMetric.emptyIllustration, height: CouliGuideMetric.emptyIllustration)
                .overlay(
                    CouliIconView(icon, size: CouliGuideMetric.emptyIcon)
                        .foregroundColor(CouliColor.textSecondary)
                )
                .accessibilityHidden(true)
                .padding(.bottom, CouliSpacing.s3)
            VStack(spacing: CouliSpacing.s1) {
                Text(verbatim: title)
                    .couliFont(.body, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(verbatim: message)
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                CouliButton(actionTitle, kind: .secondary, action: action)
                    .modifier(OptionalAccessibilityFocus(binding: actionFocus))
                    .padding(.top, CouliSpacing.s2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CouliSpacing.s8)
        .padding(.horizontal, CouliSpacing.s4)
    }
}

/// 有绑定时挂 `accessibilityFocused`，没有时原样返回。
private struct OptionalAccessibilityFocus: ViewModifier {
    let binding: AccessibilityFocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let binding {
            content.accessibilityFocused(binding)
        } else {
            content
        }
    }
}

// MARK: - Skeleton

/// 骨架块：中性浅底、小圆角（GUIDE §3「骨架屏」）。读屏忽略，容器另给「加载中」状态。
public struct SkeletonBlock: View {
    private let width: CGFloat?
    private let height: CGFloat

    public init(width: CGFloat? = nil, height: CGFloat) {
        self.width = width
        self.height = height
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous)
            .fill(CouliColor.backgroundMuted)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// 列表商品卡骨架（GUIDE §3「搜索结果加载骨架」）：白卡 + 96 图片块 + 右栏三条（100% / 70% / 40%）+ 右下按钮块 88×36。
public struct ProductCardSkeleton: View {
    private let accessibilityLabel: String

    /// - Parameter accessibilityLabel: 容器读屏名称（「加载中」类字典文案）。
    public init(accessibilityLabel: String) {
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            HStack(alignment: .top, spacing: CouliSpacing.s3) {
                SkeletonBlock(width: CouliGuideMetric.listImage, height: CouliGuideMetric.listImage)
                GeometryReader { proxy in
                    VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                        SkeletonBlock(width: proxy.size.width, height: CouliSpacing.s4)
                        SkeletonBlock(width: proxy.size.width * 0.7, height: CouliSpacing.s4)
                        SkeletonBlock(width: proxy.size.width * 0.4, height: CouliSpacing.s6)
                    }
                }
                .frame(height: CouliGuideMetric.listImage)
            }
            HStack {
                Spacer()
                SkeletonBlock(width: CouliSpacing.s16 + CouliSpacing.s6, height: CouliSpacing.s8 + CouliSpacing.s1)
            }
        }
        .couliCard(padding: CouliSpacing.s3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }
}

// MARK: - Toast

/// 页顶轻提示（复制、保存等）：白底浮层阴影、墨棕字、左侧 20 图标（按类型，缺省成功勾）；出现时礼貌播报同文（adaptation-a11y-spec §10）。
public struct Toast: View {
    private let message: String
    private let icon: CouliToastIcon

    public init(_ message: String, icon: CouliToastIcon = .success) {
        self.message = message
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: CouliSpacing.s2) {
            if let symbol = icon.icon {
                CouliIconView(symbol, size: CouliGuideMetric.iconMedium, relativeTo: .footnote)
                    .foregroundColor(icon.color)
            }
            Text(verbatim: message)
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.vertical, CouliSpacing.s3)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous).fill(CouliColor.backgroundSurface)
                .couliShadow(.floating)
        )
        .accessibilityElement(children: .combine)
    }
}

/// 一次轻提示请求。每次 `init` 生成新 `id`：同一段文字再提示一次也是新请求（会重新计时、重新播报）。
public struct CouliToastMessage: Equatable, Sendable {
    public let id: UUID
    public let text: String
    /// 左侧图标类型（缺省成功勾，既有调用不变）。
    public let icon: CouliToastIcon

    public init(_ text: String) {
        self.init(text, icon: .success)
    }

    public init(_ text: String, icon: CouliToastIcon) {
        id = UUID()
        self.text = text
        self.icon = icon
    }
}

/// Toast 的播报规则（adaptation-a11y-spec §10）：首次出现、显示期间换成新内容、同文再提示一次，都播报一次；
/// 同一个请求（id 不变）重绘不重复播报；置空不播报。
enum ToastAnnouncement {
    static func text(previous: CouliToastMessage?, current: CouliToastMessage?) -> String? {
        guard let current, current.id != previous?.id else {
            return nil
        }
        return current.text
    }

    /// 礼貌播报：排队等当前朗读结束，不打断。
    @MainActor static func post(_ text: String) {
        let announcement = NSAttributedString(
            string: text,
            attributes: [.accessibilitySpeechQueueAnnouncement: true]
        )
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var message: CouliToastMessage?
    let duration: TimeInterval
    /// 额外下移（让出盖在同一页面里的导航栏，APP-06v-b：轻提示在导航栏下约 8）。
    let topInset: CGFloat
    /// 上一次已播报的请求（同一请求重绘、视图重挂时不重复播报）。
    @State private var announced: CouliToastMessage?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message {
                Toast(message.text, icon: message.icon)
                    .padding(.horizontal, CouliSpacing.s4)
                    .padding(.top, CouliSpacing.s2 + topInset)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    // id 变化（首次出现、换内容、同文再提示）都会重跑：播报一次并重新计时。
                    .task(id: message.id) {
                        if let text = ToastAnnouncement.text(previous: announced, current: message) {
                            announced = message
                            ToastAnnouncement.post(text)
                        }
                        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                        if self.message?.id == message.id {
                            self.message = nil
                        }
                    }
            }
        }
        .animation(.easeInOut, value: message)
    }
}

public extension View {
    /// 页顶轻提示；`message` 置非空即显示，`duration` 秒后自动消失。显示期间再置一个新的 `CouliToastMessage`
    /// （不论文字是否相同）会换内容、重新计时并重新播报。
    /// `topInset`：页顶有自绘导航栏时让出它的高度（缺省 0，既有调用不变）。
    func couliToast(_ message: Binding<CouliToastMessage?>, duration: TimeInterval = 2,
                    topInset: CGFloat = 0) -> some View {
        modifier(ToastModifier(message: message, duration: duration, topInset: topInset))
    }
}
