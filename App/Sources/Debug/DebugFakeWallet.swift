#if DEBUG
import CouliNetwork
import CryptoKit
import Foundation
import SecureStore
import WalletCore

/// 本机假服务的钱包场景（APP-09 截图、冒烟与设计稿比对用；只在 Debug / Staging 编译，APP-04 共性 2）。由 `DebugFakeLoginServer`（启动参数
/// `-CouliFakeLoginServer`）接管时回答；Release 制品扫描查 `marker` 与类型名。全部在本机回答，不连任何地址，不做真实提现与真实实名核验。
/// 数据照设计稿 sample-data §12（与 Android DebugFakeWallet 同一份：可提现 ¥12.34、已提现 ¥5、预估 ¥56.78、已收货 ¥34.56、暂缓 ¥4.56、
/// 最早 10 月；提现记录 10 月 ¥10 审核中、¥8 打款未成功，9 月 ¥5 已到账、¥6 未通过；收款账号支付宝 138****5678、收款人 **三）。姓名、身份证号、
/// 卡号、登录号一律不落盘、不打印。
///
/// - 签名、step-up、幂等走网络层真实管线，只把传输层换成本服务：createWithdrawal / savePayoutAccount 没带有效 X-Step-Up-Token 回 10003；同一
///   Idempotency-Key 回同一结果；作废接口按键回 abandoned 或 completed（原结果）；二次验证码 123456 通过，200030 → 20003，其余 → 20002。
/// - 实名与劳务协议（契约没有接口，G01 / G02）：只由本服务在进程内实现，不经网络管线。
///
/// 开关（启动参数 `-CouliFakeWallet wallet=frozen,payout=none,…`）：wallet=normal|frozen|negative|risk|disabled|new；
/// offline=1；realname=none；payout=none|bank；labor=unsigned；records=empty|empty_once（第一次列表读取为空，之后带一张 W-call-<序号>）；
/// submit=unknown_created|unknown_lost|44001|30303|busy|5xxxx；save=unknown_created|30307|44001；
/// rules=below_min|feature_off|negative|5xxxx|5xxxx_after_submit；payout_read=5xxxx|5xxxx_after_save；me=5xxxx；
/// abandon=busy；step_up=always；outcome=<3xxxx>（提交 / 保存的业务结局，配合 unknown_created：确认回该错误、作废回 completed 原结果为该错误）；
/// confirm=20903（unknown_lost 丢在路上的键再次发送时回 20903）。`*_after_submit` / `*_after_save`：收到第一次提交 / 保存之后读取才失败
/// （先进入待确认、再让读取持续失败，iOS R2-02）。
/// 结果未知分两种（iOS R1-02）：unknown_lost =「请求未到达」——带有效 token 的提交在服务端任何处理之前丢在路上，不建单、不记幂等结果、
/// 不核销 token；unknown_created =「响应丢失」——建单与幂等结果在同一把锁里一起保存，之后才丢响应（确认返回原结果、作废返回 completed）。
final class DebugFakeWallet: @unchecked Sendable {
    static let marker = "COULI_FAKE_WALLET_SERVER_APP09_IOS_8d3c52"
    static let launchArgument = "CouliFakeWallet"
    static let phone = "13800005678"
    static let shared = DebugFakeWallet()

    enum Reply {
        case answer(code: Int, data: String, headers: [String: String])
        /// 传输失败（断网、响应丢失）。
        case offline
    }

    let lock = NSLock()
    var results: [String: (code: Int, data: String)] = [:]
    var validTokens: Set<String> = []
    var created: [[String: Any]] = []
    var realnameVerified: Bool?
    var laborSigned: Bool?
    var payout: [String: Any]?
    var payoutInitialized = false
    var serial = 0
    /// 收到过提交 / 保存（`rules=5xxxx_after_submit`、`payout_read=5xxxx_after_save` 据此开始失败）。
    var submitSeen = false
    var saveSeen = false
    /// unknown_lost 丢在路上的键（`confirm=20903` 时再次发送回 20903）。
    var lostKeys: Set<String> = []
    /// `records=empty_once` 时收到的列表读取次数（iOS R3-02）。
    var listCalls = 0

    /// 把假服务接到 App（只在假登录服务打开时）：测试号码、假实名与假劳务协议后端。
    @MainActor
    static func install(_ wallet: AppWallet, arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains(DebugFakeLoginServer.launchArgument) else { return }
        wallet.phoneProvider = { _ in phone }
        wallet.installBackends(realname: FakeRealName(fake: shared), labor: FakeLabor(fake: shared))
    }

    /// 假服务冷启动时的假账号（`-CouliFakeTradeLoggedIn`）。
    static let fakeAccount = "debug-fake-user"
    /// 截图清场参数（iOS R1-01，rule-gaps I15 更正）：只由截图 / 冒烟 UI 测试的独立夹具显式传入。正常启动、冷启动恢复都不带它，未决记录照常保留
    /// （brief §0 第 3 条：未决记录不过期、冷启动恢复待确认，不能生成新键）。
    static let resetPendingArgument = "-CouliFakeWalletResetPending"

