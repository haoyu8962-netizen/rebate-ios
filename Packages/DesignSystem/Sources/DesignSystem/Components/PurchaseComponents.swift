import SwiftUI

// MARK: - 购买流程用到的通用块（APP-06b；设计稿 ProductBuyOpening、ProductBuyTimeout、ProductJumpBrowser）

/// 可取消的进度面板（ProductBuyOpening「正在打开淘宝」+【取消】、ProductJumpBrowser「将通过浏览器打开京东」+【取消】）：居中白卡、
/// 转圈 + 标题 + 文字按钮。只写平台名，不显示金额。读屏焦点进标题。
public struct ProgressPanel: View {
    private let title: String
    private let cancelTitle: String
    private let onCancel: () -> Void
    @AccessibilityFocusState private var titleFocused: Bool

    public init(title: String, cancelTitle: String, onCancel: @escaping () -> Void) {
        self.title = title
        self.cancelTitle = cancelTitle
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: CouliSpacing.s3) {
            ProgressView()
                .accessibilityHidden(true)
            Text(verbatim: title)
                .couliFont(.body, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
            CouliButton(cancelTitle, kind: .text, size: .compact, action: onCancel)
        }
        .padding(.horizontal, CouliSpacing.s6)
        .padding(.vertical, CouliSpacing.s5)
        .frame(minWidth: 200)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous).fill(CouliColor.backgroundSurface)
                .couliShadow(.floating)
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            titleFocused = true
        }
    }
}

/// 页内错误条 + 文字按钮（ProductBuyTimeout「网络不稳定，请重试」+【重试】）：错误底色、警示图标、正文可换行，按钮放不下时换行靠右。
/// 出现时礼貌播报正文（adaptation-a11y-spec §10）。
public struct RetryBanner: View {
    private let message: String
    private let retryTitle: String
    private let isEnabled: Bool
    private let onRetry: () -> Void

    public init(message: String, retryTitle: String, isEnabled: Bool = true, onRetry: @escaping () -> Void) {
        self.message = message
        self.retryTitle = retryTitle
        self.isEnabled = isEnabled
        self.onRetry = onRetry
    }

    public var body: some View {
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s1) {
            HStack(alignment: .firstTextBaseline, spacing: CouliSpacing.s2) {
                CouliIconView(.alert, size: CouliComponentMetric.iconMedium, relativeTo: .footnote)
                    .accessibilityHidden(true)
                Text(verbatim: message)
                    .couliFont(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(CouliColor.statusErrorText)
            CouliButton(retryTitle, kind: .text, size: .compact, isEnabled: isEnabled, action: onRetry)
        }
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.vertical, CouliSpacing.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(CouliColor.token("status.error.background"))
        )
        .accessibilityElement(children: .contain)
        .task(id: message) {
            ToastAnnouncement.post(message)
        }
    }
}

/// 弹窗里的提示框（ProductPriceChangedRebateGone「该商品当前暂无返利 / 继续购买不会获得返利」）：警示底色、图标 + 标题 + 说明。
public struct NoticeBox: View {
    private let title: String
    private let message: String?

    public init(title: String, message: String? = nil) {
        self.title = title
        self.message = message
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CouliSpacing.s2) {
            CouliIconView(.alert, size: CouliComponentMetric.iconMedium, relativeTo: .footnote)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                Text(verbatim: title)
                    .couliFont(.footnote, weight: .couliSemibold)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(verbatim: message)
                        .couliFont(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundColor(CouliColor.statusWarningText)
        .padding(CouliSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(CouliColor.token("status.warning.background"))
        )
        .accessibilityElement(children: .combine)
    }
}
