@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Router
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// 真实 App 组装的提现记录页（APP-09v-b）：WalletAppFixture（已登录 user-a，AppNetwork + AppRouting + AppLogin + AppWallet，传输层换成
/// WalletStubProtocol）→ Router 打开 WithdrawRecords（可带 withdrawal_id）→ 生产的 `WalletRouteView`（AppWallet.entry →
/// WithdrawRecordsScreen + WithdrawRecordsController）。测试只换网络、测量接收方与画布，不重画页面。显示时钟靠响应头 Date 走生产校准。
/// 安全区按画板固定 顶 54 / 底 34（与钱包 a 组同口径）。
@MainActor
final class RecordsVisualHost {
    struct Canvas {
        var width: CGFloat = 390
        var height: CGFloat = 844
        var dark = false
        var size: DynamicTypeSize = .large
        var top: CGFloat = 54
        var bottom: CGFloat = 34
    }

    let fixture: WalletAppFixture
    let server: RecordsVisualServer
    let probes = ProductVisualProbes()
    private(set) var window: UIWindow?
    private(set) var canvas = Canvas()
    private(set) var destination: RouteDestination?
    private var hidden: [UIWindow] = []

    init(suiteName: String, defaults: UserDefaults, server: RecordsVisualServer) {
        self.server = server
        fixture = WalletAppFixture.make(suiteName: suiteName, defaults: defaults)
    }

    var wallet: AppWallet {
        fixture.wallet
    }

    var controller: WithdrawRecordsController? {
        guard let destination else { return nil }
        return wallet.pages[destination.id]?.controller as? WithdrawRecordsController
    }

    /// 经真实 Router 打开 WithdrawRecords（`focus` = 路由参数 withdrawal_id）并挂窗口。
    func show(focus: String? = nil, _ canvas: Canvas = Canvas()) async throws {
        if destination == nil {
            let values: [String: JSONValue] = focus.map { [WalletRoutes.withdrawalId: .string($0)] } ?? [:]
            fixture.router.open(RouteRequest(route: WalletRoutes.withdrawRecords, values: values, from: .inApp))
            destination = try XCTUnwrap(fixture.router.path.last, "Router 没有推入 WithdrawRecords")
            XCTAssertEqual(destination?.route, WalletRoutes.withdrawRecords)
        }
        mount(canvas)
    }

    /// 换画布重挂当前页面（执行器一个导航实例一份，重挂不重建）。
    func remount(_ canvas: Canvas) {
        mount(canvas)
    }

    private func mount(_ canvas: Canvas) {
        close()
        self.canvas = canvas
        let content = if let destination {
            AnyView(WalletRouteView(destination: destination).environmentObject(wallet))
        } else {
            AnyView(EmptyView())
        }
        let root = content
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

    /// 等页面稳定：连续两帧像素指纹相同、测量记录逐条相同，且就绪条件成立；没稳定判失败并附最后一帧、执行器阶段、已发请求与已上报测量。
    func stable(seconds: Int = 10, file: StaticString = #filePath, line: UInt = #line,
                until ready: (RecordsVisualHost) -> Bool) async -> UIImage? {
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
            let ok = ready(self)
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
        let phase = controller.map { "\($0.state.phase)" } ?? "无执行器"
        XCTFail(
            "页面没有稳定或没就绪（执行器 \(phase)；已请求 \(WalletStubProtocol.requests.map { "\($0.method) \($0.path)?\($0.query)" })；"
                + "已上报测量 \(reported.count) 个\(reported.isEmpty ? "——§4 测量桥未接" : "：\(reported.prefix(20))")）",
            file: file,
            line: line
        )
        return last
    }

    // MARK: - 操作（与真实点击走同一份回调：渲染时取出的 RecordsActions）

    /// 展开 / 收起一张单（等同点整行；回调带当前快照的版本与身份）。
    func toggle(_ id: String) throws {
        let controller = try XCTUnwrap(controller, "没有记录页执行器")
        RecordsActions.make(controller, controller.state).toggle(id)
    }

    // MARK: - 滚动

    /// 记录列表的滚动视图：竖向、面积最大的那个。
    var scroller: UIScrollView? {
        guard let window else { return nil }
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, !scroll.isHidden, scroll.window != nil,
               scroll.bounds.height > 100 {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    /// 滚动视图在窗口里的可视框。
    var viewport: CGRect? {
        scroller.map { $0.convert($0.bounds, to: nil) }
    }

    var maxOffset: CGFloat {
        guard let scroller else { return 0 }
        return max(0, scroller.contentSize.height - scroller.bounds.height + scroller.adjustedContentInset.bottom
            - scroller.adjustedContentInset.top)
    }

    /// 滚到绝对偏移（不带动画；与 APP-08v 订单列表测试同做法）。
    func scroll(to offset: CGFloat) {
        guard let scroller else { return }
        let top = -scroller.adjustedContentInset.top
        scroller.setContentOffset(CGPoint(x: scroller.contentOffset.x, y: max(top, min(offset, maxOffset))),
                                  animated: false)
        window?.layoutIfNeeded()
    }

    var offset: CGFloat {
        scroller?.contentOffset.y ?? 0
    }

    /// 可视区顶边上最靠上、仍露出的记录（收起行 `records.row.<id>` 或展开卡 `records.detail.<id>`）及其相对可视区顶边的偏移。
    func anchor() -> (id: String, offset: CGFloat)? {
        guard let top = viewport?.minY else { return nil }
        var best: (String, CGRect)?
        for (key, record) in probes.records {
            let parts = key.split(separator: ".")
            guard parts.count == 3, parts[0] == "records", parts[1] == "row" || parts[1] == "detail" else { continue }
            guard record.rect.maxY > top + 1 else { continue }
            if best.map({ record.rect.minY < $0.1.minY }) ?? true {
                best = (String(parts[2]), record.rect)
            }
        }
        return best.map { ($0.0, $0.1.minY - top) }
    }

    /// 某张单当前的框（收起行或展开卡）。
    func frame(of id: String) -> CGRect? {
        probes["records.detail.\(id)"]?.rect ?? probes["records.row.\(id)"]?.rect
    }
}
