@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Wallet
import WalletCore
import XCTest

/// APP-09v-b（提现记录视觉）三端同一份截图数据：`specs/wallet-vectors.json` 的 `visualWithdrawRecords`（G-W25；与 Android 49a1eb9
/// 合入版逐字节相同，只在根末尾多这一组，原 22 组与 a 的 visualWallet 不动）。固定时钟 2026-10-12 10:30 +08:00。只读，不写回共用文件。
enum RecordsVisualData {
    static func root() throws -> [String: Any] {
        let data = try Data(contentsOf: WalletVisualData.repo().appendingPathComponent("specs/wallet-vectors.json"))
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(vectors["visualWithdrawRecords"] as? [String: Any], "共用向量缺 visualWithdrawRecords（G-W25）")
    }

    /// 一份列表报文（`{"items": [...], "next_cursor": ...}`）。
    static func page(_ name: String) throws -> [String: Any] {
        let pages = try XCTUnwrap(root()["pages"] as? [String: Any])
        return try XCTUnwrap(pages[name] as? [String: Any], "visualWithdrawRecords.pages 缺 \(name)")
    }

    /// 一份详情报文（带 channel_order_id）。
    static func detail(_ name: String) throws -> [String: Any] {
        let details = try XCTUnwrap(root()["details"] as? [String: Any])
        return try XCTUnwrap(details[name] as? [String: Any], "visualWithdrawRecords.details 缺 \(name)")
    }

    /// 全部详情，按 withdrawal_id 索引（展开时假服务按单号回答）。
    static func detailsById() throws -> [String: [String: Any]] {
        let details = try XCTUnwrap(root()["details"] as? [String: Any])
        var out: [String: [String: Any]] = [:]
        for case let object as [String: Any] in details.values {
            if let id = object["withdrawal_id"] as? String {
                out[id] = object
            }
        }
        return out
    }

    static func nowMillis() throws -> Int64 {
        let clock = try XCTUnwrap(root()["clock"] as? [String: Any])
        return try XCTUnwrap((clock["nowMillis"] as? NSNumber)?.int64Value)
    }

    /// 同月 `count` 条（分页 / 锚点用）：照拷 `pending` 列表项，只换 ID 与申请时间（10 月内逐条早一小时），金额、枚举保持原报文值
    /// （同 Android v2 `WithdrawRecordsV2Fixtures` 做法；不写回共用文件）。ID 为 `prefix` + 两位序号（从 `start` 起）。
    static func sameMonth(_ count: Int, start: Int = 1, prefix: String = "R") throws -> [[String: Any]] {
        let base = try XCTUnwrap((page("pending")["items"] as? [[String: Any]])?.first)
        return (0..<count).map { offset in
            let index = start + offset
            var item = base
            item["withdrawal_id"] = String(format: "%@%02d", prefix, index)
            // 10-11 23:00 起逐条早一小时：60 条仍都在 10 月
            let hour = 23 - (index % 24)
            let day = 11 - index / 24
            item["created_at"] = String(format: "2026-10-%02dT%02d:00:00+08:00", day, hour)
            return item
        }
    }

    /// `sameMonth` 派生单的详情（v2 / T2）：照拷 `details.pending`，只换 ID 与申请时间（与派生列表项逐条一致），展开时假服务按单号
    /// 回答详情，不回 30701。金额、枚举、流水号等保持原报文值；不写回共用文件。
    static func sameMonthDetails(_ count: Int, start: Int = 1, prefix: String = "R") throws -> [String: [String: Any]] {
        let base = try detail("pending")
        var out: [String: [String: Any]] = [:]
        for item in try sameMonth(count, start: start, prefix: prefix) {
            let id = try XCTUnwrap(item["withdrawal_id"] as? String)
            var object = base
            object["withdrawal_id"] = id
            object["created_at"] = item["created_at"]
            out[id] = object
        }
        return out
    }

    static func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(bytes: data, encoding: .utf8))
    }

    static func money(_ fen: Int64) -> String {
        WalletVisualFormat.money(fen)
    }
}

/// 提现记录视觉的本地假服务（生产同一个 WalletStubProtocol）：列表按 `cursor` 查询参数分页回答，详情按单号回答（没有的回 30701），
/// 其余接口照 `WalletScript.fallback`。每个回答带固定时钟的 `Date` 响应头（生产 ApiClient 据此校准显示时钟，「今天 10:00」）。
/// 线程安全（URLProtocol 在任意线程调用）。
final class RecordsVisualServer: @unchecked Sendable {
    private let lock = NSLock()
    /// 游标 → 列表报文（"" = 第一页）。
    private var pages: [String: String] = [:]
    private var details: [String: String] = [:]
    /// 第一页 / 翻页的特殊回答（挂起、失败、断网）；nil = 正常按 `pages` 回答。
    private var firstOverride: WalletStubProtocol.Reply?
    private var moreOverride: WalletStubProtocol.Reply?
    private let date: String

    init(nowMillis: Int64) {
        date = WalletVisualData.httpDate(nowMillis)
    }

    func setPage(_ object: [String: Any], cursor: String = "") throws {
        let body = try RecordsVisualData.json(object)
        lock.withLock { pages[cursor] = body }
    }

    func setPage(_ cursor: String = "", items: [[String: Any]], next: String?) throws {
        try setPage(["items": items, "next_cursor": next.map { $0 as Any } ?? NSNull()], cursor: cursor)
    }

    func setDetails(_ objects: [String: [String: Any]]) throws {
        let encoded = try objects.mapValues { try RecordsVisualData.json($0) }
        lock.withLock { details.merge(encoded) { $1 } }
    }

    func setFirst(_ reply: WalletStubProtocol.Reply?) {
        lock.withLock { firstOverride = reply }
    }

    func setMore(_ reply: WalletStubProtocol.Reply?) {
        lock.withLock { moreOverride = reply }
    }

    func install() {
        WalletStubProtocol.install { [self] request in reply(request) }
    }

    static func cursor(_ query: String) -> String? {
        for part in query.split(separator: "&") where part.hasPrefix("cursor=") {
            return String(part.dropFirst("cursor=".count)).removingPercentEncoding
        }
        return nil
    }

    func reply(_ request: WalletStubProtocol.Recorded) -> WalletStubProtocol.Reply {
        let headers = ["Date": date]
        if request.method == "GET", request.path == "/v1/withdrawals" {
            let cursor = Self.cursor(request.query)
            let (override, body) = lock.withLock {
                (cursor == nil ? firstOverride : moreOverride, pages[cursor ?? ""])
            }
            if let override {
                return override
            }
            guard let body else { return .envelope(code: 50001, data: "null", headers: headers) }
            return .envelope(code: 0, data: body, headers: headers)
        }
        if request.method == "GET", request.path.hasPrefix("/v1/withdrawals/"),
           request.path != "/v1/withdrawals/rules" {
            let id = String(request.path.dropFirst("/v1/withdrawals/".count)).removingPercentEncoding ?? ""
            guard let body = lock.withLock({ details[id] }) else {
                return .envelope(code: 30701, data: "null", headers: headers)
            }
            return .envelope(code: 0, data: body, headers: headers)
        }
        return WalletScript.fallback(request)
    }

    /// 列表请求（第一页与翻页）的查询串，按发生顺序。
    static var listQueries: [String] {
        WalletStubProtocol.requests("GET", "/v1/withdrawals").map(\.query)
    }

    /// 带 cursor 的翻页请求数。
    static var moreRequests: Int {
        listQueries.filter { cursor($0) != nil }.count
    }
}
