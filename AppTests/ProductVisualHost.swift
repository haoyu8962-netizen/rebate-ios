@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Router
import SwiftUI
import UIKit
import XCTest

/// 布局测量接收方（APP-11v 的 `couliLayoutProbe` 环境钩子）：测试直接收生产组件上报的实际框、自然宽度与字号。
@MainActor
final class ProductVisualProbes {
    private(set) var records: [String: CouliLayoutProbeRecord] = [:]
    lazy var probe = CouliLayoutProbe(
        report: { [weak self] in self?.records[$0.id] = $0 },
        remove: { [weak self] in self?.records[$0] = nil }
    )

    subscript(_ id: String) -> CouliLayoutProbeRecord? {
        records[id]
    }

    func rect(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        try XCTUnwrap(records[id], "缺测量 \(id)（§2 测量桥）", file: file, line: line).rect
    }

    func ids(prefix: String) -> [String] {
        records.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
}

/// 真实 App 组装的商品详情页（APP-06v）：OrdersAppFixture（已登录 user-a，本地 AppStubProtocol 假服务）→ AppTrade → AppSearch →
/// Router 打开 ProductDetail → 生产的 `ProductDetailRouteView`（含购买浮层、待跟单槽）。测试只换网络、图片与测量接收方，不重画页面。
@MainActor
final class ProductVisualHost {
    enum Reply {
        case card([String: Any])
        case error(Int)
        case hold
    }

    struct Canvas {
        var width: CGFloat = 390
        var height: CGFloat = 956
        var dark = false
        var size: DynamicTypeSize = .large
        /// 安全区：画板顶部 54 是状态栏、底栏下 34 是 iPhone 主屏指示条。
        var top: CGFloat = 54
        var bottom: CGFloat = 34
    }

    let fixture: OrdersAppFixture
    let trade: AppTrade
    let search: AppSearch
    let destination: RouteDestination
    let probes = ProductVisualProbes()
    private(set) var window: UIWindow?
    private(set) var canvas = Canvas()
    private var hidden: [UIWindow] = []

    /// - Parameter statuses: 平台购买状态（`AppTrade.overrides`，等同点击结果确认的 50301；`on` / `maintenance` / `not_launched`）。
    init(suiteName: String, defaults: UserDefaults, platform: String, productKey: String, reply: Reply,
         statuses: [String: String] = [:]) throws {
        let body: String? = switch reply {
        case let .card(card): ProductVisualCards.envelope(card)
        case let .error(code): ProductVisualCards.errorEnvelope(code)
        case .hold: nil
        }
        AppStubProtocol.install(Self.answer(body))
        fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        let runner = fixture.runner
        trade = AppTrade(
            network: fixture.network, config: fixture.config, privacy: fixture.privacy, routing: fixture.routing,
            login: fixture.login, credentialsReadable: { runner.credentialsReadable }, track: { _, _ in }
        )
        for (code, status) in statuses {
            trade.overrides.mark(code, status: status)
        }
        search = AppSearch(network: fixture.network, config: fixture.config, privacy: fixture.privacy,
                           routing: fixture.routing, trade: trade, restorationDefaults: defaults,
                           credentialsReadable: { runner.credentialsReadable })
        search.orders = fixture.orders
        let router = fixture.routing.router
        router.open(RouteRequest(
            route: "ProductDetail", values: ["platform": .string(platform), "product_key": .string(productKey)],
            from: .inApp
        ))
        destination = try XCTUnwrap(router.path.last)
    }

    /// 假服务（在网络线程执行，不能带主线程隔离）：getProduct 回指定包或挂起，其余请求回空成功。
    private nonisolated static func answer(_ body: String?) -> @Sendable (AppStubProtocol.Recorded) -> AppStubProtocol
        .Reply {
        { request in
            guard request.path.hasPrefix("/v1/products/"), !request.path.hasPrefix("/v1/products/search") else {
                return .json(status: 200, body: "{\"code\":0,\"msg\":\"\",\"data\":{},\"trace_id\":\"t\"}")
            }
            guard let body else { return .hold }
            return .json(status: 200, body: body)
        }
    }

    /// 用一张 visualCards 卡建页面（getProduct 回这张卡）。
    convenience init(suiteName: String, defaults: UserDefaults, card: [String: Any],
                     statuses: [String: String] = [:]) throws {
        try self.init(suiteName: suiteName, defaults: defaults, platform: card["platform"] as? String ?? "",
                      productKey: card["product_key"] as? String ?? "", reply: .card(card), statuses: statuses)
    }

