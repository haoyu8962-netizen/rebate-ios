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
/// - `earnings: true`：只在 Debug 把收益看板开关当作打开、Earnings 路由 since 当作 "1.0.0"（生产 since=null 不变）；
/// - APP-09v-b 可选键 `records`：`{"pages": {"<游标>": <列表报文>, …}（"" = 第一页）, "details": {"<withdrawal_id>": <详情报文>},
///   "nowMillis": <Int>}`——`GET /v1/withdrawals` 无 cursor 回 `pages[""]`、有 cursor 回 `pages[<游标>]`（缺页 50001），
///   `GET /v1/withdrawals/{id}` 回 `details[id]`（没有 30701）；两类回答带 `Date` 响应头 = nowMillis（生产据此校准显示时钟）；
/// - APP-09v-c 可选键 `withdraw`：`{"rules": <WithdrawRules 报文>, "helpLinks": {"withdraw_rules": {…}}}`——
///   `GET /v1/withdrawals/rules` 回 `rules`（先于通用样例）；假服务 `GET /v1/config` 的 `help_links` 并入 `helpLinks`（生产不变）。
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

    /// 注入的提现记录回答（APP-09v-b）；不是记录请求或没注入 `records` 时 nil。
    static func recordsReply(method: String, path: String, query: [String: String]) -> DebugFakeWallet.Reply? {
        guard let records = payload?["records"] as? [String: Any], method == "GET",
              path.hasPrefix("/v1/withdrawals"), path != "/v1/withdrawals/rules"
        else { return nil }
        let headers = (records["nowMillis"] as? NSNumber).map { ["Date": httpDate($0.int64Value)] } ?? [:]
        if path == "/v1/withdrawals" {
            let pages = records["pages"] as? [String: Any] ?? [:]
            guard let page = pages[query["cursor"] ?? ""] else {
                return .answer(code: 50001, data: "null", headers: headers)
            }
            return .answer(code: 0, data: DebugFakeWallet.json(page), headers: headers)
        }
        let id = String(path.dropFirst("/v1/withdrawals/".count)).removingPercentEncoding ?? ""
        guard let detail = (records["details"] as? [String: Any])?[id] else {
            return .answer(code: 30701, data: "null", headers: headers)
        }
        return .answer(code: 0, data: DebugFakeWallet.json(detail), headers: headers)
    }

    private static var withdraw: [String: Any]? {
        payload?["withdraw"] as? [String: Any]
    }

    /// 注入的提现规则（APP-09v-c）；不是 rules 请求或没注入时 nil。
    static func rulesReply(method: String, path: String) -> DebugFakeWallet.Reply? {
        guard method == "GET", path == "/v1/withdrawals/rules", let rules = withdraw?["rules"] as? [String: Any]
        else { return nil }
        return .answer(code: 0, data: DebugFakeWallet.json(rules), headers: [:])
    }

    /// 配置里并入注入的 `help_links`（APP-09v-c）；不是配置请求或没注入时 nil。`base` = 假服务本来要回的配置。
    static func configReply(method: String, path: String, base: () -> String) -> DebugFakeWallet.Reply? {
        guard method == "GET", path == "/v1/config", let links = withdraw?["helpLinks"] as? [String: Any],
              var config = (try? JSONSerialization.jsonObject(with: Data(base().utf8))) as? [String: Any]
        else { return nil }
        config["help_links"] = (config["help_links"] as? [String: Any] ?? [:]).merging(links) { $1 }
        return .answer(code: 0, data: DebugFakeWallet.json(config), headers: [:])
    }

    /// HTTP 日期（RFC 7231，GMT）。
    static func httpDate(_ millis: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }
}

/// 钱包页视觉 UI 测试的只读记录（只在注入生效时记录与显示）：
/// - `request:<方法> <路径>`：假服务收到的每个钱包类请求；
/// - `route:<路由名>[?<参数按键名排序 k=v&…>]`：钱包类页面每调用一次 App 出口 `AppWallet.open` / `replace` 记一条（交给 Router 之前记）；
/// - APP-09v-b：`copy:<文本>`（`AppWallet.copy` 每调用一次一条）、`contact:<来源路由名>`（`AppWallet.contactService` 每调用一次一条），
///   都在交给系统 / 客服出口之前同步追加。
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

    /// 统一剪贴板写入口（主线程）：同步追加。
    static func copy(_ text: String) {
        guard DebugWalletVisual.isActive else { return }
        shared.entries.append("copy:" + text)
    }

    /// 客服出口（主线程）：同步追加。
    static func contact(_ route: String) {
        guard DebugWalletVisual.isActive else { return }
        shared.entries.append("contact:" + route)
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
