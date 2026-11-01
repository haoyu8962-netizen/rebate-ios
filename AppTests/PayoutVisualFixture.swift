@testable import Couli
import CouliNetwork
import Foundation
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-e（收款账号 / 实名 / 劳务协议视觉）三端同一份数据：`specs/wallet-vectors.json` 的 `visualPayout`（G-W25；与 Android 5a795b5
/// 合入版逐字节相同，只在根末尾多这一组）。固定时钟 2026-10-12 10:30 +08:00。实名与劳务是 Debug 手写接口形状（G-W24），不接锁定契约。
enum PayoutVisualData {
    static func root() throws -> [String: Any] {
        let data = try Data(contentsOf: WalletVisualData.repo().appendingPathComponent("specs/wallet-vectors.json"))
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(vectors["visualPayout"] as? [String: Any], "共用向量缺 visualPayout（G-W25）")
    }

    private static func group(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(root()[name] as? [String: Any], "visualPayout 缺 \(name)")
    }

    static func nowMillis() throws -> Int64 {
        let clock = try group("clock")
        return try XCTUnwrap((clock["nowMillis"] as? NSNumber)?.int64Value)
    }

    /// unbound、boundAlipay、boundBank、boundExhausted、boundStress。
    static func payoutBody(_ name: String) throws -> String {
        let all = try group("payout")
        return try WithdrawVisualData.json(XCTUnwrap(all[name], "visualPayout.payout 缺 \(name)"))
    }

    static func form(_ name: String) throws -> [String: String] {
        let all = try group("forms")
        return try XCTUnwrap(all[name] as? [String: String], "visualPayout.forms 缺 \(name)")
    }

    /// changeLimit、verifyLimit、payeeMismatch、accountTaken、busy。
    static func saveError(_ name: String) throws -> (code: Int, data: String) {
        let all = try group("saveErrors")
        return try failure(XCTUnwrap(all[name] as? [String: Any], "visualPayout.saveErrors 缺 \(name)"))
    }

    static func realnameForm() throws -> (name: String, idNo: String) {
        let form = try XCTUnwrap(group("realname")["form"] as? [String: String])
        return try (XCTUnwrap(form["name"]), XCTUnwrap(form["idNo"]))
    }

    /// verifyFailed、idTaken、age、dailyLimit、server、fields。
    static func realnameError(_ name: String) throws -> (code: Int, data: String) {
        let all = try XCTUnwrap(group("realname")["errors"] as? [String: Any])
        return try failure(XCTUnwrap(all[name] as? [String: Any], "realname.errors 缺 \(name)"))
    }

    static func laborFirst() throws -> [String: Any] {
        try XCTUnwrap(group("labor")["first"] as? [String: Any])
    }

    private static func failure(_ raw: [String: Any]) throws -> (code: Int, data: String) {
        try (XCTUnwrap(raw["code"] as? Int), WithdrawVisualData.json(raw["data"] ?? [String: Any]()))
    }
}

/// 收款账号读取的假回答：c 组 `WithdrawVisualServer` 的收款账号报文取自 `visualWithdraw`，本组要 `visualPayout` 的五份，所以包一层：
/// 只接管 `GET /v1/me/payout-account`，其余（rules、写请求、配置）原样交给 c 组假服务。c 组文件零改动。
final class PayoutVisualServer: @unchecked Sendable {
    private let lock = NSLock()
    private let base: WithdrawVisualServer
    private var body: String
    private var override: WalletStubProtocol.Reply?
    private let date: String

    init(base: WithdrawVisualServer, payout: String, nowMillis: Int64) throws {
        self.base = base
        body = try PayoutVisualData.payoutBody(payout)
        date = WalletVisualData.httpDate(nowMillis)
    }

    func set(_ name: String) throws {
        let next = try PayoutVisualData.payoutBody(name)
        lock.withLock { body = next }
    }

    /// 特殊回答（挂起 = 加载中、50001 = 读取失败）；nil = 正常。
    func setRead(_ reply: WalletStubProtocol.Reply?) {
        lock.withLock { override = reply }
    }

    func install() {
        WalletStubProtocol.install { [self] request in
            guard request.method == "GET", request.path == "/v1/me/payout-account" else { return base.reply(request) }
            let (special, text) = lock.withLock { (override, body) }
            return special ?? .envelope(code: 0, data: text, headers: ["Date": date])
        }
    }
}

