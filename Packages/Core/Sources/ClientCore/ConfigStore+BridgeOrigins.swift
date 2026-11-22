import Foundation

// N-22（D10-2539）：ConfigStore 的「上次可用白名单」与 LKG 文件格式（从 ConfigStore.swift 拆出，file_length）。
// 验签本身在 BridgeHost 的 BridgeOriginsVerifier，由 App 经 `verifyBridgeOrigins` 闭包注入（ClientCore 不依赖 BridgeHost）。

public extension ConfigStore {
    /// 可信 H5 源（N-22）：上次可用（验签通过）的 bridge_origins 白名单的 origins；没有为 `[]`。
    /// - 200 新配置：用当前上次可用的 version 验新文档，通过才替换；不通过保留原值（失败值不写成上次可用，AC-S1-180 ②）。
    /// - 冷启动：LKG 带完整 `bridge_origins_last_good` 直接用；没有或形状不完整时用 LKG 文档现验，通过才用。
    /// - 304、拉取失败：不变（不重新验签）；切换环境：清空。包内默认配置不验（占位 jws 必然验不过）→ 空。
    /// 变化随生效文档的变化经 `observe` 通知。
    var trustedOrigins: [String] {
        lastGoodOrigins?.origins ?? []
    }

    /// 上次可用白名单的 version（下一份文档的回退基准）；没有为 nil。
    var trustedOriginsVersion: Int? {
        lastGoodOrigins?.version
    }
}

/// 上次可用白名单（LKG 文件字段 `bridge_origins_last_good: {"version": n, "origins": [...]}`）。
struct BridgeOriginsLastGood {
    let version: Int
    let origins: [String]

    var object: [String: Any] {
        ["version": version, "origins": origins]
    }

    /// 形状完整（version 为 ≥ 0 的整数、origins 为非空字符串数组）才算；否则 nil（按没有处理，回落现验）。
    static func decode(_ value: Any?) -> BridgeOriginsLastGood? {
        guard let object = value as? [String: Any],
              let number = object["version"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), !CFNumberIsFloatType(number),
              let items = object["origins"] as? [Any], !items.isEmpty
        else {
            return nil
        }
        let version = number.intValue
        let origins = items.compactMap { $0 as? String }
        guard version >= 0, number.compare(NSNumber(value: version)) == .orderedSame,
              origins.count == items.count
        else {
            return nil
        }
        return BridgeOriginsLastGood(version: version, origins: origins)
    }
}

/// LKG 文件：最近一次成功的 data、它的 ETag、保存时刻、上一次成功的完整 link_patterns 与上次可用的 bridge_origins 白名单。
/// 不含任何凭据（CSB-05、CSB-06）。
struct LKGFile {
    static let version = 1

    let document: ConfigDocument
    let etag: String?
    let savedAt: Int64
    let lastGoodPatterns: [String: Any]?
    let lastGoodOrigins: BridgeOriginsLastGood?

    func encode() -> String? {
        var object: [String: Any] = ["v": Self.version, "data": document.object, "saved_at": savedAt]
        if let etag {
            object["etag"] = etag
        }
        if let lastGoodPatterns {
            object["link_patterns_last_good"] = lastGoodPatterns
        }
        if let lastGoodOrigins {
            object["bridge_origins_last_good"] = lastGoodOrigins.object
        }
        return ConfigDocument.encode(object)
    }

    static func decode(_ text: String?) -> LKGFile? {
        guard let root = ConfigDocument.parse(text),
              root.object["v"] as? Int == version,
              let data = root.object["data"] as? [String: Any]
        else {
            return nil
        }
        return LKGFile(
            document: ConfigDocument(object: data),
            etag: root.object["etag"] as? String,
            savedAt: (root.object["saved_at"] as? NSNumber)?.int64Value ?? 0,
            lastGoodPatterns: root.object["link_patterns_last_good"].flatMap(ConfigResolver.completePatterns),
            lastGoodOrigins: BridgeOriginsLastGood.decode(root.object["bridge_origins_last_good"])
        )
    }
}
