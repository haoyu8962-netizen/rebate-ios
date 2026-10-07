import Foundation

/// 一致性页的必测用例清单（APP-04 三端共性第 55 条：结果集为空或缺少必测用例时判失败）。
///
/// 来源：rebate-platform 9cd1e6f 的 `apps/h5/src/entries/conformance/cases.ts`
/// （`buildCaseTable` → `casesForPlatform(…, "ios")`，不带 `cases`
/// 查询）按本仓契约快照（`contracts/snapshot/contracts/bridge.schema.json`、`apps.json`，contract.lock 锁定
/// 9cd1e6f）逐条推出：每个方法的 normal / timeout / bad_params / no_gesture / negative/logged_out / unsupported 行、未知方法、
/// trade_only 与 platform_link / share_domain 白名单负面行、子框架探针；只限 android / harmony 的行不在 iOS 跑，已去掉。
/// 共 91 条，与 iOS 一致性结果 `result-logged-in-after-taps.json` 的用例集逐条相同。契约或一致性页升级时同步更新本清单。
enum BridgeConformanceCaseList {
    /// trigger 为 harness 的用例：由测试桩控制，一致性页本身不跑，允许（且必须）保持待定。必须出现在结果里。
    static let harness: [String] = [
        "auth.getH5Token/negative/logged_out",
        "auth.getH5Token/timeout",
        "auth.getUser/negative/logged_out",
        "auth.getUser/timeout",
        "clipboard.read/negative/logged_out",
        "clipboard.read/timeout",
        "cs.open/timeout",
        "ext.openApp/negative/logged_out",
        "ext.openApp/timeout",
        "media.saveImage/negative/logged_out",
        "nav.open/timeout",
        "net.signedRequest/negative/logged_out",
        "net.signedRequest/timeout",
        "perm.getPushStatus/timeout",
        "perm.request/negative/logged_out",
        "share.open/negative/logged_out",
        "trade.authorize/negative/logged_out",
        "trade.convertAndOpen/negative/logged_out",
        "trade.openProduct/timeout",
    ]

    /// 其余必测用例：必须出现在结果里，并逐项按预期断言。
    static let required: [String] = [
        "app.getConfig/bad_params",
        "app.getConfig/normal",
        "app.getEnv/normal",
        "auth.getH5Token/normal",
        "auth.getUser/normal",
        "auth.login/normal",
        "clipboard.read/no_gesture",
        "clipboard.read/normal",
        "clipboard.setAutoDetect/bad_params",
        "clipboard.setAutoDetect/normal",
        "clipboard.write/bad_params",
        "clipboard.write/no_gesture",
        "clipboard.write/normal",
        "conformance.notAMethod/unsupported",
        "cs.open/bad_params",
        "cs.open/normal",
        "ext.openApp/bad_params",
        "ext.openApp/negative/trade_only/jd",
        "ext.openApp/negative/trade_only/pdd",
        "ext.openApp/negative/trade_only/taobao",
        "ext.openBrowser/bad_params",
        "ext.openBrowser/negative/platform_link/taobao.example.test/base",
        "ext.openBrowser/negative/platform_link/taobao.example.test/default_port",
        "ext.openBrowser/negative/platform_link/taobao.example.test/host_case",
        "ext.openBrowser/negative/platform_link/taobao.example.test/percent_host",
        "ext.openBrowser/negative/platform_link/taobao.example.test/percent_path",
        "ext.openBrowser/negative/platform_link/taobao.example.test/trailing_dot",
        "ext.openBrowser/normal",
        "ext.openMiniProgram/unsupported",
        "frame/negative/subframe",
        "media.previewImage/bad_params",
        "media.previewImage/normal",
        "media.saveImage/bad_params",
        "media.saveImage/normal",
        "media.scan/unsupported",
        "media.uploadImage/unsupported",
        "nav.close/normal",
        "nav.open/bad_params",
        "nav.open/normal",
        "net.signedRequest/bad_params",
        "net.signedRequest/no_gesture",
        "net.signedRequest/normal",
        "perm.getPushStatus/normal",
        "perm.request/bad_params",
        "perm.request/normal",
        "share.open/bad_params",
        "share.open/negative/platform_link/taobao.example.test/base",
        "share.open/negative/platform_link/taobao.example.test/default_port",
        "share.open/negative/platform_link/taobao.example.test/host_case",
        "share.open/negative/platform_link/taobao.example.test/percent_host",
        "share.open/negative/platform_link/taobao.example.test/percent_path",
        "share.open/negative/platform_link/taobao.example.test/trailing_dot",
        "share.open/negative/share_domain/s.example.test/not_share_page",
        "share.open/normal",
        "track.event/bad_params",
        "track.event/normal",
        "trade.authorize/bad_params",
        "trade.authorize/no_gesture",
        "trade.authorize/normal",
        "trade.convertAndOpen/bad_params",
        "trade.convertAndOpen/no_gesture",
        "trade.convertAndOpen/normal",
        "trade.openProduct/bad_params",
        "trade.openProduct/normal",
        "trade.openUnionActivity/unsupported",
        "ui.hideLoading/normal",
        "ui.setNavBar/bad_params",
        "ui.setNavBar/normal",
        "ui.showLoading/bad_params",
        "ui.showLoading/normal",
        "ui.toast/bad_params",
        "ui.toast/normal",
    ]