/// 实名提交的计数后端（生产协议 `RealNameBackend`，Debug 假服务的进程内同形）。只记次数与入参，测试不打印。线程安全。
final class VisualRealNameBackend: RealNameBackend, @unchecked Sendable {
    struct Call {
        let name: String
        let idNo: String
        let key: String
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var reply: ApiResult = .success(data: Data("{\"realname_status\":\"verified\"}".utf8),
                                            traceId: "visual", idempotencyKey: nil)
    private var holding = false

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func fail(_ code: Int, data: String = "{}") {
        let failed = visualFailure(code, data: data)
        lock.withLock { reply = failed }
    }

    /// 挂起提交（提交中的镜头）；`release` 放行。
    func hold() {
        lock.withLock { holding = true }
    }

    func release() {
        lock.withLock { holding = false }
    }

    func submit(name: String, idNo: String, idempotencyKey: String, owner _: RequestOwnership?) async -> ApiResult {
        lock.withLock { recorded.append(Call(name: name, idNo: idNo, key: idempotencyKey)) }
        while lock.withLock({ holding }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return lock.withLock { reply }
    }
}

/// 劳务协议的计数后端（生产协议 `LaborBackend`）。协议内容来自 visualPayout.labor.first。线程安全。
final class VisualLaborBackend: LaborBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var recorded: [(version: String, sha: String)] = []
    private var content: ApiResult
    private var signReply: ApiResult = .success(data: Data("{}".utf8), traceId: "visual", idempotencyKey: nil)
    private var holdingRead = false
    private var holdingSign = false

    init() throws {
        content = try .success(data: Data(WithdrawVisualData.json(PayoutVisualData.laborFirst()).utf8),
                               traceId: "visual", idempotencyKey: nil)
    }

    var readCount: Int {
        lock.withLock { reads }
    }

    var signs: [(version: String, sha: String)] {
        lock.withLock { recorded }
    }

    func failRead(_ code: Int) {
        let failed = visualFailure(code)
        lock.withLock { content = failed }
    }

    func failSign(_ code: Int) {
        let failed = visualFailure(code)
        lock.withLock { signReply = failed }
    }

    func holdRead() {
        lock.withLock { holdingRead = true }
    }

    func holdSign() {
        lock.withLock { holdingSign = true }
    }

    func release() {
        lock.withLock {
            holdingRead = false
            holdingSign = false
        }
    }

    func current(owner _: RequestOwnership?) async -> ApiResult {
        lock.withLock { reads += 1 }
        while lock.withLock({ holdingRead }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return lock.withLock { content }
    }

    func sign(version: String, textSha256: String, owner _: RequestOwnership?) async -> ApiResult {
        lock.withLock { recorded.append((version, textSha256)) }
        while lock.withLock({ holdingSign }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return lock.withLock { signReply }
    }
}

/// 与 Debug 假服务同形的失败结果。
func visualFailure(_ code: Int, data: String = "{}") -> ApiResult {
    .failure(code: code, msg: "", data: Data(data.utf8), traceId: "visual-trace-\(code)00",
             effect: ErrorEffect(code: code, kind: .toast), idempotencyKey: nil)
}

extension WithdrawVisualHost {
    var realName: RealNameController? {
        destination.flatMap { wallet.pages[$0.id]?.controller as? RealNameController }
    }

    var laborPage: LaborAgreementController? {
        destination.flatMap { wallet.pages[$0.id]?.controller as? LaborAgreementController }
    }

    var payoutActions: PayoutActions? {
        payout.map { PayoutActions.make($0, $0.state, risk: $0.flow.state.riskDialog?.id) }
    }

    var realNameActions: RealNameActions? {
        realName.map { RealNameActions.make($0, $0.state) }
    }

    var laborActions: LaborActions? {
        laborPage.map { LaborActions.make($0, $0.state) }
    }

    /// 未过期的 step-up 令牌（跳过二次验证半屏，它归 d 组）。
    func grantStepUp() {
        wallet.deps.tokens.put(action: "payout_account_change", account: "user-a", token: "t", expireAtMs: .max)
    }
}
