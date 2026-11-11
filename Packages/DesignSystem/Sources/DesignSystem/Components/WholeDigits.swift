import SwiftUI
import UIKit

// D10-1230 判据 1（QA-11）：订单号、金额、手机号 / 脱敏账号、流水号这类数字串，任何字号和宽度下都不在中间断开。
// 放不下时整段换到下一行、改上下排，或在框内横向滚动；不缩字、不截断。三端同一口径，改在共用件，所有页面一起生效。

/// 文字里不可拆的数字段：连续的数字连同其中的 `.` `,` `*`（脱敏「138****5678」是一整段）、紧挨在前的 `¥` / 正负号。
public enum CouliDigitRuns {
    public static func runs(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var prefix = ""
        func flush() {
            if current.contains(where: \.isNumber) {
                result.append(prefix + current)
            }
            current = ""
            prefix = ""
        }
        for character in text {
            if character.isNumber || (!current.isEmpty && ".,*".contains(character))
                || (current.isEmpty && character == "*") {
                current.append(character)
            } else {
                flush()
                if "¥￥-−+".contains(character) {
                    prefix = String(character)
                }
            }
        }
        flush()
        return result
    }

    /// 最宽一个数字段的单行宽（系统字体、等宽数字、给定字号与字重）；没有数字段时 0。
    public static func widest(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular) -> CGFloat {
        let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return runs(text).map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    }

    /// SwiftUI 字重 → UIKit 字重（只认本仓库用到的四档）。
    public static func uiWeight(_ weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .couliBold: .bold
        case .couliSemibold: .semibold
        case .couliMedium: .medium
        default: .regular
        }
    }
}

/// 含数字串的文字：最宽的数字段放得进可用宽时照常排（`content` 自己在空格 / 中文处折行，数字段整段换到下一行，不在中间断）；
/// 放不下时走 `overflow`（缺省：整串一行、在框内横向滚动，带截断提示，见 `CouliDigitsScroller`），不缩字、不截断。
/// 放得下时排版与直接放 `content` 完全一样（不出现渐隐和指示器）。
/// - `minimumWidth`：最宽数字段的单行宽（`CouliDigitRuns.widest`，须与 `content` 同字体）。
/// - `content` 里的测量（`couliTextProbe` 等）照常挂在文字上：横滑时报的是滚动内容里的文字框。
public struct CouliWholeDigits<Content: View, Overflow: View>: View {
    private let minimumWidth: CGFloat
    private let content: Content
    private let overflow: Overflow

    /// 自定排不下时的排法（如金额句：前后文字照常折行、金额单独一行横滑）。
    public init(minimumWidth: CGFloat, @ViewBuilder content: () -> Content, @ViewBuilder overflow: () -> Overflow) {
        self.minimumWidth = minimumWidth
        self.content = content()
        self.overflow = overflow()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            // 整串一行放得下：就是一行（理想宽 = 整串自然宽，外层按理想宽排版时与原样一致）
            content.fixedSize(horizontal: true, vertical: false)
            // 理想宽 = 最宽数字段（+1 容差）：可用宽放得下它就选这一支；实际排版时按可用宽折行，与原样一致
            content.frame(idealWidth: (minimumWidth + 1).rounded(.up))
            overflow
        }
    }
}

public extension CouliWholeDigits where Overflow == CouliDigitsScroller<Content> {
    /// 缺省排不下时整串一行框内横滑（带截断提示）。`probe`：有测量接收方时报 `<probe>.scrollHint`（指示器轨道框）。
    init(minimumWidth: CGFloat, probe: String? = nil, @ViewBuilder content: () -> Content) {
        let body = content()
        self.init(
            minimumWidth: minimumWidth,
            content: { body },
            overflow: { CouliDigitsScroller(probe: probe) { body } }
        )
    }
}

enum CouliDigitsScrollerMetric {
    /// 两端渐隐宽（末端渐隐到透明；在开头以外的位置时开头也渐隐）。
    static let fade: CGFloat = 16
    static let indicatorHeight: CGFloat = 3
    static let indicatorGap: CGFloat = 3
    static let thumbMinimum: CGFloat = 12
}