    /// 结果里的用例 ID 与清单是否一致：返回发现的问题（空 = 完整、无重复、无清单外用例）。
    static func completenessProblems(_ ids: [String]) -> [String] {
        var problems: [String] = []
        if ids.isEmpty {
            problems.append("结果集为空")
        }
        var seen: Set<String> = []
        let duplicates = Set(ids.filter { !seen.insert($0).inserted })
        if !duplicates.isEmpty {
            problems.append("重复的用例：\(duplicates.sorted())")
        }
        let expected = Set(required + harness)
        let missing = expected.subtracting(seen)
        if !missing.isEmpty {
            problems.append("缺少必测用例：\(missing.sorted())")
        }
        let extra = seen.subtracting(expected)
        if !extra.isEmpty {
            problems.append("清单外的用例（契约或一致性页已变，先更新清单）：\(extra.sorted())")
        }
        return problems
    }
}

/// 一致性页结果里的一条用例（`__RESULT__.cases[]` 的精简形）。
struct ConformanceCase: CustomStringConvertible {
    let id: String
    let method: String
    let category: String
    let trigger: String
    let pass: Bool?
    let outcome: [String: Any]?

    var code: Int? {
        outcome?["code"] as? Int
    }

    var ok: Bool? {
        outcome?["ok"] as? Bool
    }

    var description: String {
        let passed = pass.map(String.init) ?? "nil"
        return "\(id) trigger=\(trigger) pass=\(passed) outcome=\(outcome.map { "\($0)" } ?? "nil")"
    }
}

/// 一致性页的 `__RESULT__`。
struct ConformanceReport {
    let status: String
    let unknownCases: [Any]
    let cases: [ConformanceCase]

    func item(_ id: String) -> ConformanceCase? {
        cases.first { $0.id == id }
    }

    init(status: String, unknownCases: [Any] = [], cases: [ConformanceCase]) {
        self.status = status
        self.unknownCases = unknownCases
        self.cases = cases
    }

    init?(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = object["cases"] as? [[String: Any]]
        else { return nil }
        status = object["status"] as? String ?? ""
        unknownCases = object["unknown_cases"] as? [Any] ?? []
        cases = items.map { item in
            ConformanceCase(
                id: item["id"] as? String ?? "",
                method: item["method"] as? String ?? "",
                category: item["category"] as? String ?? "",
                trigger: item["trigger"] as? String ?? "",
                pass: item["pass"] as? Bool,
                outcome: item["outcome"] as? [String: Any]
            )
        }
    }
}

/// 一致性结果的判定：先校验用例 ID 完整（`BridgeConformanceCaseList`），再按清单逐项断言。返回全部失败说明（空 = 通过）。
enum BridgeConformanceExpectations {
    /// 本任务不实现、协议判定通过后返回 90001 的方法（BridgeHost.notImplementedTasks 与 since 为 null 的 P1 方法）。
    static let notImplemented: Set<String> = [
        "trade.openProduct", "trade.convertAndOpen", "trade.authorize", "trade.openUnionActivity",
        "ext.openApp", "ext.openBrowser", "ext.openMiniProgram", "share.open",
        "media.saveImage", "media.previewImage", "media.scan", "media.uploadImage", "cs.open",
    ]

    static let notSupported = 90001
    static let timeout = 90003

    /// 受环境限制的预期例外（id → 规定的错误码与原因），其余失败一律让测试失败。这些用例登记为未完成（not_done）。
    static let environmentExceptions: [String: (code: Int, reason: String)] = [
        "auth.getUser/normal": (timeout, "无后端：Debug 环境地址是保留域，ApiClient 传输失败按超时结束"),
        "auth.getH5Token/normal": (timeout, "无后端：同上"),
        "net.signedRequest/normal": (
            notSupported, "openapi 9cd1e6f 没有 signed_paths 里的 POST /v1/orders/claims，按本端不支持结束（TODO(N-22)）"
        ),
        // 一致性页 9cd1e6f 不含这一条；若以后出现，只能是 90001（App 固定浅色界面，做不到 light 状态栏，capability-ios.md）。
        "ui.setNavBar/status_bar_light": (notSupported, "status_bar_style=light 本端做不到，整次调用 90001"),
    ]

    /// `skipping`：由单独测试断言的用例（仍须出现在结果里，只是这里不逐项判）。
    static func failures(_ report: ConformanceReport, skipping: Set<String>) -> [String] {
        var failures = BridgeConformanceCaseList.completenessProblems(report.cases.map(\.id))
        if report.status != "done" {
            failures.append("status 应为 done：\(report.status)")
        }
        if !report.unknownCases.isEmpty {
            failures.append("页面上有未知用例：\(report.unknownCases)")
        }
        for id in BridgeConformanceCaseList.harness {
            if let item = report.item(id), item.outcome != nil {
                failures.append("\(id)：harness 用例由测试桩控制，一致性页不跑。\(item)")
            }
        }
        for id in BridgeConformanceCaseList.required where !skipping.contains(id) {
            guard let item = report.item(id) else {
                failures.append("\(id)：结果里没有这条必测用例")
                continue
            }
            if let failure = failure(item) {
                failures.append(failure)
            }
        }
        return failures
    }

    /// 一条必测用例按预期判定；通过返回 nil。
    static func failure(_ item: ConformanceCase) -> String? {
        let method = item.id.split(separator: "/").first.map(String.init) ?? item.method
        if let exception = environmentExceptions[item.id] {
            return item.code == exception.code ? nil : "\(item.id)（预期例外：\(exception.reason)）\(item)"
        }
        if notImplemented.contains(method), item.id == "\(method)/normal" {
            return item.code == notSupported ? nil : "\(item.id)：未实现的方法应返回 90001。\(item)"
        }
        return item.pass == true ? nil : "\(item.id) 应通过：\(item)"
    }
}