    /// 挂上真实窗口（独立 UIWindow + 安全区），等页面结算。
    func show(_ canvas: Canvas = Canvas()) async {
        close()
        self.canvas = canvas
        ProductVisualImages.reset()
        let root = ProductDetailRouteView(destination: destination)
            .environmentObject(search)
            // 安全区按画板固定（顶 54 状态栏、底 34 主屏指示条）：宿主场景窗口自带的系统安全区随模拟器机型变，先整体关掉再补。
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: canvas.top) }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: canvas.bottom) }
            .environment(\.couliLayoutProbe, probes.probe)
            .environment(\.colorScheme, canvas.dark ? .dark : .light)
            .environment(\.dynamicTypeSize, canvas.size)
        let host = UIHostingController(rootView: root)
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = []
        }
        // 挂在 App 宿主的窗口场景上（不挂场景的独立 UIWindow 里 SwiftUI 不提交新一帧：实测内容到了仍渲染出加载骨架；
        // 与 APP-11v 测试 v5 Basic-w840 同一宿主问题）。
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        frame.frame = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        frame.overrideUserInterfaceStyle = canvas.dark ? .dark : .light
        frame.rootViewController = host
        frame.windowLevel = .alert + 1
        // 宿主 App 自己的窗口（RootView）同在这个场景里，启动后会再把自己设为主窗口；截图期间把它们藏起来，免得本窗口失去主窗口。
        hidden = (scene?.windows ?? []).filter { $0 !== frame && !$0.isHidden }
        hidden.forEach { $0.isHidden = true }
        frame.makeKeyAndVisible()
        host.view.frame = frame.bounds
        host.view.layoutIfNeeded()
        window = frame
    }

    func close() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        hidden.forEach { $0.isHidden = false }
        hidden = []
    }

    /// 渲染当前窗口（3 倍，与 iPhone 17 同）。
    func render() -> UIImage? {
        window.map(ProductVisualRender.image)
    }

    /// 等页面稳定：连续两帧取样指纹相同、且**测量记录也相同**；要图时还须本轮请求过商品图、且头图里画出了图（非占位底像素 ≥ 2000）。
    ///
    /// v2（实现交回 T2）：测量桥只在框变化时上报，布局后整体平移 / 环境变化可能让记录停在旧值。每次取样前强制窗口重新布局，
    /// 并要求相邻两次取样的全部测量记录逐条相等才算稳定——只等测量落定，判据本身不放宽。
    ///
    /// 要图时每轮最多等 4 秒，没上屏就关窗重挂同一页面再等（最多 3 轮），仍没有图才判失败。
    func stableImage(expectImage: Bool, file: StaticString = #filePath, line: UInt = #line) async -> UIImage? {
        var last: UIImage?
        for attempt in 0..<(expectImage ? 3 : 1) {
            if attempt > 0 {
                await show(canvas)
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(expectImage ? 4 : 8))
            var previous: [ProductVisualPixels.RGB]?
            var previousRecords: [String: CouliLayoutProbeRecord]?
            while clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(500))
                if window?.isKeyWindow == false {
                    window?.makeKeyAndVisible()
                }
                window?.rootViewController?.view.setNeedsLayout()
                window?.layoutIfNeeded()
                await Task.yield()
                guard let image = render() else { continue }
                last = image
                let ready = !expectImage || (ProductVisualImages.served.isEmpty == false && imageDrawn(image))
                let print = ProductVisualPixels(image).fingerprint()
                let records = probes.records
                if ready, print == previous, records == previousRecords {
                    return image
                }
                previous = ready ? print : nil
                previousRecords = ready ? records : nil
            }
        }
        if let last {
            XCTContext.runActivity(named: "最后一帧") { $0.add(XCTAttachment(image: last)) }
        }
        XCTFail("页面没有稳定（要图：\(expectImage)；已请求 \(ProductVisualImages.served)）", file: file, line: line)
        return last
    }

    /// 头图里是否已画出测试位图：有 `product.hero` 测量时数头图框内非占位底像素，否则数整页的三段色像素。
    func imageDrawn(_ image: UIImage) -> Bool {
        let pixels = ProductVisualPixels(image)
        if let hero = probes["product.hero"]?.rect {
            let placeholder = pixels.color(at: CGPoint(x: hero.minX + 3, y: hero.minY + 3))
            return pixels
                .count(in: hero.insetBy(dx: 2, dy: 2), step: 6) { !$0.near(placeholder, tolerance: 24) } >= 2000
        }
        return pixels.count(in: CGRect(origin: .zero, size: image.size), step: 6) { $0.isStripe } >= 2000
    }
}

