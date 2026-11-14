import Foundation
import Generated

/// 诊断字段（规划/03 §4.7「诊断字段」；events.yaml v6 的 bridge_call、sdui_card_error、agent_stream_*）：schema_version、bridge_version、
/// config_version、h5_release 四项必填，所在层不存在或尚未取到时填固定值 `unknown`，不留空（与 Android EventDiagnostics 同口径）。
public enum EventDiagnostics {
    public static let unknown = "unknown"

    /// 生效配置（`ConfigStore.snapshotJson`：current → LKG → 包内，整份选择）里的 config_version（04 §10.1，= /v1/config 响应 ETag
    /// 去引号）。包内默认配置没有它，/v1/config 还没拉到时为 `unknown`；不是非空字符串也按 `unknown`。
    public static func configVersion(configJson: String) -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(configJson.utf8))) as? [String: Any],
              let version = root["config_version"] as? String, !version.isEmpty
        else { return unknown }
        return version
    }

    /// bridge_call 的 schema_version（03 §4.7，D10-1612 ④ (i)）：本端打包的桥契约（Generated `BridgeSchema.json`，快照
    /// contracts/bridge.schema.json 原样嵌入）顶层 version 转成的字符串；读不了或没有整数 version 时为 `unknown`（不借用默认值，
    /// 也不借用 bridge_version，两者数值可以相同）。
    public static let bridgeSchemaVersion: String = {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(BridgeSchema.json.utf8))) as? [String: Any],
              let number = root["version"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return unknown }
        return number.stringValue
    }()
}
