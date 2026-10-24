import SwiftUI

/// 首页金刚区类目图标与首页功能小图标（APP-11v G-V08：凑狸自有内容图标，照 Main-v3 / HomeGuest-v3 画板的 SVG 逐条转写，
/// 与 Android `CouliCategoryIcons`、鸿蒙同一组路径；24 视口、1.75 描边、圆头圆角，颜色由调用方的前景色给）。
/// 导航、搜索、关闭等功能图标仍用系统图标（`CouliIconView`）。
public enum CouliContentIcon: String, Sendable, CaseIterable {
    case supermarket
    case fresh
    case baby
    case beauty
    case household
    case electronics
    case guide
    /// 粘贴（剪贴板夹）。
    case paste
    /// 链接（粘贴卡插图）。
    case link

    /// 包内默认 / 服务端 `builtin:` 名称 → 类目图标；不认识的名字（含平台格 `platform.*`）返回 nil。
    public static func named(_ name: String) -> CouliContentIcon? {
        switch name {
        case "category.supermarket": .supermarket
        case "category.fresh": .fresh
        case "category.baby": .baby
        case "category.beauty": .beauty
        case "category.household": .household
        case "category.electronics": .electronics
        case "guide": .guide
        default: nil
        }
    }

    var paths: [String] {
        switch self {
        case .supermarket:
            ["M4 9.5h16l-1.6 9.1a1.5 1.5 0 0 1-1.5 1.2H7.1a1.5 1.5 0 0 1-1.5-1.2L4 9.5Z",
             "M8 9.5 10.5 4.5M16 9.5 13.5 4.5", "M9.5 13v3.5M14.5 13v3.5"]
        case .fresh:
            ["M12 8c-1.6-1.1-5.6-1.3-6.5 2.6-.8 3.6 1.5 9.4 4.3 9.4.9 0 1.4-.5 2.2-.5s1.3.5 2.2.5"
                + "c2.8 0 5.1-5.8 4.3-9.4C17.6 6.7 13.6 6.9 12 8Z", "M12 8c0-1.9.7-3.4 2.5-4.5"]
        case .baby:
            ["M10.5 6V4.5a1.5 1.5 0 0 1 3 0V6",
             "M8.5 6H15.5A1 1 0 0 1 16.5 7V8A1 1 0 0 1 15.5 9H8.5A1 1 0 0 1 7.5 8V7"
                 + "A1 1 0 0 1 8.5 6Z",
             "M8 9h8v9.5a2 2 0 0 1-2 2h-4a2 2 0 0 1-2-2V9Z", "M8 13h3M8 16h3"]
        case .beauty:
            ["M9 12.5H15A1.5 1.5 0 0 1 16.5 14V19A1.5 1.5 0 0 1 15 20.5H9A1.5 1.5 0 0 1 7.5 19V14"
                + "A1.5 1.5 0 0 1 9 12.5Z", "M9.5 12.5v-3h5v3", "M10.5 9.5V5.5l3-2.5v6.5"]
        case .household:
            ["M5.5 11.5V9a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v2.5",
             "M3.5 13a1.5 1.5 0 0 1 3 0v1.5h11V13a1.5 1.5 0 0 1 3 0v4.5h-17V13Z", "M6 17.5v2M18 17.5v2"]
        case .electronics:
            ["M5 4.5H19A1.5 1.5 0 0 1 20.5 6V14.5A1.5 1.5 0 0 1 19 16H5A1.5 1.5 0 0 1 3.5 14.5V6"
                + "A1.5 1.5 0 0 1 5 4.5Z", "M9 20h6M12 16v4"]
        case .guide:
            ["M12 6.5C10.5 5.3 8 4.8 4 5v13c4-.2 6.5.3 8 1.5 1.5-1.2 4-1.7 8-1.5V5c-4-.2-6.5.3-8 1.5Z", "M12 6.5v13"]
        case .paste:
            ["M8 5H16A2 2 0 0 1 18 7V18.5A2 2 0 0 1 16 20.5H8A2 2 0 0 1 6 18.5V7A2 2 0 0 1 8 5Z",
             "M9.5 5V4a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1v1"]
        case .link:
            ["M10.5 13.5a3.5 3.5 0 0 0 5 0l3-3a3.5 3.5 0 0 0-5-5l-.8.8",
             "M13.5 10.5a3.5 3.5 0 0 0-5 0l-3 3a3.5 3.5 0 0 0 5 5l.8-.8"]
        }
    }
}

