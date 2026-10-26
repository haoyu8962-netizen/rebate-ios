@testable import Couli
import DesignSystem
import Foundation
import OrderCore
import Router
import SwiftUI
import UIKit
import XCTest

/// 真实 App 组装的订单页（APP-08v）：OrdersAppFixture（已登录 user-a，网络换成 OrderVisualStub）→ AppOrders → 生产的
/// `OrderListRouteView` / `OrderDetailRouteView`。测试只换网络、图片、时钟与测量接收方，不重画页面。
/// 时钟固定 2026-10-12 10:30（visualOrders.clock）；安全区按画板固定 顶 54 / 底 34（与商品详情视觉同口径）。
@MainActor
final class OrderVisualHost {
    struct Canvas {
        var width: CGFloat = 390
        var height: CGFloat = 844
        var dark = false
        var size: DynamicTypeSize = .large
        var top: CGFloat = 54
        var bottom: CGFloat = 34
    }

    enum Page: Equatable {
        case list
        case detail(String)
    }

    let fixture: OrdersAppFixture
    let probes = ProductVisualProbes()
    private(set) var window: UIWindow?
    private(set) var canvas = Canvas()
    private(set) var page: Page = .list
    private var destination: RouteDestination?
    private var hidden: [UIWindow] = []

    init(suiteName: String, defaults: UserDefaults, script: OrderVisualStub.Script) throws {
        OrderVisualStub.install(script)
        fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults,
                                        configuration: OrderVisualStub.configuration())
        let now = try OrderVisualData.nowMillis()
        fixture.orders.clock = { now }
    }

    var orders: AppOrders {
        fixture.orders
    }

    /// 金额隐藏开关（设备级偏好，本组合自己的偏好套件）。
    func setHidden(_ hidden: Bool) {
        fixture.orders.mask.set(hidden)
    }

    /// 打开订单列表（订单 Tab 根；scope 为空 = 自购）。
    func showList(_ canvas: Canvas = Canvas(), scope: String? = nil) async {
        page = .list
        var params: [String: JSONValue] = [:]
        if let scope {
            params["scope"] = .string(scope)
        }
        destination = RouteDestination(route: "OrderList", params: params)
        await mount(canvas)
    }

    /// 打开订单详情（经 Router 推入，路由栈里有这一页，出栈生命周期与生产一致）。
    func showDetail(_ orderId: String, _ canvas: Canvas = Canvas()) async throws {
        page = .detail(orderId)
        let router = fixture.routing.router
        router.open(RouteRequest(route: "OrderDetail", values: ["order_id": .string(orderId)], from: .inApp))
        destination = try XCTUnwrap(router.path.last, "Router 没有推入 OrderDetail")
        await mount(canvas)
    }

    /// 重新挂当前页面（换画布：深色、字号、宽度）。列表执行器一个会话一份，重挂不重新请求。
    func remount(_ canvas: Canvas) async {
        await mount(canvas)
    }

    private func mount(_ canvas: Canvas) async {
        close()
        self.canvas = canvas
        let orders = fixture.orders
        let content = if let destination {
            switch page {
            case .list: AnyView(OrderListRouteView(destination: destination))
            case .detail: AnyView(OrderDetailRouteView(destination: destination))
            }
        } else {
            AnyView(EmptyView())
        }
        let root = content
            .environmentObject(orders)
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: canvas.top) }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: canvas.bottom) }
            .environment(\.couliLayoutProbe, probes.probe)
            .environment(\.colorScheme, canvas.dark ? .dark : .light)
            .environment(\.dynamicTypeSize, canvas.size)
        let host = UIHostingController(rootView: root)
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = []
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        frame.frame = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        frame.overrideUserInterfaceStyle = canvas.dark ? .dark : .light
        frame.rootViewController = host
        frame.windowLevel = .alert + 1
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

    func render() -> UIImage? {
        window.map(ProductVisualRender.image)
    }

    /// 等页面稳定：连续两帧取样指纹相同、且测量记录也逐条相同（APP-06v-b 测试 v2「两帧一致」）；`ready` 另加就绪条件
    /// （如某个测量已上报、商品图已画出）。最多等 `seconds` 秒，没稳定判失败并附最后一帧。
    func stable(seconds: Int = 10, file: StaticString = #filePath, line: UInt = #line,
                until ready: (OrderVisualHost, UIImage) -> Bool = { _, _ in true }) async -> UIImage? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        var last: UIImage?
        var previous: [ProductVisualPixels.RGB]?
        var previousRecords: [String: CouliLayoutProbeRecord]?
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            if window?.isKeyWindow == false {
                window?.makeKeyAndVisible()
            }
            window?.rootViewController?.view.setNeedsLayout()
            window?.layoutIfNeeded()
            await Task.yield()
            guard let image = render() else { continue }
            last = image
            let ok = ready(self, image)
            let print = ProductVisualPixels(image).fingerprint()
            let records = probes.records
            if ok, print == previous, records == previousRecords {
                return image
            }
            previous = ok ? print : nil
            previousRecords = ok ? records : nil
        }
        if let last {
            XCTContext.runActivity(named: "最后一帧") { $0.add(XCTAttachment(image: last)) }
        }
        let reported = probes.records.keys.sorted()
        XCTFail("页面没有稳定或没就绪（已请求 \(OrderVisualStub.orderRequests.map(\.line))；图片 \(OrderVisualImages.served)；"
            + "已上报测量 \(reported.count) 个\(reported.isEmpty ? "——§2 测量桥未接" : "：\(reported.prefix(12))")）",
            file: file, line: line)
        return last
    }

    /// 列表里某张卡的商品图已画出测试位图（缩略图框内三段色像素足够多）。没有该测量时看整页三段色。
    func thumbnailDrawn(_ image: UIImage, id: String) -> Bool {
        let pixels = ProductVisualPixels(image)
        let rect = probes["order.card.\(id).image"]?.rect ?? probes["orderDetail.product.image"]?.rect
            ?? CGRect(origin: .zero, size: image.size)
        return pixels.count(in: rect, step: 2) { $0.isStripe } >= 400
    }

    /// 断网 + 缓存（OrdersStale / 详情 stale）：先在 09:30 用当前脚本取一次成功（写入断网缓存），再改成断网、作废显示后重开页面，
    /// 时钟回到 10:30——页面显示「今天 09:30」的提示条与缓存数据（生产缓存与读取路径，不另造快照）。
    func prepareStale(_ canvas: Canvas = Canvas(), file: StaticString = #filePath, line: UInt = #line) async throws {
        let now = try OrderVisualData.nowMillis()
        let staleAt = try OrderVisualData.staleAtMillis()
        fixture.orders.clock = { staleAt }
        switch page {
        case .list:
            await showList(canvas)
            _ = await stable(file: file, line: line) { host, _ in
                host.orders.listConfig?.controller.snapshot.phase == .content
            }
        case let .detail(id):
            try await showDetail(id, canvas)
            _ = await stable(file: file, line: line) { host, _ in
                host.orders.details.values.contains { $0.controller?.snapshot.phase == .content }
            }
        }
        OrderVisualStub.update { $0.offline = true }
        fixture.orders.clock = { now }
        switch page {
        case .list:
            fixture.orders.clearDisplays()
            await showList(canvas)
        case let .detail(id):
            fixture.routing.router.path.removeAll()
            try await showDetail(id, canvas)
        }
    }
}
