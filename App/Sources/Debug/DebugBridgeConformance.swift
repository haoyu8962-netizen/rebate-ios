#if DEBUG
import BridgeHost
import Foundation
import Router
import SwiftUI
import Web

/// 桥一致性页入口（03 §5.5；只在 Debug / Staging 编译，Release 制品扫描查 `DebugBridgeConformance.marker`）。
///
/// 加载 rebate-platform 构建出的 `conformance` 入口，用的是**真实的** TrustedWebController 与 BridgeHost 分派（业务能力照常走
/// ApiClient、Router、Tracker、PermissionRequester），只替换三样调试取值：
/// - 可信源：只认本机一致性测试源（`http://127.0.0.1:8789`，只在 Debug 构建；Staging 没有本机源，入口打不开）；
/// - 规则表与分享域：契约 openapi `GET /v1/config` 响应示例里的 link_patterns 与 share_domains（包内规则为空，TODO(N-21)）；
/// - 「假定已登录」：调用方状态里放一个固定的调试归属键（`assumedAccountKey`），协议准入按已登录判；不造会话、不造令牌
///   （L1 / L2 的业务能力没有会话时照常失败）。
///
/// 启动参数 `-CouliBridgeConformance guest|logged_in` 直接打开（UI 测试与截图用）；页面结果 `window.__RESULT__` 每秒写到
/// App 的 Documents/bridge-conformance-<模式>.json（`xcrun simctl get_app_container … data` 取出）。
enum DebugBridgeConformance {
    /// Release 制品扫描查这个标记（长字符串，-O 下保留）。
    static let marker = "COULI_BRIDGE_CONFORMANCE_APP04_7d41c2"

    enum Mode: String, CaseIterable, Identifiable {
        case guest
        case loggedIn = "logged_in"

        var id: String {
            rawValue
        }
    }

    static let closedNotification = Notification.Name("CouliBridgeConformanceClosed")

    static var launchMode: Mode? {
        UserDefaults.standard.string(forKey: "CouliBridgeConformance").flatMap(Mode.init(rawValue:))
    }

    /// 本机一致性测试源（只在 Debug 构建；Staging 为 nil）。APP-04 三端共性第 2 条：回环地址只在调试源码里。
    static var loopbackOrigin: String? {
        #if STAGING
        nil
        #else
        "http://127.0.0.1:8789"
        #endif
    }

    static var pageURL: URL? {
        loopbackOrigin.flatMap { URL(string: $0 + "/conformance/") }
    }

    /// 契约 openapi GET /v1/config 响应示例的 link_patterns（只含保留测试域）。
    static var exampleLinkPatterns: [String: Any] {
        [
            "version": "2026100401",
            "rules": [
                ["platform": "taobao", "category": "union_host", "hosts": ["taobao.example.test"], "path_patterns": []],
            ],
        ]
    }

    /// 同一示例的 share_domains。
    static let exampleShareDomains = ["s.example.test"]

    @MainActor
    static func makeController(web: AppWeb, mode: Mode, onClose: @escaping @MainActor () -> Void)
        -> TrustedWebController {
        let origin = loopbackOrigin
        // 本机源逐字相等（scheme + 主机 + 端口），不做任何通配；与生产的 https 白名单分开。
        let matcher: @Sendable (String) -> Bool = { candidate in origin != nil && candidate == origin }
        return web.makeTrustedController(
            url: pageURL,
            protocolProvider: {
                BridgeProtocol(
                    trustedOrigins: [],
                    linkPatterns: exampleLinkPatterns,
                    shareDomains: exampleShareDomains,
                    extraOriginAllowed: matcher
                )
            },
            caller: { [weak web] in
                let state = web?.callerState(fromForceUpdatePage: false)
                    ?? BridgeCallerState(
                        privacy: BridgePrivacy.notDecided,
                        accountKey: nil,
                        update: BridgeUpdateState.unknown
                    )
                // 「假定已登录」只在本调试页：给一个固定的调试归属键，让协议准入按已登录判（L1 / L2 的用例测到协议层）；
                // 不造会话、不造令牌，业务能力没有会话时照常失败。
                guard mode == .loggedIn, state.accountKey == nil else { return state }
                return BridgeCallerState(
                    privacy: state.privacy, accountKey: assumedAccountKey, update: state.update,
                    fromForceUpdatePage: false
                )
            },
            onClose: onClose
        )
    }

    /// 「假定已登录」的调试归属键（只在 Debug / Staging 源码里）。
    static let assumedAccountKey = "conformance-assumed-login#0"

    static func resultFile(_ mode: Mode) -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("bridge-conformance-\(mode.rawValue).json")
    }
}

