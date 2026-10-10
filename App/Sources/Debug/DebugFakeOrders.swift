#if DEBUG
import Foundation

/// 本机假服务的订单场景（APP-08 截图、冒烟与设计稿比对用；只在 Debug / Staging 编译，APP-04 共性 2）。由 `DebugFakeLoginServer`
/// （启动参数 `-CouliFakeLoginServer`）接管时回答；Release 制品扫描查 `marker` 与类型名。全部在本机回答，不连任何地址。
/// 数据照设计稿 sample-data §1、§12.2、§12.3（订单号、金额、时间都是样例值，没有个人信息；与 Android DebugFakeOrders 同一份）。
///
/// - `GET /v1/orders`：自购 15 单（每页 5 单）、分享 5 单；按 status_group、platform、paid_month 在服务端筛；q：自购单完整单号命中，否则按
///   标题包含；分享单只按标题（好友买的其他商品不参与）。§12.3 的补稿订单不进列表，按完整单号能搜到。q 场景词：`fail` 50001、`busy` 42901
///   （Retry-After 10）、`slow` 3 秒后回答、`pageerr` 第二页 50401；
/// - `GET /v1/orders/{order_id}`：样例详情；`ord-missing` → 30701；
/// - `GET /v1/orders/pending-tracks` 与 `POST …/dismiss`：开关 pending 打开时淘宝、京东各一张（京东带找回入口）、拼多多一张已关闭；关闭记在
///   本进程。
/// 开关（启动参数 `-CouliFakeOrders offline,empty,pending,appeal,history=2026-01-01,dismiss=busy|stale`）：offline 订单接口一律传输失败
/// （断网演示），empty 没有订单，appeal 剃须刀那单申诉中，history 下发 earliest_visible_date。
enum DebugFakeOrders {
    static let marker = "COULI_FAKE_ORDERS_SERVER_APP08_IOS_6a2f19"
    static let prefix = "/v1/orders"

    enum Reply {
        case answer(code: Int, data: String, headers: [String: String], delay: TimeInterval)
        /// 传输失败（断网）。
        case offline
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var dismissed: Set<String> = []

    static var options: [String: String] {
        var out: [String: String] = [:]
        for part in (UserDefaults.standard.string(forKey: "CouliFakeOrders") ?? "").split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            out[pair[0]] = pair.count == 2 ? pair[1] : "1"
        }
        return out
    }

    static func answer(method: String, path: String, query: [String: String]) -> Reply? {
        guard path == prefix || path.hasPrefix(prefix + "/") else { return nil }
        let state = options
        if state["offline"] != nil {
            return .offline
        }
        if path == prefix + "/pending-tracks" {
            return pending(state)
        }
        if path.hasPrefix(prefix + "/pending-tracks/"), method == "POST" {
            return dismiss(path, state)
        }
        if path == prefix {
            return list(query, state)
        }
        let id = String(path.dropFirst(prefix.count + 1)).removingPercentEncoding ?? ""
        return detail(id, state)
    }

    private static func ok(_ object: Any, delay: TimeInterval = 0.3) -> Reply {
        .answer(code: 0, data: DebugFakeSearch.json(object), headers: [:], delay: delay)
    }

    private static func fail(_ code: Int, headers: [String: String] = [:]) -> Reply {
        .answer(code: code, data: "{}", headers: headers, delay: 0.3)
    }

    // MARK: - 列表

    private static func list(_ query: [String: String], _ state: [String: String]) -> Reply {
        let keyword = query["q"]
        let page = Int(query["cursor"]?.replacingOccurrences(of: "page-", with: "") ?? "") ?? 0
        switch keyword {
        case "fail": return fail(50001)
        case "busy": return fail(42901, headers: ["Retry-After": "10"])
        case "pageerr" where page > 0: return fail(50401)
        default: break
        }
        let share = query["scope"] == "share"
        var rows = state["empty"] != nil ? [] : (share ? shareSamples : selfSamples)
        if let group = query["status_group"] {
            rows = rows.filter { groupOf($0.status) == group }
        }
        if let platform = query["platform"] {
            rows = rows.filter { $0.platform == platform }
        }
        if let month = query["paid_month"] {
            rows = rows.filter { ($0.paidAt ?? $0.depositAt)?.hasPrefix(month) == true }
        }
        if let keyword, keyword != "slow", keyword != "pageerr" {
            rows = search(keyword, share: share, rows: rows)
        }
        let size = 5
        let chunk = Array(rows.dropFirst(page * size).prefix(size))
        let more = rows.count > (page + 1) * size
        let data: [String: Any] = [
            "items": chunk.map { $0.summary() },
            "next_cursor": more ? "page-\(page + 1)" : NSNull(),
            "earliest_visible_date": state["history"].map { $0 as Any } ?? NSNull(),
        ]
        return ok(data, delay: keyword == "slow" ? 3 : 0.3)
    }

    private static func search(_ keyword: String, share: Bool, rows: [Sample]) -> [Sample] {
        if share {
            return rows.filter { !$0.other && ($0.title?.localizedCaseInsensitiveContains(keyword) ?? false) }
        }
        let byNumber = (rows + extraSamples).filter { $0.orderNo == keyword }
        if !byNumber.isEmpty {
            return byNumber
        }
        return rows.filter { $0.title?.localizedCaseInsensitiveContains(keyword) ?? false }
    }

    private static func groupOf(_ status: String) -> String {
        switch status {
        case "DEPOSIT_PAID", "PAID", "WAITING", "CREDITING", "RIGHTS_PENDING", "REVIEWING": "estimating"
        case "CREDITED", "CREDITED_PART_CLAWED": "credited"
        case "NO_REBATE", "INVALID", "CLAWED_BACK": "no_rebate"
        default: "all-only"
        }
    }

    // MARK: - 详情

    private static func detail(_ id: String, _ state: [String: String]) -> Reply {
        guard let sample = (selfSamples + shareSamples + extraSamples).first(where: { $0.id == id }) else {
            return fail(30701)
        }
        return ok(sample.detail(appeal: sample.id == appealSampleId && state["appeal"] != nil))
    }

    // MARK: - 待跟单卡

    private static func pending(_ state: [String: String]) -> Reply {
        guard state["pending"] != nil else { return ok(["items": []]) }
        let closed = lock.withLock { dismissed }
        let items: [[String: Any]] = [
            track("lnk-tb-01", "att-tb-01", "taobao", claim: false, closed: closed.contains("att-tb-01")),
            track("lnk-jd-01", "att-jd-01", "jd", claim: true, closed: closed.contains("att-jd-01")),
            track("lnk-pdd-01", "att-pdd-01", "pdd", claim: false, closed: true),
        ]
        return ok(["items": items])
    }

    private static func track(_ link: String, _ attempt: String, _ platform: String, claim: Bool, closed: Bool)
        -> [String: Any] {
        [
            "link_id": link, "attempt_id": attempt, "platform": platform, "jumped_at": "2026-10-09T10:00:00+08:00",
            "show_claim_entry": claim, "dismissed": closed,
        ]
    }

    private static func dismiss(_ path: String, _ state: [String: String]) -> Reply {
        switch state["dismiss"] {
        case "busy": return fail(42901, headers: ["Retry-After": "10"])
        case "stale": return fail(20001)
        default: break
        }
        let link = path.replacingOccurrences(of: prefix + "/pending-tracks/", with: "")
            .replacingOccurrences(of: "/dismiss", with: "")
        _ = lock.withLock { dismissed.insert(link.replacingOccurrences(of: "lnk-", with: "att-")) }
        return ok([String: Any]())
    }
}
#endif
