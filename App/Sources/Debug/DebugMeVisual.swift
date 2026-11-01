#if DEBUG
import Clipboard
import Combine
import Foundation
import Me
import Router
import SwiftUI

/// 「我的」视觉 UI 测试的 Me 报文注入（APP-12v；只在 Debug / Staging 编译，Release 制品扫描查环境变量名 `COULI_FAKE_ME_VISUAL`、
/// 类型名 DebugMeVisual / DebugMeLog 与标识 `debug.me.log`）。调试开关只走环境变量，不写 App 标准偏好。
///
/// 环境变量 `COULI_FAKE_ME_VISUAL` = UTF-8 JSON 对象的 Base64：`{"me": <Me 报文>}`，游客给 `{}`（只开记录，不接管 getMe）。
/// 生效时假服务 `GET /v1/me` 回注入的报文，先于 `-CouliFakeMe me=…`；`guide=1` 仍然生效。
enum DebugMeVisual {
    static let environmentKey = "COULI_FAKE_ME_VISUAL"

    /// 注入内容（进程启动后读一次；没有、解不开或假服务没打开时为 nil，不接管任何请求）。
    nonisolated(unsafe) static let payload: [String: Any]? = {
        guard ProcessInfo.processInfo.arguments.contains(DebugFakeLoginServer.launchArgument),
              let raw = ProcessInfo.processInfo.environment[environmentKey],
              let data = Data(base64Encoded: raw)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }()

    static var isActive: Bool {
        payload != nil
    }

    /// `GET /v1/me` 记一条；有注入报文时给回答，其余 nil。
    static func reply(method: String, path: String) -> String? {
        guard isActive, method == "GET", path == "/v1/me" else { return nil }
        DebugMeLog.request(method: method, path: path)
        guard let me = payload?["me"] as? [String: Any] else { return nil }
        return DebugFakeMe.json(me)
    }
}

/// 只读记录：`request:GET /v1/me`、`route:<路由名>`（含切 Tab）、`copy`（统一写入口写入成功，不记内容）、`toast:<文字>`（真正显示时）、
/// `announce:polite:<文字>` / `announce:assertive:<文字>`。UI 测试读根视图左上角 1×1 的只读元素 `debug.me.log`，
/// accessibilityValue = 全部记录按发生顺序以「 | 」连接。不影响任何回答与界面。
@MainActor
final class DebugMeLog: ObservableObject {
    static let shared = DebugMeLog()
    static let identifier = "debug.me.log"

    @Published private(set) var entries: [String] = []
    private var seen: Set<UUID> = []

    /// 任意线程调用（假服务在网络线程回答）；在主线程按调用顺序追加。
    nonisolated static func request(method: String, path: String) {
        let entry = "request:\(method) \(path)"
        DispatchQueue.main.async {
            MainActor.assumeIsolated { shared.entries.append(entry) }
        }
    }

    /// 接上生产旁路（都是 nil 钩子：不接时生产行为一样）。
    func install() {
        MeAnnounceProbe.toast = { [weak self] in self?.entries.append("toast:" + $0) }
        MeAnnounceProbe.observe = { [weak self] text, assertive in
            self?.entries.append("announce:\(assertive ? "assertive" : "polite"):\(text)")
        }
        ClipboardWriter.writeObserver = { [weak self] in self?.entries.append("copy") }
    }

    /// Router 新打开的目的地（同一目的地只记一次：栈变短、重发不算）。
    func opened(_ destinations: [RouteDestination]) {
        for destination in destinations where seen.insert(destination.id).inserted {
            if let route = destination.route {
                entries.append("route:" + route)
            }
        }
    }

    var value: String {
        entries.joined(separator: " | ")
    }
}

/// `debug.me.log` 只读元素（1×1、透明，不挡点击）。路由取 Router 自己的发布值：App/Sources/Me 不动（逻辑零改动），首个值是启动现状，不算打开。
struct DebugMeLogReadout: View {
    let router: Router
    let me: AppMe
    @ObservedObject var log = DebugMeLog.shared

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: DebugMeLog.identifier))
            .accessibilityValue(Text(verbatim: log.value))
            .accessibilityIdentifier(DebugMeLog.identifier)
            .onAppear {
                log.install()
                // guide=1 只强制权限条件；上一次冷启动点过关闭的时刻落了盘，这里改回很久以前，否则 7 天内不再显示
                if DebugFakeMe.shared.forceGuideBar {
                    me.local.markGuideClosed(0)
                }
            }
            .onReceive(router.$path.dropFirst()) { log.opened($0) }
            .onReceive(router.$tabRoot.dropFirst()) { log.opened([$0]) }
    }
}
#endif