/// 一致性页的结果与路由观测（UI 测试逐项断言用，03 §5.5）。`json` 是 `window.__RESULT__` 精简后的逐项结果，
/// `router` 是 Router 的状态（Tab 根、栈深度、变更次数）：nav.open 之类离页调用要同时断言回包与实际导航结果。
/// 由 RootView 的调试浮层以无障碍标签暴露（页面被别的路由盖住时仍可读）。
@MainActor
final class DebugConformanceResults: ObservableObject {
    static let shared = DebugConformanceResults()

    @Published var json = ""
    @Published var router = ""
    private var routerChanges = 0

    /// Router 发布了一次 Tab 根或导航栈（启动时的初值算第 0 次）。
    func routerChanged(root: RouteDestination, depth: Int) {
        router = "tabRoot=\(root.route ?? "") path=\(depth) changes=\(routerChanges)"
        routerChanges += 1
    }

    /// 只保留断言要用的字段：id、method、category、trigger、pass、outcome（ok / code）。
    static func compact(_ object: [String: Any]) -> String {
        let cases = (object["cases"] as? [[String: Any]] ?? []).map { item -> [String: Any] in
            var entry: [String: Any] = [:]
            for key in ["id", "method", "category", "trigger"] {
                entry[key] = item[key]
            }
            entry["pass"] = item["pass"] ?? NSNull()
            entry["outcome"] = item["outcome"] ?? NSNull()
            return entry
        }
        let body: [String: Any] = [
            "status": object["status"] ?? "",
            "unknown_cases": object["unknown_cases"] ?? [],
            "cases": cases,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// RootView 的调试浮层：两段无障碍标签（`conformance.result`、`conformance.router`），界面上几乎不可见、不接收点击。
struct DebugConformanceResultsOverlay: View {
    @ObservedObject var results = DebugConformanceResults.shared
    @EnvironmentObject private var router: Router

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: "r")
                .accessibilityLabel(Text(verbatim: results.json))
                .accessibilityIdentifier("conformance.result")
            Text(verbatim: "n")
                .accessibilityLabel(Text(verbatim: results.router))
                .accessibilityIdentifier("conformance.router")
        }
        .font(.system(size: 4))
        .opacity(0.05)
        .allowsHitTesting(false)
        .onReceive(router.$tabRoot.combineLatest(router.$path)) { root, path in
            results.routerChanged(root: root, depth: path.count)
        }
    }
}

/// 一致性页：真实可信容器 + 结果导出。顶部一行显示通过 / 失败 / 待定计数（UI 测试读它判断跑完）。
struct DebugBridgeConformanceView: View {
    let mode: DebugBridgeConformance.Mode
    @EnvironmentObject private var web: AppWeb

    var body: some View {
        DebugConformanceContainer(web: web, mode: mode)
    }
}

private struct DebugConformanceContainer: View {
    let mode: DebugBridgeConformance.Mode
    @StateObject private var controller: TrustedWebController
    @State private var summary = "starting"
    @Environment(\.dismiss) private var dismiss

    @State private var closed = false

    init(web: AppWeb, mode: DebugBridgeConformance.Mode) {
        self.mode = mode
        _controller = StateObject(wrappedValue: DebugBridgeConformance.makeController(web: web, mode: mode) {
            NotificationCenter.default.post(name: DebugBridgeConformance.closedNotification, object: nil)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: "\(DebugBridgeConformance.marker.prefix(5)) \(mode.rawValue) · \(summary)")
                .font(.caption2)
                .accessibilityIdentifier("conformance.summary")
            if closed {
                // nav.close：容器已关闭（调试页是栈底，没有可返回的页面，这里只显示已关闭）。
                Text(verbatim: "container closed by nav.close")
                    .accessibilityIdentifier("conformance.closed")
                Spacer()
            } else {
                TrustedWebScreen(controller: controller)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: DebugBridgeConformance.closedNotification)) { _ in
            closed = true
        }
        .task {
            controller.start()
            await exportLoop()
        }
    }

    /// 每秒读一次 `window.__RESULT__`（只在这个调试页里执行脚本；生产容器不执行页面脚本取值）。
    private func exportLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let script = "JSON.stringify(window.__RESULT__ || null)"
            guard let json = try? await controller.webView.evaluateJavaScript(script) as? String,
                  json != "null"
            else { continue }
            if let file = DebugBridgeConformance.resultFile(mode) {
                try? Data(json.utf8).write(to: file, options: .atomic)
            }
            if let object = AppWeb.object(json) {
                DebugConformanceResults.shared.json = DebugConformanceResults.compact(object)
            }
            if let object = AppWeb.object(json), let counts = object["summary"] as? [String: Any] {
                let status = object["status"] as? String ?? "?"
                summary = "\(status) passed \(counts["passed"] ?? 0) failed \(counts["failed"] ?? 0) "
                    + "pending \(counts["pending"] ?? 0)"
            }
        }
    }
}
#endif
