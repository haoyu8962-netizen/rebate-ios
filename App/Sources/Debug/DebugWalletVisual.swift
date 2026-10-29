#if DEBUG
import Foundation
import SwiftUI

/// 钱包页视觉 UI 测试的摘要注入（APP-09v-a；只在 Debug / Staging 编译，Release 制品扫描查环境变量名 `COULI_FAKE_WALLET_VISUAL`、
/// 类型名 DebugWalletVisual / DebugWalletLog 与标识 `debug.wallet.log`）。调试开关只走环境变量，不写 App 标准偏好。
///
/// 环境变量 `COULI_FAKE_WALLET_VISUAL` = UTF-8 JSON 对象的 Base64：`{"summary": <WalletSummary 报文>, "offline": <bool>,
/// "earnings": <bool>}`，
/// 仅在本机假服务（`-CouliFakeLoginServer`）打开时生效：
/// - `GET /v1/wallet/summary` 原样回注入的 `summary`（先于 `-CouliFakeWallet wallet=…` 的通用样例）；`offline: true` 时这条按传输层失败
///   结束（生产读断网缓存）；其余钱包类接口照旧由 DebugFakeWallet 回答；
/// - `earnings: true`：只在 Debug 把收益看板开关当作打开、Earnings 路由 since 当作 "1.0.0"（生产 since=null 不变）。
enum DebugWalletVisual {
    static let environmentKey = "COULI_FAKE_WALLET_VISUAL"

    /// 注入内容（进程启动后读一次；没有、解不开或假服务没打开时为 nil，不接管任何请求）。
    nonisolated(unsafe) static let payload: [String: Any]? = {
        guard ProcessInfo.processInfo.arguments.contains(DebugFakeLoginServer.launchArgument),
              let raw = ProcessInfo.processInfo.environment[environmentKey],
              let data = Data(base64Encoded: raw),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["summary"] is [String: Any]
        else { return nil }
        return object
    }()

    static var isActive: Bool {
        payload != nil
    }

    static var earnings: Bool {
        payload?["earnings"] as? Bool == true
    }

    /// 钱包类请求（只读记录要记的范围，与 DebugFakeWallet 接管的路径相同）。
    static func isWalletPath(_ path: String) -> Bool {
        path.hasPrefix("/v1/wallet/") || path.hasPrefix("/v1/withdrawals") || path == "/v1/me"
            || path == "/v1/me/payout-account" || path == "/v1/auth/step-up" || path == "/v1/idempotency-keys/abandon"
    }

    /// 注入的摘要回答；不是摘要请求或没注入时 nil。
    static func summaryReply(method: String, path: String) -> DebugFakeWallet.Reply? {
        guard let payload, method == "GET", path == "/v1/wallet/summary",
              let summary = payload["summary"] as? [String: Any]
        else { return nil }
        if payload["offline"] as? Bool == true {
            return .offline
        }
        return .answer(code: 0, data: DebugFakeWallet.json(summary), headers: [:])
    }
}

/// 钱包页视觉 UI 测试的只读记录（只在注入生效时记录与显示）：
/// - `request:<方法> <路径>`：假服务收到的每个钱包类请求；
/// - `route:<路由名>[?<参数按键名排序 k=v&…>]`：钱包类页面每调用一次 App 出口 `AppWallet.open` / `replace` 记一条（交给 Router 之前记）。
/// UI 测试读根视图左上角 1×1 的只读元素 `debug.wallet.log`：accessibilityValue = 全部记录按发生顺序以「 | 」连接。不影响任何回答与界面。
@MainActor
final class DebugWalletLog: ObservableObject {
    static let shared = DebugWalletLog()
    static let identifier = "debug.wallet.log"

    @Published private(set) var entries: [String] = []

    /// 任意线程调用（假服务在网络线程回答）；在主线程按调用顺序追加。
    nonisolated static func request(method: String, path: String) {
        guard DebugWalletVisual.isActive, DebugWalletVisual.isWalletPath(path) else { return }
        let entry = "request:\(method) \(path)"
        DispatchQueue.main.async {
            MainActor.assumeIsolated { shared.entries.append(entry) }
        }
    }

    /// App 出口（主线程）：同步追加，先于随后的请求记录。
    static func route(_ route: String, params: [String: String]) {
        guard DebugWalletVisual.isActive else { return }
        let query = params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined(separator: "&")
        shared.entries.append("route:" + route + (query.isEmpty ? "" : "?" + query))
    }

    var value: String {
        entries.joined(separator: " | ")
    }
}

/// `debug.wallet.log` 只读元素（1×1、透明，不挡点击）。
struct DebugWalletLogReadout: View {
    @ObservedObject var log = DebugWalletLog.shared

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: DebugWalletLog.identifier))
            .accessibilityValue(Text(verbatim: log.value))
            .accessibilityIdentifier(DebugWalletLog.identifier)
    }
}
#endif