/// 放不下的数字串（D10-1265，三端同口径）：整串一行、框内横向滚动，从开头露出；有截断提示——后面还有内容时末端渐隐，
/// 下方一条横向滚动指示器（轨道 + 按可见比例的滑块，随滚动移动）。只在真的放不下时出现（放得下的走 `CouliWholeDigits` 前两支）。
/// 读屏：横滑条收成一个叶子元素，读出里面的整串文字（外层组合元素照常把它并进一句；文字本身读屏隐藏时没有可读内容）。
public struct CouliDigitsScroller<Content: View>: View {
    private let probe: String?
    private let content: Content
    @State private var offset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var viewport: CGFloat = 0
    private static var space: String {
        "couli.digits.scroller"
    }

    public init(probe: String? = nil, @ViewBuilder content: () -> Content) {
        self.probe = probe
        self.content = content()
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content
                .fixedSize(horizontal: true, vertical: true)
                .background(GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(Self.space))
                    Color.clear
                        .onAppear { track(frame) }
                        .onChange(of: frame) { track($0) }
                })
        }
        .coordinateSpace(name: Self.space)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { viewport = proxy.size.width }
                .onChange(of: proxy.size.width) { viewport = $0 }
        })
        .mask(fadeMask)
        .accessibilityElement(children: .combine)
        .padding(.bottom, CouliDigitsScrollerMetric.indicatorGap + CouliDigitsScrollerMetric.indicatorHeight)
        .overlay(alignment: .bottomLeading) { indicator }
    }

    private func track(_ frame: CGRect) {
        offset = max(0, -frame.minX)
        contentWidth = frame.width
    }

    private var overflows: Bool {
        viewport > 0 && contentWidth > viewport + 0.5
    }

    private var fadeMask: some View {
        let fade = CouliDigitsScrollerMetric.fade
        let leading = overflows && offset > 0.5
        let trailing = overflows && contentWidth - offset - viewport > 0.5
        return HStack(spacing: 0) {
            LinearGradient(colors: [Color.black.opacity(leading ? 0 : 1), .black], startPoint: .leading,
                           endPoint: .trailing)
                .frame(width: fade)
            Color.black
            LinearGradient(colors: [.black, Color.black.opacity(trailing ? 0 : 1)], startPoint: .leading,
                           endPoint: .trailing)
                .frame(width: fade)
        }
    }

    @ViewBuilder private var indicator: some View {
        if overflows {
            let thumb = max(viewport * viewport / contentWidth, CouliDigitsScrollerMetric.thumbMinimum)
            let progress = min(max(offset / (contentWidth - viewport), 0), 1)
            let track = ZStack(alignment: .leading) {
                Capsule().fill(.secondary).opacity(0.25)
                Capsule().fill(.secondary)
                    .frame(width: thumb)
                    .offset(x: (viewport - thumb) * progress)
            }
            .frame(width: viewport, height: CouliDigitsScrollerMetric.indicatorHeight)
            .accessibilityHidden(true)
            if let probe {
                track.couliProbe(probe + ".scrollHint", role: "scroll-hint")
            } else {
                track
            }
        }
    }
}

public extension View {
    /// D10-1223 按钮口径：光秃文字按钮（【复制】【全部提现】「未跟单？去找回」）在 `outlined` 时加 `border.control` 描边与内边距，
    /// 明确是按钮（大字号下字会换行、离开所在行，光字看不出能点）；命中区 ≥ 44 由调用方保证。`outlined` 为 false 时原样返回。
    @ViewBuilder
    func couliTextButtonOutline(_ outlined: Bool) -> some View {
        if outlined {
            padding(.horizontal, CouliSpacing.s2)
                .padding(.vertical, CouliSpacing.s1)
                .frame(minHeight: CouliHitTarget.minimum)
                .background(
                    RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                        .fill(CouliColor.backgroundSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                        .strokeBorder(CouliColor.borderControl, lineWidth: CouliComponentMetric.controlBorderWidth)
                )
        } else {
            self
        }
    }
}