    /// 假服务冷启动、网络层建好之前调用：默认什么都不清；只有带 `resetPendingArgument` 时才清假账号的未决记录与金额草稿（截图从干净状态开始）。
    static func prepareColdStart(
        arguments: [String],
        backend: @autoclosure () -> PendingKeyBackend = SecurePendingKeyBackend(store: KeychainStore()),
        draftRoot: @autoclosure () -> URL = WalletCacheStore.defaultRoot()
    ) {
        guard arguments.contains(resetPendingArgument) else { return }
        clearPending(account: fakeAccount, backend: backend(), draftRoot: draftRoot())
    }

    /// 清掉假账号的未决记录（只由 `prepareColdStart` 在显式清场时调用）。
    /// 同时删掉上一次场景留下的提现金额草稿（进程被结束时草稿按设计保留，iOS I06），截图从空金额框开始；摘要缓存保留（WalletStale 要用）。
    static func clearPending(account: String, backend: PendingKeyBackend, draftRoot: URL) {
        for record in (try? backend.loadAll(account: account)) ?? [] {
            try? backend.delete(account: account, key: record.key)
        }
        let draft = draftRoot
            .appendingPathComponent(WalletCacheStore.hash(account), isDirectory: true)
            .appendingPathComponent(WalletCacheStore.draftFile)
        try? FileManager.default.removeItem(at: draft)
    }

    var options: [String: String] {
        var out: [String: String] = [:]
        for part in (UserDefaults.standard.string(forKey: Self.launchArgument) ?? "").split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            out[pair[0]] = pair.count == 2 ? pair[1] : "1"
        }
        return out
    }

    /// 回答钱包类路径；不是本服务的为 nil。
    func answer(method: String, path: String, query: [String: String], body: [String: Any],
                headers: [String: String]) -> Reply? {
        let mine = path.hasPrefix("/v1/wallet/") || path.hasPrefix("/v1/withdrawals") || path == "/v1/me"
            || path == "/v1/me/payout-account" || path == "/v1/auth/step-up" || path == "/v1/idempotency-keys/abandon"
        guard mine else { return nil }
        let state = options
        if state["offline"] != nil, path != "/v1/idempotency-keys/abandon", path != "/v1/me" {
            return .offline
        }
        return lock.withLock { route(method: method, path: path, query: query, body: body, headers: headers, state) }
    }

    // swiftlint:disable:next function_parameter_count
    private func route(method: String, path: String, query: [String: String], body: [String: Any],
                       headers: [String: String], _ state: [String: String]) -> Reply {
        switch path {
        case "/v1/me":
            // me=5xxxx：打开资金页前的实名查询失败（打开错误卡，iOS R1-08）
            return state["me"] == "5xxxx" ? fail(50001) : ok(me(state))
        case "/v1/wallet/summary":
            return ok(summary(state["wallet"]))
        case "/v1/withdrawals/rules":
            // rules=5xxxx：rules 读取失败（待确认卡独立于读取状态，iOS R1-03）
            let rulesDown = state["rules"] == "5xxxx" || (state["rules"] == "5xxxx_after_submit" && submitSeen)
            return rulesDown ? fail(50001)
                : ok(rules(state, amount: query["amount_fen"].flatMap { Int64($0) }))
        case "/v1/withdrawals":
            return method == "POST" ? submit(state, body, headers) : list(state, query)
        case "/v1/me/payout-account":
            if method == "PUT" {
                return save(state, body, headers)
            }
            let readDown = state["payout_read"] == "5xxxx" || (state["payout_read"] == "5xxxx_after_save" && saveSeen)
            return readDown ? fail(50001) : ok(payoutAccount(state) ?? [String: Any]())
        case "/v1/auth/step-up":
            return stepUp(body)
        case "/v1/idempotency-keys/abandon":
            return abandon(state, body)
        default:
            let id = String(path.dropFirst("/v1/withdrawals/".count)).removingPercentEncoding ?? ""
            return detail(id)
        }
    }

    func ok(_ object: Any) -> Reply {
        .answer(code: 0, data: Self.json(object), headers: [:])
    }

    func fail(_ code: Int, data: String = "null", headers: [String: String] = [:]) -> Reply {
        .answer(code: code, data: data, headers: headers)
    }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        else { return "null" }
        return String(bytes: data, encoding: .utf8) ?? "null"
    }

    static func header(_ headers: [String: String], _ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func me(_ state: [String: String]) -> [String: Any] {
        [
            "user_id": "debug-user", "realname_status": realname(state) ? "verified" : "none",
            "phone_bound": DebugFakeOAuth.shared.phoneBound,
            "risk": ["state": "normal"], "need_reconsent": false,
        ]
    }

    func realname(_ state: [String: String]) -> Bool {
        realnameVerified ?? (state["realname"] != "none")
    }

    func labor(_ state: [String: String]) -> Bool {
        laborSigned ?? (state["labor"] != "unsigned")
    }
}
#endif
