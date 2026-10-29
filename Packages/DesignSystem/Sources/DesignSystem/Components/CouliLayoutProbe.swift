import SwiftUI

/// 布局原始测量的接收方（APP-11v）：组件把实际布局框（屏幕坐标）、文字的无约束自然宽度与字号报给它。
///
/// 包里不写调试编译条件（AGENTS.md 硬规则 6），所以这里只是一个环境值钩子：默认 nil，组件什么也不量、不多画任何视图；
/// 只有 App 的调试场景入口（只在 Debug / Staging 编译）放进接收方，把记录序列化给 UI 测试。Release 制品里没有接收方，也没有调用方。
@MainActor
public final class CouliLayoutProbe {
    public let report: (CouliLayoutProbeRecord) -> Void
    public let remove: (String) -> Void
    /// 每个编号当前由哪一个视图实例上报：视图换实例（分支切换、懒加载行重建）时，旧实例晚到的「消失」不能删掉新实例的记录。
    private var owners: [String: UUID] = [:]

    func report(_ record: CouliLayoutProbeRecord, from owner: UUID) {
        owners[record.id] = owner
        report(record)
    }

    func remove(_ id: String, from owner: UUID) {
        guard owners[id] == owner else { return }
        owners[id] = nil
        remove(id)
    }

    /// 读屏焦点转移的接收方（APP-11v-b）：组件的 `AccessibilityFocusState` 变成「有焦点」时报控件编号；nil 时不报。
    public let focus: ((String) -> Void)?

    public init(report: @escaping (CouliLayoutProbeRecord) -> Void, remove: @escaping (String) -> Void,
                focus: ((String) -> Void)? = nil) {
        self.report = report
        self.remove = remove
        self.focus = focus
    }
}

/// 一条测量：只记录原始几何，不做任何「放得下 / 列数」之类的判定。
public struct CouliLayoutProbeRecord: Sendable, Equatable {
    public let id: String
    public let role: String
    public let card: String
    public let text: String
    /// 屏幕坐标的实际布局框。
    public let rect: CGRect
    /// 同一字体、字号、字重、等宽数字设置下，同一不可拆片段在无宽度约束时的宽度（非文字为 0）。
    public let naturalWidth: CGFloat
    /// 实际字号（非文字为 0）。
    public let fontSize: CGFloat
    /// 系统字号为「大」时的字号（非文字为 0）。
    public let baseFontSize: CGFloat

    public init(id: String, role: String, card: String = "", text: String = "", rect: CGRect,
                naturalWidth: CGFloat = 0, fontSize: CGFloat = 0, baseFontSize: CGFloat = 0) {
        self.id = id
        self.role = role
        self.card = card
        self.text = text
        self.rect = rect
        self.naturalWidth = naturalWidth
        self.fontSize = fontSize
        self.baseFontSize = baseFontSize
    }
}

public extension EnvironmentValues {
    /// 布局测量接收方；nil（默认、Release）时组件不量。
    @Entry var couliLayoutProbe: CouliLayoutProbe?
}

public extension View {
    /// 把这个视图的实际布局框报给测量接收方（没有接收方时原样返回，不加任何视图）。
    func couliProbe(_ id: String, role: String, card: String = "", text: String = "") -> some View {
        modifier(CouliProbeModifier(id: id, role: role, card: card, text: text, natural: 0, fontSize: 0, base: 0))
    }

    /// 文字的实际布局框连同实际字号上报（可换行的文字：缺省不量自然宽度）。`fontSize` 须是正在显示的文字所用字号。
    /// `naturalWidth`：调用方已按同一字体量好的单行自然宽度（APP-09v 钱包金额：放得下单行、放不下段内折行）；缺省 0 = 不报。
    func couliTextProbe(_ id: String, role: String, text: String, fontSize: CGFloat,
                        baseFontSize: CGFloat, naturalWidth: CGFloat = 0) -> some View {
        modifier(CouliProbeModifier(id: id, role: role, card: "", text: text, natural: naturalWidth,
                                    fontSize: fontSize, base: baseFontSize))
    }
}

public extension View {
    /// 把读屏焦点的转移报给接收方：`focused`（AccessibilityFocusState）变成 true，或组件把焦点移到这里的请求次数 `requests`
    /// 增加时报 `id`。没有接收方时什么也不做。
    ///
    /// 为什么也报请求：没有辅助技术（VoiceOver）运行时，系统忽略对 AccessibilityFocusState 的写入（实测值保持 false），
    /// UI 测试里只能看到生产组件「把焦点移到哪里」这一次写入；真实焦点转移仍须 VoiceOver 实机核对。
    func couliFocusProbe(_ id: String, focused: Bool, requests: Int = 0) -> some View {
        modifier(CouliFocusProbeModifier(id: id, focused: focused, requests: requests))
    }
}

struct CouliFocusProbeModifier: ViewModifier {
    @Environment(\.couliLayoutProbe) private var probe
    let id: String
    let focused: Bool
    let requests: Int

    func body(content: Content) -> some View {
        content
            .onAppear {
                if focused || requests > 0 {
                    probe?.focus?(id)
                }
            }
            .onChange(of: focused) { value in
                if value {
                    probe?.focus?(id)
                }
            }
            .onChange(of: requests) { _ in
                probe?.focus?(id)
            }
    }
}

struct CouliProbeModifier: ViewModifier {
    @Environment(\.couliLayoutProbe) private var probe
    @State private var instance = UUID()
    let id: String
    let role: String
    let card: String
    let text: String
    let natural: CGFloat
    let fontSize: CGFloat
    let base: CGFloat