/// 内容图标视图：24 视口按 `size` 等比缩放，描边 1.75（同比例），前景色由调用方给；装饰性，读屏隐藏。
public struct CouliContentIconView: View {
    private let icon: CouliContentIcon
    private let size: CGFloat

    public init(_ icon: CouliContentIcon, size: CGFloat = 24) {
        self.icon = icon
        self.size = size
    }

    public var body: some View {
        let scale = size / 24
        CouliSVGPathShape(paths: icon.paths)
            .stroke(style: StrokeStyle(lineWidth: 1.75 * scale, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 24 视口的 SVG 路径（M L H V C S Q A Z 及小写相对形式）→ 按实际框等比缩放的 Path。
struct CouliSVGPathShape: Shape {
    let paths: [String]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for data in paths {
            path.addPath(SVGPathParser.parse(data))
        }
        let scale = min(rect.width, rect.height) / 24
        return path.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// 极简 SVG 路径解析（只为上面固定的几条图标路径；圆弧换成三次贝塞尔）。
enum SVGPathParser {
    /// 各命令每组参数的个数。
    private static let arity: [Character: Int] = [
        "M": 2,
        "L": 2,
        "H": 1,
        "V": 1,
        "C": 6,
        "S": 4,
        "Q": 4,
        "A": 7,
        "Z": 0,
    ]

    static func parse(_ data: String) -> Path {
        var builder = SVGPathBuilder()
        var command: Character?
        var numbers: [CGFloat] = []
        func flush() {
            guard let current = command, let count = arity[Character(current.uppercased())] else { return }
            if count == 0 {
                builder.apply(current, [])
                return
            }
            var index = 0
            var active = current
            while index + count <= numbers.count {
                builder.apply(active, Array(numbers[index..<index + count]))
                index += count
                // M 后面的隐含参数组按 L 处理
                if active == "M" {
                    active = "L"
                } else if active == "m" {
                    active = "l"
                }
            }
        }
        for token in tokenize(data) {
            switch token {
            case let .command(next):
                flush()
                command = next
                numbers = []
            case let .number(value):
                numbers.append(value)
            }
        }
        flush()
        return builder.path
    }

    private enum Token {
        case command(Character)
        case number(CGFloat)
    }

    private static func tokenize(_ data: String) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        func flush() {
            if let value = Double(buffer) {
                tokens.append(.number(CGFloat(value)))
            }
            buffer = ""
        }
        for char in data {
            if char.isLetter {
                flush()
                tokens.append(.command(char))
            } else if char == "-" {
                flush()
                buffer = "-"
            } else if char == "." {
                if buffer.contains(".") {
                    flush()
                }
                buffer.append(char)
            } else if char.isNumber {
                buffer.append(char)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}

/// 按 SVG 命令逐组画路径（大写绝对、小写相对）。
private struct SVGPathBuilder {
    var path = Path()
    private var current = CGPoint.zero
    private var start = CGPoint.zero
    private var lastControl: CGPoint?

    private func point(_ px: CGFloat, _ py: CGFloat, relative: Bool) -> CGPoint {
        relative ? CGPoint(x: current.x + px, y: current.y + py) : CGPoint(x: px, y: py)
    }

    mutating func apply(_ command: Character, _ args: [CGFloat]) {
        let rel = command.isLowercase
        var control: CGPoint?
        switch command.uppercased() {
        case "M":
            current = point(args[0], args[1], relative: rel)
            start = current
            path.move(to: current)
        case "L":
            current = point(args[0], args[1], relative: rel)
            path.addLine(to: current)
        case "H":
            current = CGPoint(x: rel ? current.x + args[0] : args[0], y: current.y)
            path.addLine(to: current)
        case "V":
            current = CGPoint(x: current.x, y: rel ? current.y + args[0] : args[0])
            path.addLine(to: current)
        case "C":
            let c1 = point(args[0], args[1], relative: rel)
            control = point(args[2], args[3], relative: rel)
            current = point(args[4], args[5], relative: rel)
            path.addCurve(to: current, control1: c1, control2: control ?? current)
        case "S":
            let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
            control = point(args[0], args[1], relative: rel)
            current = point(args[2], args[3], relative: rel)
            path.addCurve(to: current, control1: c1, control2: control ?? current)
        case "Q":
            let quad = point(args[0], args[1], relative: rel)
            current = point(args[2], args[3], relative: rel)
            path.addQuadCurve(to: current, control: quad)
        case "A":
            let end = point(args[5], args[6], relative: rel)
            SVGArc(start: current, end: end, radii: CGSize(width: args[0], height: args[1]), rotation: args[2],
                   large: args[3] != 0, sweep: args[4] != 0).add(to: &path)
            current = end
        default:
            path.closeSubpath()
            current = start
        }
        lastControl = control
    }
}

/// SVG 端点式圆弧 → 中心式 → 每段不超过 90° 的三次贝塞尔。
private struct SVGArc {
    let start: CGPoint
    let end: CGPoint
    let radii: CGSize
    let rotation: CGFloat
    let large: Bool
    let sweep: Bool

    private struct Center {
        let cx: CGFloat
        let cy: CGFloat
        let rx: CGFloat
        let ry: CGFloat
        let theta: CGFloat
        let delta: CGFloat
    }

    func add(to path: inout Path) {
        guard abs(radii.width) > 0, abs(radii.height) > 0, start != end, let center = center() else {
            path.addLine(to: end)
            return
        }
        let phi = rotation * .pi / 180
        let segments = max(1, Int(ceil(abs(center.delta) / (.pi / 2))))
        let step = center.delta / CGFloat(segments)
        let kappa = 4 / 3 * tan(step / 4)
        func point(_ theta: CGFloat) -> CGPoint {
            CGPoint(x: center.cx + center.rx * cos(theta) * cos(phi) - center.ry * sin(theta) * sin(phi),
                    y: center.cy + center.rx * cos(theta) * sin(phi) + center.ry * sin(theta) * cos(phi))
        }
        func derivative(_ theta: CGFloat) -> CGPoint {
            CGPoint(x: -center.rx * sin(theta) * cos(phi) - center.ry * cos(theta) * sin(phi),
                    y: -center.rx * sin(theta) * sin(phi) + center.ry * cos(theta) * cos(phi))
        }
        var theta = center.theta
        for _ in 0..<segments {
            let next = theta + step
            let (p1, p2, d1, d2) = (point(theta), point(next), derivative(theta), derivative(next))
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + kappa * d1.x, y: p1.y + kappa * d1.y),
                          control2: CGPoint(x: p2.x - kappa * d2.x, y: p2.y - kappa * d2.y))
            theta = next
        }
    }

    private func center() -> Center? {
        var rx = abs(radii.width)
        var ry = abs(radii.height)
        let phi = rotation * .pi / 180
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1p = cos(phi) * dx + sin(phi) * dy
        let y1p = -sin(phi) * dx + cos(phi) * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda)
            ry *= sqrt(lambda)
        }
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        guard denominator > 0 else { return nil }
        let factor = sqrt(max(0, (rx * rx * ry * ry - denominator) / denominator)) * (large == sweep ? -1 : 1)
        let cxp = factor * rx * y1p / ry
        let cyp = -factor * ry * x1p / rx
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let sign: CGFloat = ux * vy - uy * vx < 0 ? -1 : 1
            let dot = (ux * vx + uy * vy) / (sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy))
            return sign * acos(min(1, max(-1, dot)))
        }
        let theta = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep, delta > 0 {
            delta -= 2 * .pi
        } else if sweep, delta < 0 {
            delta += 2 * .pi
        }
        return Center(cx: cos(phi) * cxp - sin(phi) * cyp + (start.x + end.x) / 2,
                      cy: sin(phi) * cxp + cos(phi) * cyp + (start.y + end.y) / 2,
                      rx: rx, ry: ry, theta: theta, delta: delta)
    }
}
