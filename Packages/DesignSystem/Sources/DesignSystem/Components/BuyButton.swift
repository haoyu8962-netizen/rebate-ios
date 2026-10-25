import SwiftUI

// MARK: - BuyButton

/// BuyButton 状态。loading、禁用与「稍后再试」不拼返利后缀（BR-TEXT-14 表 C）。
public enum BuyButtonState: Sendable, Equatable {
    case normal
    case loading
    case disabled
    /// 稍后再试：显示调用方给的文案（如 error.* 字典句），按钮不可点。
    case retryLater(String)
}

/// 购买按钮：动词由调用方给（cta.text_key 对应的字典文案）；`BuyButtonModel` 决定是否拼「· 预估返 ¥x」。
public struct BuyButton: View {
    private let base: String
    private let rebate: RebateTagContent
    private let amountHidden: Bool
    private let context: BuyButtonContext
    private let state: BuyButtonState
    private let size: CouliButtonSize
    private let fillsWidth: Bool
    private let labelProbeID: String?
    private let action: () -> Void

    public init(
        base: String,
        rebate: RebateTagContent,
        amountHidden: Bool = false,
        context: BuyButtonContext,
        state: BuyButtonState = .normal,
        size: CouliButtonSize = .compact,
        fillsWidth: Bool = false,
        labelProbeID: String? = nil,
        action: @escaping () -> Void
    ) {
        self.labelProbeID = labelProbeID
        self.base = base
        self.rebate = rebate
        self.amountHidden = amountHidden
        self.context = context
        self.state = state
        self.size = size
        self.fillsWidth = fillsWidth
        self.action = action
    }

    private var title: String {
        switch state {
        case .normal:
            BuyButtonModel.text(base: base, rebate: rebate, amountHidden: amountHidden, context: context.rawValue)
        case .loading, .disabled:
            base
        case let .retryLater(text):
            text
        }
    }

    private var label: String {
        switch state {
        case .normal:
            BuyButtonModel.accessibilityLabel(
                base: base,
                rebate: rebate,
                amountHidden: amountHidden,
                context: context.rawValue
            )
        case .loading, .disabled:
            base
        case let .retryLater(text):
            text
        }
    }

    public var body: some View {
        CouliButton(
            title,
            kind: .primary,
            size: size,
            isLoading: state == .loading,
            isEnabled: state == .normal,
            fillsWidth: fillsWidth,
            accessibilityLabel: label,
            labelProbeID: labelProbeID,
            action: action
        )
    }
}
