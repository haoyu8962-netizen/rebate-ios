@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Generated
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-c（提现页视觉）三端同一份截图数据：`specs/wallet-vectors.json` 的 `visualWithdraw`（G-W25；与 Android 6770a58 合入版逐字节相同，
/// 只在根末尾多这一组）。固定时钟 2026-10-12 10:30 +08:00。只读，不写回共用文件。
enum WithdrawVisualData {
    static func root() throws -> [String: Any] {
        let data = try Data(contentsOf: WalletVisualData.repo().appendingPathComponent("specs/wallet-vectors.json"))
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(vectors["visualWithdraw"] as? [String: Any], "共用向量缺 visualWithdraw（G-W25）")
    }

    static func rules(_ name: String) throws -> [String: Any] {
        let all = try XCTUnwrap(root()["rules"] as? [String: Any])
        return try XCTUnwrap(all[name] as? [String: Any], "visualWithdraw.rules 缺 \(name)")
    }

    static func payout(_ name: String) throws -> [String: Any] {
        let all = try XCTUnwrap(root()["payout"] as? [String: Any])
        return try XCTUnwrap(all[name] as? [String: Any], "visualWithdraw.payout 缺 \(name)")
    }

    static func nowMillis() throws -> Int64 {
        let clock = try XCTUnwrap(root()["clock"] as? [String: Any])
        return try XCTUnwrap((clock["nowMillis"] as? NSNumber)?.int64Value)
    }

    /// PageStates 证据稿的全部规则名（21 个 code / reason）。
    static func pageStates() throws -> [String] {
        try XCTUnwrap(root()["pageStates"] as? [String])
    }

    static func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(bytes: data, encoding: .utf8))
    }

    static func money(_ fen: Int64) -> String {
        WalletVisualFormat.money(fen)
    }

    /// 带 `help_links.withdraw_rules` 与时效句的配置报文（包内 DefaultConfig 上只改这两处；`sla` 为 nil = 不下发，回落 BR-TEXT-07）。
    static func config(help: Bool, sla: String?) throws -> String {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(DefaultConfig.json.utf8)) as? [String: Any]
        )
        var links = object["help_links"] as? [String: Any] ?? [:]
        if help {
            links["withdraw_rules"] = ["route": "Help", "params": ["article_id": articleId]]
        }
        object["help_links"] = links
        object["texts"] = sla.map { ["withdraw.sla_text": $0] } ?? [String: String]()
        return try json(object)
    }

    static let articleId = "withdraw-rules-fixture"
}

/// 截图是否真的画出了页面（v2 / T3）：实现者实测 8400 物理像素高的图 drawHierarchy 整张黑，而「两帧一致」对全黑也成立，全黑图曾被录成绿基准。
/// 页面任何状态（含深色画布 #171513、遮罩下）都不是纯黑，也不是单一颜色，所以这两条对真页面恒成立。
enum WithdrawVisualRenderJudge {
    /// 渲染上限（实测 8100 正常、8400 全黑；按 CoreAnimation 常见上限取 8192）。
    static let maxPixels: CGFloat = 8192

    static func problems(_ image: UIImage) -> [String] {
        var out: [String] = []
        let pixelHeight = image.size.height * image.scale
        if pixelHeight > maxPixels {
            out.append("图高 \(pixelHeight) 物理像素超过渲染上限 \(maxPixels)")
        }
        let sample = ProductVisualPixels(image).fingerprint()
        let black = sample.filter { $0.red == 0 && $0.green == 0 && $0.blue == 0 }.count
        if black * 2 >= sample.count {
            out.append("纯黑取样 \(black) / \(sample.count)：没有画出页面")
        }
        let colors = Set(sample.map { "\($0.red),\($0.green),\($0.blue)" })
        if colors.count < 8 {
            out.append("取样只有 \(colors.count) 种颜色：没有画出页面")
        }
        return out
    }
}

/// 提现视觉的本地假服务（生产同一个 WalletStubProtocol）：rules 分「不带金额」「带 amount_fen（估算）」两路回答，收款账号按报文回答，
/// 其余接口走 `WalletScript`（可排队给提交、确认、放弃的结局）。rules / 收款账号带固定时钟的 Date。线程安全（URLProtocol 在任意线程调用）。
final class WithdrawVisualServer: @unchecked Sendable {
    let script = WalletScript()
    private let lock = NSLock()
    private var rules = "{}"
    private var estimate: String?
    private var payout = "{}"
    private var firstOverride: WalletStubProtocol.Reply?
    private var estimateOverride: WalletStubProtocol.Reply?
    private let date: String

    init(nowMillis: Int64) {
        date = WalletVisualData.httpDate(nowMillis)
    }

    func setRules(_ name: String) throws {
        let body = try WithdrawVisualData.json(WithdrawVisualData.rules(name))
        lock.withLock { rules = body }
    }

    func setEstimate(_ name: String?) throws {
        let body = try name.map { try WithdrawVisualData.json(WithdrawVisualData.rules($0)) }
        lock.withLock { estimate = body }
    }

    func setPayout(_ name: String) throws {
        let body = try WithdrawVisualData.json(WithdrawVisualData.payout(name))
        lock.withLock { payout = body }
    }

    /// 不带金额的 rules 的特殊回答（挂起 = 加载中、50001 = 读取失败）；nil = 正常。
    func setFirst(_ reply: WalletStubProtocol.Reply?) {
        lock.withLock { firstOverride = reply }
    }

    /// 带金额的 rules 的特殊回答（挂起 = 计算中、50001 = 估算读取失败）；nil = 正常。
    func setEstimateReply(_ reply: WalletStubProtocol.Reply?) {
        lock.withLock { estimateOverride = reply }
    }

    func install() {
        WalletStubProtocol.install { [self] request in reply(request) }
    }

    func reply(_ request: WalletStubProtocol.Recorded) -> WalletStubProtocol.Reply {
        let headers = ["Date": date]
        if request.method == "GET", request.path == "/v1/withdrawals/rules" {
            let amount = request.query.contains("amount_fen=")
            let (override, body) = lock.withLock {
                (amount ? estimateOverride : firstOverride, amount ? (estimate ?? rules) : rules)
            }
            return override ?? .envelope(code: 0, data: body, headers: headers)
        }
        if request.method == "GET", request.path == "/v1/me/payout-account" {
            return .envelope(code: 0, data: lock.withLock { payout }, headers: headers)
        }
        return script.reply(request)
    }
}
