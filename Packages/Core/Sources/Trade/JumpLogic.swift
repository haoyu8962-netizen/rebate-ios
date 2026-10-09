import Foundation
import Generated

/// 跳转方案的执行结果。
public struct JumpRun: Equatable, Sendable {
    /// 实际执行到的步骤类型（按顺序，含初始化失败的 sdk）。
    public let executed: [String]
    /// opened（拉起 App）/ browser（系统浏览器）/ copied / not_installed（未装、复制口令后仍提示安装）/ failed。
    public let final: String
}

/// 跳转方案步骤类型与结果（契约 jump_type、events.json link_jump.result）。
public enum JumpTypes {
    public static let sdk = "sdk"
    public static let scheme = "scheme"
    public static let universalLink = "universal_link"
    public static let h5 = "h5"
    public static let copyTpwd = "copy_tpwd"
    public static let known: Set<String> = [sdk, scheme, universalLink, h5, copyTpwd]

    public static let launched = "launched"
    public static let failed = "failed"
    public static let sdkInitFailed = "sdk_init_failed"
    public static let copied = "copied"

    public static let finalOpened = "opened"
    public static let finalBrowser = "browser"
    public static let finalCopied = "copied"
    public static let finalNotInstalled = "not_installed"
    public static let finalFailed = "failed"
}

/// 按 primary、fallbacks 顺序执行（03 §4.5、BR-ATTR-27；客户端不自行拼 scheme、不追加兜底）：
/// - 某步 launched → 停：h5 为 browser（系统浏览器），其余 opened；
/// - copy_tpwd copied → 停：明确未安装（installed=false）时 not_installed（复制口令后仍提示安装，BR-ATTR-27 未安装列），否则 copied；
/// - failed / sdk_init_failed → 下一步；全部失败 → failed。
/// 不读时钟、不按 expire_at 判过期（G14；过期由执行器 TradeJumpExecutor 判）。`run` 是执行器与向量共用的同一个循环。
public enum JumpPlanRunner {
    /// 方案里的步骤（primary + fallbacks），保留 value 给执行器。
    public static func steps(_ plan: TradeObject) -> [TradeObject] {
        (TJSON.object(plan["primary"]).map { [$0] } ?? []) + TJSON.objects(plan["fallbacks"])
    }

    /// 逐步执行：`execute` 返回该步结果（launched / failed / sdk_init_failed / copied）。
    @MainActor
    public static func run(
        _ steps: [TradeObject], installedApp: Bool?, execute: @MainActor (Int, TradeObject) async -> String
    ) async -> JumpRun {
        var executed: [String] = []
        for (index, step) in steps.enumerated() {
            let type = TJSON.string(step["type"]) ?? ""
            executed.append(type)
            switch await execute(index, step) {
            case JumpTypes.launched:
                return JumpRun(
                    executed: executed,
                    final: type == JumpTypes.h5 ? JumpTypes.finalBrowser : JumpTypes.finalOpened
                )
            case JumpTypes.copied:
                return JumpRun(
                    executed: executed,
                    final: installedApp == false ? JumpTypes.finalNotInstalled : JumpTypes.finalCopied
                )
            default:
                continue
            }
        }
        return JumpRun(executed: executed, final: JumpTypes.finalFailed)
    }

    /// 同步版本（向量与纯逻辑用）：与 `run` 同一判定。
    public static func runSync(
        _ steps: [TradeObject], installedApp: Bool?, execute: (Int, TradeObject) -> String
    ) -> JumpRun {
        var executed: [String] = []
        for (index, step) in steps.enumerated() {
            let type = TJSON.string(step["type"]) ?? ""
            executed.append(type)
            switch execute(index, step) {
            case JumpTypes.launched:
                return JumpRun(
                    executed: executed,
                    final: type == JumpTypes.h5 ? JumpTypes.finalBrowser : JumpTypes.finalOpened
                )
            case JumpTypes.copied:
                return JumpRun(
                    executed: executed,
                    final: installedApp == false ? JumpTypes.finalNotInstalled : JumpTypes.finalCopied
                )
            default:
                continue
            }
        }
        return JumpRun(executed: executed, final: JumpTypes.finalFailed)
    }

    /// 向量用：步骤结果按位置注入，未执行的结果不消费；installed.app 是注入的检测结果。
    public static func simulate(plan: TradeObject, installed: TradeObject, stepResults: [String]) -> JumpRun {
        let app = TJSON.bool(installed["app"])
        return runSync(steps(plan), installedApp: app) { index, _ in
            index < stepResults.count ? stepResults[index] : JumpTypes.failed
        }
    }
}

/// link_jump 的事件业务字段（specs/events.json；03 §4.5、§4.7）：每一步一条，不排序、不去重；phase=purchase 带本次 open 响应的
/// attempt_id 与（替换后的）link_id、duration_ms、installed；startup 只有 phase / union_platform / step / result。步骤的 value
/// （完整推广 URL、口令）一律不上报（02 §12.6）。auth_jump 不上报（AuthJumpPlan：不是购买外跳）。缺编号的 purchase 步骤不上报。
public enum LinkJumpEvents {
    public static let phasePurchase = "purchase"
    public static let phaseStartup = "startup"
    private static let purchaseFields = ["union_platform", "step", "result", "duration_ms", "installed"]
    private static let startupFields = ["union_platform", "step", "result"]

    public static func build(
        attemptId: String?, linkId: String?, steps: [TradeObject], isAuthJump: Bool
    ) -> [TradeObject] {
        guard !isAuthJump else { return [] }
        return steps.compactMap { step in
            switch TJSON.string(step["phase"]) {
            case phasePurchase:
                guard let attemptId, let linkId else { return nil }
                var fields: TradeObject = ["phase": phasePurchase, "attempt_id": attemptId, "link_id": linkId]
                for key in purchaseFields {
                    if let value = step[key] {
                        fields[key] = value
                    }
                }
                return fields
            case phaseStartup:
                var fields: TradeObject = ["phase": phaseStartup]
                for key in startupFields {
                    if let value = step[key] {
                        fields[key] = value
                    }
                }
                return fields
            default:
                return nil
            }
        }
    }
}

/// 淘宝授权方式（BR-ID-17 细则「授权方式」）：按服务端下发的 auth_methods 顺序取本端能执行的第一种，不自行增减；`supported`
/// 是本端此刻的能力（web_code：系统浏览器 + 已登记的回跳；sdk_token：百川可用）。其余平台不走授权方式（拼多多走 auth_jump）。
public enum AuthMethodPicker {
    public static let webCode = "web_code"
    public static let sdkToken = "sdk_token"

    public static func pick(platform: String, authMethods: [String], supported: [String]) -> String? {
        guard platform == Platform.taobao.rawValue else { return nil }
        return authMethods.first { supported.contains($0) }
    }
}

/// 契约取值（三端同名）。
public enum TradeConstants {
    public static let authUnavailable = "auth_unavailable"
    public static let active = "active"
    public static let amountUnknown = "amount_unknown"
    public static let maintenance = "maintenance"
    public static let notLaunched = "not_launched"
    public static let installedTrue = "true"
    public static let installedFalse = "false"
    public static let installedUnknown = "unknown"
    public static let noRebateAuthDeclined = "auth_declined"
    public static let noRebateAuthFailed = "auth_failed"
}
