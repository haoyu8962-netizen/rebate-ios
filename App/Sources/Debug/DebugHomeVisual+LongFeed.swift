#if DEBUG
import Darwin
import DesignSystem
import Foundation
import HomeCore
import QuartzCore
import UIKit

/// 长信息流测量场景（APP-11v r1 S1-1；只在 Debug / Staging 编译）：场景名 `long_feed`。
///
/// 本机首页端口按游标给信息流连续 `pages` 页、每页 `pageSize` 件（共数百件，商品键各不相同，最后一页 next_cursor 为空）；
/// 场景就绪后由显示链接把首页列表从顶到底匀速滚完（翻页仍由真实加载行触发），记录：启动到首张信息流卡上屏、滚动帧间隔（卡顿帧）、
/// 进程内存（phys_footprint）随件数变化、同时实际布局的信息流卡数（布局测量桥里还在的 `home.product.feed.*`）。
/// 结果写到 App 临时目录 `couli-longfeed-bench.json` 并打日志，供 `xcrun simctl get_app_container … data` 取回。
@MainActor
final class DebugHomeVisualLongFeed {
    nonisolated static let pages = 25
    nonisolated static let pageSize = 20
    nonisolated static let resultFile = "couli-longfeed-bench.json"
    /// 每帧滚动距离（pt）：约 60 帧 / 秒时 1800pt/s，接近用户快速滑动。
    private static let step: CGFloat = 30

    private weak var visual: DebugHomeVisual?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var intervals: [CFTimeInterval] = []
    private var memory: [[String: Any]] = []
    private var lastSampledItems = -1
    private var maxRealized = 0
    private var firstCardMs: Double?
    private var readyMs: Double?
    private var startedAt: CFTimeInterval = 0
    private var finished = false

    init(visual: DebugHomeVisual) {
        self.visual = visual
    }

    // MARK: - 端口数据（端口在后台线程调用，只做纯数据变换）

    /// 第 n 页（游标 nil = 第 0 页，其余为 `lf-<n>`）：用 fixture 信息流的第一件做模板，改商品键 / 标题 / 价格。
    nonisolated static func page(template: Data?, cursor: String?) -> Data {
        let index = cursor.flatMap { Int($0.replacingOccurrences(of: "lf-", with: "")) } ?? 0
        let source = (template.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["items"]
        let base = (source as? [[String: Any]])?.first ?? [:]
        let items: [[String: Any]] = (0..<pageSize).map { offset in
            let serial = index * pageSize + offset
            var item = base
            item["product_key"] = "taobao:long-\(serial)"
            item["item_ref"] = "v1.long.\(serial).sig"
            item["link_id"] = "long-\(serial)"
            item["title"] = "长列表商品 \(serial) " + String(repeating: "加长标题", count: serial % 4)
            if let price = base["price_fen"] as? Int {
                item["price_fen"] = price + serial * 7
            }
            return item
        }
        let next: Any = index + 1 < pages ? "lf-\(index + 1)" : NSNull()
        return (try? JSONSerialization.data(withJSONObject: ["items": items, "next_cursor": next])) ?? Data()
    }

    // MARK: - 测量

    /// 每次读数轮询（0.2 秒）调用：记首张卡上屏时刻、实际布局卡数、按件数采样内存。
    func poll(state: HomeUiState, probes: [String: CouliLayoutProbeRecord]) {
        let prefix = "home.product.feed."
        let realized = probes.keys.filter {
            $0.hasPrefix(prefix) && $0.dropFirst(prefix.count).allSatisfy(\.isNumber)
        }.count
        maxRealized = max(maxRealized, realized)
        if firstCardMs == nil, realized > 0 {
            firstCardMs = Self.sinceLaunchMs()
        }
        let items = state.sections.first { $0.type == "feed_infinite" }?.items.count ?? 0
        if items / 100 != lastSampledItems / 100 || lastSampledItems < 0 {
            lastSampledItems = items
            memory.append(["items": items, "footprintMB": Self.footprintMB(), "realizedFeedCards": realized])
        }
    }

    func ready() {
        guard readyMs == nil else { return }
        readyMs = Self.sinceLaunchMs()
        memory.append(["items": -1, "footprintMB": Self.footprintMB(), "note": "ready"])
        let link = CADisplayLink(target: Ticker(owner: self), selector: #selector(Ticker.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        startedAt = CACurrentMediaTime()
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard !finished, let visual, let home = visual.home, let scroll = Self.homeList() else { return }
        if lastTimestamp > 0 {
            intervals.append(link.timestamp - lastTimestamp)
        }
        lastTimestamp = link.timestamp
        let maxOffset = max(0, scroll.contentSize.height - scroll.bounds.height)
        let feed = home.controller.state.sections.first { $0.type == "feed_infinite" }
        if scroll.contentOffset.y < maxOffset - 0.5 {
            scroll.setContentOffset(CGPoint(x: 0, y: min(maxOffset, scroll.contentOffset.y + Self.step)),
                                    animated: false)
        } else if feed?.feed?.exhausted == true || feed?.feed == nil {
            finish(items: feed?.items.count ?? 0, link: link)
        } else if CACurrentMediaTime() - startedAt > 180 {
            finish(items: feed?.items.count ?? 0, link: link, note: "timeout")
        }
    }

    private func finish(items: Int, link: CADisplayLink, note: String = "") {
        finished = true
        link.invalidate()
        self.link = nil
        let nominal = link.duration > 0 ? link.duration : 1.0 / 60
        let sorted = intervals.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        memory.append(["items": items, "footprintMB": Self.footprintMB(), "note": "end"])
        let result: [String: Any] = [
            "scene": "long_feed",
            "note": note,
            "items": items,
            "pages": Self.pages,
            "launchToFirstFeedCardMs": firstCardMs ?? -1,
            "launchToReadyMs": readyMs ?? -1,
            "scrollSeconds": CACurrentMediaTime() - startedAt,
            "frames": intervals.count,
            "nominalFrameMs": nominal * 1000,
            "hitchFrames": intervals.filter { $0 > nominal * 1.5 }.count,
            "longestFrameMs": (sorted.last ?? 0) * 1000,
            "p95FrameMs": p95 * 1000,
            "maxRealizedFeedCards": maxRealized,
            "sectionRequests": visual?.port.counts.sections ?? -1,
            "memory": memory,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(Self.resultFile)
            try? data.write(to: url)
            NSLog("COULI_LONGFEED_BENCH %@", String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// 首页列表的 UIScrollView：窗口里内容最高的纵向滚动容器（横滑区段内容不比视口高）。
    private static func homeList() -> UIScrollView? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var best: UIScrollView?
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height,
               scroll.contentSize.height > best?.contentSize.height ?? 0 {
                best = scroll
            }
            view.subviews.forEach(walk)
        }
        windows.forEach(walk)
        return best
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? (Double(info.phys_footprint) / 1_048_576 * 10).rounded() / 10 : -1
    }

    /// 进程启动到现在的毫秒数（内核记录的进程启动时刻）。
    private static func sinceLaunchMs() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_un.__p_starttime
        let launched = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return ((Date().timeIntervalSince1970 - launched) * 1000).rounded()
    }

    /// 显示链接的目标（CADisplayLink 强引用目标；结束时 invalidate 解除）。
    @MainActor
    private final class Ticker: NSObject {
        weak var owner: DebugHomeVisualLongFeed?

        init(owner: DebugHomeVisualLongFeed) {
            self.owner = owner
        }

        @objc func tick(_ link: CADisplayLink) {
            owner?.tick(link)
        }
    }
}
#endif
