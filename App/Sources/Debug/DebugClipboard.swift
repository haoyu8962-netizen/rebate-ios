#if DEBUG
import Clipboard
import Foundation

/// 剪贴板识别的调试能力（APP-07；只在 Debug / Staging 编译，Release 制品扫描查 `marker`）：
/// - `-CouliClipboardDiagnostics`：根视图角落放一个读屏可读的计数（探测、parse 请求、App 写系统剪贴板的次数），UI 测试据此断言
///   「点击前 0 次请求、点击后 1 次」「写入次数为 0」；不含任何剪贴板内容。
enum DebugClipboard {
    static let marker = "COULI_DEBUG_CLIPBOARD_APP07_IOS_4e1b9a"

    static var diagnostics: Bool {
        ProcessInfo.processInfo.arguments.contains("-CouliClipboardDiagnostics")
    }
}

/// 最近一次自动识别判定（FU-IOS-CLIP-DIAG-REASON，D10-1640 (2)）：事件名 + 落点，拼进 `debugDiagnostics` 的 ` last=<event>:<outcome>`。
/// 只记判定走到哪条路，不含剪贴板内容，也不含 changeCount 的值。Release 制品扫描查类型名 `DebugClipboardEvaluation`。
/// outcome 取值：
/// - `evaluate`：`home_visual`（首页视觉场景提前返回）；读取策略跳过时用 reasonRaw（basic_mode / privacy_outdated /
///   sensitive / not_foreground / already_read / config_off / web_suppressed / switch_off；为空时记 actionRaw）；
///   `unchanged`（changeCount 没变，已写 ios_change_seen）；`not_home_root`（策略让探测但不在首页根页）；
///   `self_written`（App 自写记录命中）；`detecting`（已发起 detectPatterns）。
/// - `detected`（只覆盖同一轮的记录，旧轮迟到的回调不盖掉新一轮）：复核不过丢弃记 `stale_round` / `stale_background` /
///   `stale_home_gen` / `stale_not_home_root` / `stale_overlay` / `stale_change`；策略按 no_detect_hit 跳过记 `no_hit`；
///   探测期间策略改判跳过记 `late_<reasonRaw>`（如 late_switch_off）；出了提示条记 `hit`。
struct DebugClipboardEvaluation: Equatable {
    static let none = "none"
    static let homeVisual = "home_visual"
    static let notHomeRoot = "not_home_root"
    static let selfWritten = "self_written"
    static let detecting = "detecting"
    static let staleRound = "stale_round"
    static let staleBackground = "stale_background"
    static let staleHomeGen = "stale_home_gen"
    static let staleNotHomeRoot = "stale_not_home_root"
    static let staleOverlay = "stale_overlay"
    static let staleChange = "stale_change"
    static let noHit = "no_hit"
    static let latePrefix = "late_"
    static let hit = "hit"

    let event: String
    let round: Int64
    let outcome: String

    /// 读取策略在探测前就跳过：用策略的原因。
    static func policySkip(_ decision: ClipboardReadDecision) -> String {
        decision.reasonRaw ?? decision.actionRaw
    }

    /// 探测回来后策略不让出提示条：没命中记 no_hit，其余（开关被关、进了敏感页等）记 late_<原因>。
    static func lateOutcome(_ decision: ClipboardReadDecision) -> String {
        if decision.reasonRaw == ClipboardReadPolicy.reasonNoDetectHit {
            return noHit
        }
        return latePrefix + policySkip(decision)
    }
}

extension AppClipboard {
    /// 计数（不含内容）：detect=<探测次数> parse=<parse 请求次数> writes=<App 写系统剪贴板次数> last=<事件名>:<落点>（没判定过为 last=none）。
    var debugDiagnostics: String {
        _ = DebugClipboard.marker
        let writes = (systemClipboard as? UIKitSystemClipboard)?.writeCount ?? 0
        let last = debugLastEvaluation.map { "\($0.event):\($0.outcome)" } ?? DebugClipboardEvaluation.none
        return "detect=\(detectCount) parse=\(parseCount) writes=\(writes) last=\(last)"
    }

    /// `evaluate` 的返回点记一笔（新的一次判定，覆盖上一次）。
    func debugRecord(event: String, round: Int64, _ outcome: String) {
        debugLastEvaluation = DebugClipboardEvaluation(event: event, round: round, outcome: outcome)
    }

    /// `detected` 的返回点：只更新同一轮发起的那条记录，旧轮迟到的回调不覆盖新一轮的判定。
    func debugRecordDetected(round: Int64, _ outcome: String) {
        guard let last = debugLastEvaluation, last.round == round else { return }
        debugRecord(event: last.event, round: round, outcome)
    }

    /// `evaluate` 第二道 guard 没过：按 guard 里的先后顺序找出是哪一条（与产品判定同序、同一次主线程同步执行，不改判定）。
    func debugNotDetectedOutcome(_ decision: ClipboardReadDecision, unchanged: Bool) -> String {
        if unchanged {
            return DebugClipboardEvaluation.policySkip(decision)
        }
        return homeRoot() ? DebugClipboardEvaluation.selfWritten : DebugClipboardEvaluation.notHomeRoot
    }

    /// `detected` 复核没过：按 guard 里的先后顺序找出是哪一条；前面都过了就是剪贴板又变了（不记 changeCount 的值）。
    func debugStaleOutcome(round: Int64, homeGen gen: Int64) -> String {
        if round != watcher.round {
            return DebugClipboardEvaluation.staleRound
        }
        if !watcher.inForeground {
            return DebugClipboardEvaluation.staleBackground
        }
        if gen != homeGen {
            return DebugClipboardEvaluation.staleHomeGen
        }
        if !homeRoot() {
            return DebugClipboardEvaluation.staleNotHomeRoot
        }
        return overlayClear() ? DebugClipboardEvaluation.staleChange : DebugClipboardEvaluation.staleOverlay
    }
}
#endif
