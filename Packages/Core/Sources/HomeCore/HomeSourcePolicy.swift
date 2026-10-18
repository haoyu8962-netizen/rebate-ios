import CouliNetwork
import Foundation

/// 无副作用的三级来源状态机；控制器按动作读文件和提交渲染。
public struct HomeSourcePolicy {
    private var showing = "none"
    private var interacted = false
    private var pulling = false
    private var invalid = false
    private var disabled: Int64 = 0
    public init() {}
    public mutating func on(event: String, arg: [String: Any]) -> [String: Any] {
        let actions = transition(event, arg)
        return ["actionsRaw": actions.isEmpty ? ["none"] : actions, "showing": showing, "refreshDisabledMs": disabled]
    }

    private mutating func transition(_ event: String, _ arg: [String: Any]) -> [String] {
        if event == "cold_start" {
            self = HomeSourcePolicy()
            if arg["hasLkg"] as? Bool == true {
                showing = "lkg"
                return ["show_lkg"]
            }
            return []
        }
        if event == "identity_changed" {
            invalid = true
            showing = "none"
            return []
        }
        if invalid {
            return ["drop_stale"]
        }
        return active(event, arg)
    }

    private mutating func active(_ event: String, _ arg: [String: Any]) -> [String] {
        switch event {
        case "lkg_loaded": showing = arg["valid"] as? Bool == false ? "none" : showing
        case "user_interacted": interacted = true
        case "pull_refresh": pulling = true
        case "timer_1500": if showing == "none" {
                showing = "default"
                return ["show_default"]
            }
        case "default_loaded":
            if arg["valid"] as? Bool == false {
                showing = "load_failed"
                return ["show_load_failed"]
            }
        case "network_ok": return network(arg)
        case "network_fail": return failure(arg)
        default: break
        }
        return []
    }

    private mutating func network(_ arg: [String: Any]) -> [String] {
        guard arg["valid"] as? Bool != false else { return failure(arg) }
        if pulling || showing == "none" || showing == "load_failed" || (showing == "default" && !interacted) {
            showing = "network"
            pulling = false
            return ["show_network", "write_lkg"]
        }
        return ["write_lkg"]
    }

    private mutating func failure(_ arg: [String: Any]) -> [String] {
        let wasPulling = pulling
        pulling = false
        switch arg["kind"] as? String {
        case "code_10405": return ["force_update"]
        case "http_42901":
            let seconds = (arg["retryAfter"] as? String).flatMap(Int64.init) ?? 5
            disabled = seconds > 0 && seconds < Int64.max / 1000 ? seconds * 1000 : 5000
            return wasPulling ? ["toast_error:error.42901", "disable_refresh"] : ["disable_refresh"]
        default: return wasPulling ? ["toast_error:error.50001"] : []
        }
    }
}
