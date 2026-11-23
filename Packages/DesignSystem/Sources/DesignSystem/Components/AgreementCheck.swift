import SwiftUI

/// 协议勾选的圆形勾选框图形（登录协议行、实名同意、劳务协议、注销放弃余额共用；组件改一处，各页同步）。
///
/// 直径 18（随字号按 footnote 缩放），描边 1.5，勾为 SF Symbol checkmark（粗、直径的一半）。只画图、读屏隐藏：
/// 交互、命中区（≥ 44pt）、读屏名称与状态都由调用方的行给，各页保持自己的读屏文案与标识。
///
/// 可用态沿用收款页设计稿 RealNameConsent-v2 / LaborAgreement-v2 的原画法（勾选品牌色实心 + 面色勾，未勾面色底 + 控件边）；
/// 禁用态照安卓 CouliSelection.kt `CheckboxGlyph`：勾选用主按钮禁用底 + 禁用字色勾，未勾用弱底 + 细边。
public struct CouliCheckGlyph: View {
    /// 基准直径（未缩放），调用方对齐下一行文字缩进时用。
    public static let baseSize: CGFloat = 18
    /// 描边宽度。
    public static let strokeWidth: CGFloat = 1.5

    private let checked: Bool
    private let enabled: Bool
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = CouliCheckGlyph.baseSize

    public init(checked: Bool, enabled: Bool = true) {
        self.checked = checked
        self.enabled = enabled
    }

    public var body: some View {
        ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(ring, lineWidth: Self.strokeWidth)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: size / 2, weight: .bold))
                    .foregroundColor(mark)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// 填色。button.primary.disabled.* 在 CouliColor 里没有静态属性，经 token 取（与 CouliButton 同法）。
    private var fill: Color {
        switch (checked, enabled) {
        case (true, true): CouliColor.brandPrimary
        case (false, true): CouliColor.backgroundSurface
        case (true, false): CouliColor.token("button.primary.disabled.background")
        case (false, false): CouliColor.backgroundMuted
        }
    }

    /// 描边色（勾选时与填色相同，看不出边）。
    private var ring: Color {
        switch (checked, enabled) {
        case (true, true): CouliColor.brandPrimary
        case (false, true): CouliColor.borderControl
        case (true, false): CouliColor.token("button.primary.disabled.background")
        case (false, false): CouliColor.borderSubtle
        }
    }

    /// 勾的颜色（只在勾选时画）。
    private var mark: Color {
        enabled ? CouliColor.backgroundSurface : CouliColor.token("button.primary.disabled.text")
    }
}
