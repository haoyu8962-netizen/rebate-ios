@testable import Couli
import CouliNetwork
import Foundation
import MeCore
import UIKit
import XCTest

/// APP-12w-a（设置一族视觉）三端同一份数据：`specs/me-vectors.json` 的 `visualSettings`（G-S18；取自 Android 合入版，逐字节相同）。
/// 固定时钟 2026-10-12 10:30 +08:00。两处 iOS 口径与这份数据不同，用例按 iOS 现状写：
/// - 剪贴板开关默认开启、无用途说明（D10-423、BR-ID-16 2026-10-30），`clipboardSwitch` / `clipboardConsent` 不用；
/// - 系统权限原始值是 `permanently_denied` / `not_asked`（`notify.denied` / `notDetermined` 按此换算）。
enum SettingsVisualData {
    static func root() throws -> [String: Any] {
        let url = WalletVisualData.repo().appendingPathComponent("specs/me-vectors.json")
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(vectors["visualSettings"] as? [String: Any], "共用向量文件缺 visualSettings 组（G-S18）")
    }

    static func profile(_ name: String) throws -> [String: Any] {
        let all = try XCTUnwrap(root()["profiles"] as? [String: Any])
        return try XCTUnwrap(all[name] as? [String: Any], "visualSettings.profiles 缺 \(name)")
    }

    static func body(_ name: String) throws -> String {
        try WalletVisualData.json(profile(name))
    }

    static func routes(_ key: String) throws -> Set<String> {
        try Set(XCTUnwrap(root()[key] as? [String], "visualSettings 缺 \(key)"))
    }

    static func cacheBytes() throws -> Int64 {
        let sessions = try XCTUnwrap(root()["sessions"] as? [String: Any])
        let member = try XCTUnwrap(sessions["settings_member"] as? [String: Any])
        return try XCTUnwrap((member["cacheBytes"] as? NSNumber)?.int64Value)
    }

    /// `nickname` 组的一个字符串值（original / tooLong / stress / grapheme / saved）。
    static func nickname(_ key: String) throws -> String {
        let group = try XCTUnwrap(root()["nickname"] as? [String: Any])
        return try XCTUnwrap(group[key] as? String, "visualSettings.nickname 缺 \(key)")
    }

    /// `nickname.limit` / `nickname.sensitive` 的输入。
    static func nicknameInput(_ key: String) throws -> String {
        let group = try XCTUnwrap(root()["nickname"] as? [String: Any])
        return try XCTUnwrap((group[key] as? [String: Any])?["input"] as? String, "缺 \(key).input")
    }

    /// 待显示轻提示（键 → 是否带对勾，G-S06）。
    static func notices() throws -> [(key: String, check: Bool)] {
        let rows = try XCTUnwrap(root()["notices"] as? [[String: Any]])
        return try rows.map { row in
            try (XCTUnwrap(row["text"] as? String), XCTUnwrap(row["check"] as? Bool))
        }
    }

    static func nowMillis() throws -> Int64 {
        try MeVisualData.millis(XCTUnwrap(root()["clock"] as? String))
    }

    static let limit = ApiResult.failure(code: 30415, msg: "", data: nil, traceId: nil,
                                         effect: ErrorEffect(code: 30415, kind: .toast), idempotencyKey: nil)
    static let sensitive = ApiResult.failure(
        code: 20001, msg: "", data: Data(#"{"reason":"nickname_sensitive","fields":["nickname"]}"#.utf8),
        traceId: nil, effect: ErrorEffect(code: 20001, kind: .fieldError), idempotencyKey: nil
    )
}

/// 改昵称后端：挂住保存，等用例放行（「保存中」状态）。
final class HeldNicknameBackend: NicknameBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<ApiResult, Never>?

    var held: Bool {
        lock.withLock { waiting != nil }
    }

    func save(nickname _: String, owner _: RequestOwnership?, allowed _: @escaping @Sendable () -> Bool) async
        -> ApiResult {
        await withCheckedContinuation { continuation in
            lock.withLock { waiting = continuation }
        }
    }

    func release(_ result: ApiResult) {
        lock.withLock {
            waiting?.resume(returning: result)
            waiting = nil
        }
    }
}

/// 只看数值 / 像素的纯判据（`SettingsVisualOracleTests` 先正后反自证）。
enum SettingsVisualJudge {
    typealias RGB = ProductVisualPixels.RGB

    /// 画板色值 #RRGGBB。
    static func hex(_ text: String) -> RGB {
        let value = Int(text.dropFirst(), radix: 16) ?? 0
        return RGB(red: (value >> 16) & 0xFF, green: (value >> 8) & 0xFF, blue: value & 0xFF)
    }

    /// 遮罩盖在底色上的结果。
    static func blend(_ ink: RGB, opacity: Double, over ground: RGB) -> RGB {
        func mix(_ top: Int, _ bottom: Int) -> Int {
            Int((Double(top) * opacity + Double(bottom) * (1 - opacity)).rounded())
        }
        return RGB(red: mix(ink.red, ground.red), green: mix(ink.green, ground.green),
                   blue: mix(ink.blue, ground.blue))
    }

    /// 文字墨迹是否在面板里水平居中（左右留白差 ≤ `tolerance`）。
    static func centered(inkLeft: CGFloat, inkRight: CGFloat, in panel: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs((inkLeft - panel.minX) - (panel.maxX - inkRight)) <= tolerance
    }

    static func contrast(_ lhs: RGB, _ rhs: RGB) -> Double {
        func luminance(_ color: RGB) -> Double {
            func channel(_ value: Int) -> Double {
                let unit = Double(value) / 255
                return unit <= 0.04045 ? unit / 12.92 : pow((unit + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
        }
        let values = [luminance(lhs), luminance(rhs)].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }
}
