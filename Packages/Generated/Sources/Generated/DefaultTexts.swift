// 生成物，禁止手改；来源 contract.lock
// 资源：Resources/texts.default.json（从快照 contracts/texts.default.json 原样复制）

import Foundation

/// 包内默认文案（BR-TEXT-12 的唯一来源）。首次访问时从包资源加载。
public enum DefaultTexts {
    private struct Table: Swift.Decodable, Swift.Sendable {
        let texts: [Swift.String: Swift.String]
        let fallbacks: [Swift.String: Swift.String]
    }

    private static let table: Table = {
        guard let url = Foundation.Bundle.module.url(forResource: "texts.default", withExtension: "json"),
              let data = try? Foundation.Data(contentsOf: url),
              let decoded = try? Foundation.JSONDecoder().decode(Table.self, from: data)
        else {
            Swift.assertionFailure("Generated: texts.default.json missing or invalid")
            return Table(texts: [:], fallbacks: [:])
        }
        return decoded
    }()

    private static let sortedKeys: [Swift.String] = table.texts.keys.sorted()

    /// texts 里的值。
    public static func text(_ key: Swift.String) -> Swift.String? {
        table.texts[key]
    }

    /// fallbacks 里的值。
    public static func fallback(_ key: Swift.String) -> Swift.String? {
        table.fallbacks[key]
    }

    /// texts 的全部键（按字典序）。
    public static var allKeys: [Swift.String] {
        sortedKeys
    }
}