/// 窗口截图：用 `drawHierarchy`（与屏幕所见一致，含 SwiftUI 的饱和度 / 灰度等图层滤镜）；`layer.render` 不画滤镜，
/// 正确的去色实现会被误判为彩色（判据自证 ProductVisualOracleTests 实测）。
@MainActor
enum ProductVisualRender {
    static func image(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// 在宿主场景上挂一个临时窗口渲染一段视图（判据参考图、自证用），返回截图与测量。
    static func standalone(_ view: some View, size: CGSize, dark: Bool = false,
                           until ready: (ProductVisualPixels) -> Bool = { _ in true }) async
        -> (UIImage, ProductVisualProbes) {
        let probes = ProductVisualProbes()
        let root = view.environment(\.couliLayoutProbe, probes.probe).environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.dynamicTypeSize, .large)
        let host = UIHostingController(rootView: root)
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = []
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.windowLevel = .alert + 2
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        var image = UIImage()
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(300))
            image = Self.image(window)
            if ready(ProductVisualPixels(image)) {
                break
            }
        }
        return (image, probes)
    }
}

/// 截图像素读取（点坐标；按渲染倍数换算）。
struct ProductVisualPixels {
    struct RGB: Equatable, CustomStringConvertible {
        let red: Int
        let green: Int
        let blue: Int

        func near(_ other: RGB, tolerance: Int) -> Bool {
            abs(red - other.red) <= tolerance && abs(green - other.green) <= tolerance
                && abs(blue - other.blue) <= tolerance
        }

        /// HSV 饱和度（0…1）。
        var saturation: Double {
            let high = max(red, green, blue)
            let low = min(red, green, blue)
            return high == 0 ? 0 : Double(high - low) / Double(high)
        }

        /// 三段测试位图之一（允许 24 的颜色误差）。
        var isStripe: Bool {
            [ProductVisualImages.red, ProductVisualImages.green, ProductVisualImages.blue].contains {
                abs(red - $0.r) <= 24 && abs(green - $0.g) <= 24 && abs(blue - $0.b) <= 24
            }
        }

        var description: String {
            String(format: "#%02X%02X%02X", red, green, blue)
        }

        init(red: Int, green: Int, blue: Int) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// 令牌颜色按外观解析。
        init(_ color: Color, dark: Bool) {
            let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            self.init(red: Int((red * 255).rounded()), green: Int((green * 255).rounded()),
                      blue: Int((blue * 255).rounded()))
        }
    }

    let width: Int
    let height: Int
    let scale: CGFloat
    private let bytes: [UInt8]

    init(_ image: UIImage) {
        scale = image.scale
        let source = image.cgImage
        width = source?.width ?? 0
        height = source?.height ?? 0
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        if let source, let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        bytes = buffer
    }

    func color(px column: Int, _ row: Int) -> RGB {
        let cx = min(max(column, 0), width - 1)
        let cy = min(max(row, 0), height - 1)
        let index = (cy * width + cx) * 4
        return RGB(red: Int(bytes[index]), green: Int(bytes[index + 1]), blue: Int(bytes[index + 2]))
    }

    func color(at point: CGPoint) -> RGB {
        color(px: Int(point.x * scale), Int(point.y * scale))
    }

    /// 区域内（点坐标）满足条件的像素数。
    /// `step` > 1 时隔点取样（等待画面时用，避免 Debug 构建逐像素遍历整页占住主线程、拖住 AsyncImage 上屏）；结果按取样比例放大。
    func count(in rect: CGRect, step: Int = 1, where predicate: (RGB) -> Bool) -> Int {
        var total = 0
        let xs = stride(from: max(0, Int(rect.minX * scale)), to: min(width, Int(rect.maxX * scale)), by: step)
        let ys = stride(from: max(0, Int(rect.minY * scale)), to: min(height, Int(rect.maxY * scale)), by: step)
        for row in ys {
            for column in xs where predicate(color(px: column, row)) {
                total += 1
            }
        }
        return total * step * step
    }

    /// 整图隔 8 物理像素取样的颜色序列（判断两帧是否相同）。
    func fingerprint() -> [RGB] {
        stride(from: 0, to: height, by: 8)
            .flatMap { row in stride(from: 0, to: width, by: 8).map { color(px: $0, row) } }
    }

    /// 一行（点坐标 y）里从左到右的颜色。
    func row(at top: CGFloat, from start: CGFloat, to end: CGFloat) -> [RGB] {
        let line = Int(top * scale)
        return (max(0, Int(start * scale))..<min(width, Int(end * scale))).map { color(px: $0, line) }
    }
}