    func body(content: Content) -> some View {
        if let probe {
            content
                .background(
                    GeometryReader { proxy in
                        let frame = proxy.frame(in: .global)
                        Color.clear
                            .onAppear { probe.report(record(frame), from: instance) }
                            .onChange(of: frame) { probe.report(record($0), from: instance) }
                            .onChange(of: natural) { _ in probe.report(record(frame), from: instance) }
                    }
                )
                .onDisappear { probe.remove(id, from: instance) }
        } else {
            content
        }
    }

    private func record(_ frame: CGRect) -> CouliLayoutProbeRecord {
        CouliLayoutProbeRecord(id: id, role: role, card: card, text: text, rect: frame, naturalWidth: natural,
                               fontSize: fontSize, baseFontSize: base)
    }
}

/// 不可拆的一段文字（金额、按钮字）：单行、不截断、不缩字（宽度按内容），字号随系统字号缩放。
/// 有测量接收方时另在背景放一份同字体的隐藏副本（无宽度约束）量自然宽度，连同实际框一起上报。
public struct CouliUnbreakableText: View {
    private let text: String
    private let base: CGFloat
    private let weight: Font.Weight
    private let monospacedDigits: Bool
    private let probeID: String?
    private let role: String
    private let card: String
    private let lineHeightMultiple: CGFloat
    private let measuredNatural: CGFloat?
    @ScaledMetric private var size: CGFloat
    @Environment(\.couliLayoutProbe) private var probe
    @State private var natural: CGFloat = 0

    /// - Parameters:
    ///   - size: 系统字号「大」时的字号；`relativeTo` 决定缩放曲线。
    ///   - probeID: 测量编号（nil 不上报）。
    ///   - lineHeightMultiple: 单行占位的行高倍数（缺省正文 1.5；详情大价 display 1.2、返利金额 title 1.3，APP-06v）。
    ///   - naturalWidth: 调用方已按同一字体量好的单行自然宽度（APP-06v 详情金额）；给了就直接上报它，不再放隐藏副本。
    public init(_ text: String, size: CGFloat, weight: Font.Weight = .regular, relativeTo: Font.TextStyle = .body,
                monospacedDigits: Bool = true, probeID: String? = nil, role: String = "", card: String = "",
                lineHeightMultiple: CGFloat = CouliTextStyle.body.lineHeightMultiple,
                naturalWidth: CGFloat? = nil) {
        self.text = text
        base = size
        self.weight = weight
        self.monospacedDigits = monospacedDigits
        self.probeID = probeID
        self.role = role
        self.card = card
        self.lineHeightMultiple = lineHeightMultiple
        measuredNatural = naturalWidth
        _size = ScaledMetric(wrappedValue: size, relativeTo: relativeTo)
    }

    private var font: Font {
        let font = Font.system(size: size, weight: weight)
        return monospacedDigits ? font.monospacedDigit() : font
    }

    public var body: some View {
        // 按令牌行高（缺省 1.5 倍）占位，与设计稿单行行高一致
        let label = Text(verbatim: text).font(font).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: (size * lineHeightMultiple).rounded())
        if let probeID, probe != nil, let measuredNatural {
            label
                .modifier(CouliProbeModifier(id: probeID, role: role, card: card, text: text, natural: measuredNatural,
                                             fontSize: size, base: base))
        } else if let probeID, probe != nil {
            label
                .background(alignment: .topLeading) {
                    Text(verbatim: text).font(font).lineLimit(1).fixedSize()
                        .hidden()
                        .background(GeometryReader { proxy in
                            Color.clear
                                .onAppear { natural = proxy.size.width }
                                .onChange(of: proxy.size.width) { natural = $0 }
                        })
                        .accessibilityHidden(true)
                }
                .modifier(CouliProbeModifier(id: probeID, role: role, card: card, text: text, natural: natural,
                                             fontSize: size, base: base))
        } else {
            label
        }
    }
}

public extension View {
    /// 可换行文字（按钮字等）的实际框、单行自然宽度与实际字号一起上报（APP-06v 购买按钮字）：有接收方时另放一份同字体、
    /// 不限宽的隐藏副本量单行宽度；没有接收方时原样返回，不加任何视图。`style` / `weight` 须与正在显示的文字一致。
    func couliTextNaturalProbe(_ id: String?, role: String, text: String, style: CouliTextStyle,
                               weight: Font.Weight = .regular) -> some View {
        modifier(CouliTextNaturalProbeModifier(id: id, role: role, text: text, style: style, weight: weight))
    }
}

struct CouliTextNaturalProbeModifier: ViewModifier {
    @Environment(\.couliLayoutProbe) private var probe
    @ScaledMetric private var size: CGFloat
    @State private var natural: CGFloat = 0
    let id: String?
    let role: String
    let text: String
    let style: CouliTextStyle
    let weight: Font.Weight

    init(id: String?, role: String, text: String, style: CouliTextStyle, weight: Font.Weight) {
        self.id = id
        self.role = role
        self.text = text
        self.style = style
        self.weight = weight
        _size = ScaledMetric(wrappedValue: style.baseSize, relativeTo: style.relativeTo)
    }

    func body(content: Content) -> some View {
        if let id, probe != nil {
            content
                .background(alignment: .topLeading) {
                    Text(verbatim: text).font(.system(size: size, weight: weight)).lineLimit(1).fixedSize()
                        .hidden()
                        .background(GeometryReader { proxy in
                            Color.clear
                                .onAppear { natural = proxy.size.width }
                                .onChange(of: proxy.size.width) { natural = $0 }
                        })
                        .accessibilityHidden(true)
                }
                .modifier(CouliProbeModifier(id: id, role: role, card: "", text: text, natural: natural,
                                             fontSize: size, base: style.baseSize))
        } else {
            content
        }
    }
}
