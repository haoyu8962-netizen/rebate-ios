@testable import Couli
import Foundation
import Me
import MeCore
import SwiftUI
import XCTest

/// APP-12w-b（隐私中心 / 关于 / 联系客服视觉）三端同一份数据：`specs/privacy-visual-vectors.json`（G-P13；取自 rebate-android e9fdd94，逐字节相同）。
/// 不往 `me-vectors.json` 追加。固定时钟同 APP-12w-a。iOS 与 Android 只有一处不同：iOS 契约有两条系统权限（`behaviorOnlyPermissionEntry` 不用）。
enum PrivacyVisualData {
    static func root() throws -> [String: Any] {
        let url = WalletVisualData.repo().appendingPathComponent("specs/privacy-visual-vectors.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func session(_ name: String) throws -> [String: Any] {
        let sessions = try XCTUnwrap(root()["sessions"] as? [String: Any])
        return try XCTUnwrap(sessions[name] as? [String: Any], "sessions 缺 \(name)")
    }

    static func about(_ key: String) throws -> Any {
        let group = try XCTUnwrap(root()["about"] as? [String: Any])
        return try XCTUnwrap(group[key], "about 缺 \(key)")
    }

    static func text(_ group: String, _ key: String) throws -> String {
        let values = try XCTUnwrap(root()[group] as? [String: Any])
        return try XCTUnwrap(values[key] as? String, "\(group) 缺 \(key)")
    }

    static func csCase(_ name: String) throws -> [String: Any] {
        let group = try XCTUnwrap(root()["cs"] as? [String: Any])
        let cases = try XCTUnwrap(group["cases"] as? [String: Any])
        return try XCTUnwrap(cases[name] as? [String: Any], "cs.cases 缺 \(name)")
    }

    static func notices() throws -> [(key: String, check: Bool)] {
        let rows = try XCTUnwrap(root()["notices"] as? [[String: Any]])
        return try rows.map { row in
            try (XCTUnwrap(row["text"] as? String), XCTUnwrap(row["check"] as? Bool))
        }
    }

    /// 配置落地的标记：`legalPrivacyVersion` 没配置时回落本机值，不能当「配置已到」的信号（v1 实跑：kf 还没到就开了半屏）。
    static let marker = "visual_marker"

    /// 配置报文：kf 给 nil = 缺失；其余同 `MeSamples.config`（legal.privacy.version = 3，同 fixture 的 legalPrivacyVersion）。
    static func config(kf: String?, filing: String) throws -> String {
        let data = Data(MeSamples.config.utf8)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["kf"] = kf.map { ["url": $0] }
        var agent = object["agent"] as? [String: Any] ?? [:]
        agent["filing_text"] = filing
        agent[marker] = true
        object["agent"] = agent
        return MeSamples.json(object)
    }

    /// 画板实量（2026-11-02 逐像素，`design-hifi/review-me/v1/png/`，交回 §1 有出处）。注意隐私中心列表行是 border-box：节距 44，**不是**设置页的 53。
    enum Board {
        static let width: CGFloat = 358
        static let side: CGFloat = 16
        static let documentRow: CGFloat = 44
        static let documentCard: CGFloat = 184
        static let cardGap: CGFloat = 12
        static let personalizationCard: CGFloat = 97.5
        static let sectionTop: CGFloat = 20
        /// DS 确认框左右 24（设置一族已按此）；PrivacyCenterWithdraw 画板左右 32、宽 326，compare 记组件库差异（交回「要编排定」）。
        static let dialogWidth: CGFloat = 342
        static let aboutIcon: CGFloat = 80
        static let badge: CGFloat = 56
        static let sheetTop: CGFloat = 28
        /// 客服半屏命中高。系统 `.sheet` 在 iOS 26 把内容缩到 374/390，屏上 ≥ 44 要进程内约 46（编排 v2 第 8 条，≥ 44 按屏上算）。
        static let sheetHit: CGFloat = 46
    }
}

/// 客服半屏的测试外壳：系统 `.sheet` 的内容换成直接挂在窗口上（同一个生产 `CsSheetView` + 生产 `CustomerServiceEntry`），这样字号环境进得去、能拍深色、
/// 测量桥不跨窗口。生产的 `.sheet(item:)` 按 `sheet.id` 换内容，这里用 `.id` 对应。真实 `.sheet` + detent 由 `PrivacyVisualUITests` 真点覆盖。
struct CsSheetHarness: View {
    @ObservedObject var entry: CustomerServiceEntry
    let texts: MeTexts

    var body: some View {
        Group {
            if let sheet = entry.sheet {
                CsSheetView(entry: entry, sheet: sheet, texts: texts).id(sheet.serial)
            } else {
                Color.clear
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// 只看数值的纯判据（`PrivacyVisualFixtureTests` 先正后反自证）。
enum PrivacyVisualJudge {
    /// 整段文字的水平中心是否落在面板中线上。
    static func centered(_ item: CGRect, in panel: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(item.midX - panel.midX) <= tolerance
    }

    /// 同一行：两框纵向中线差不超过 `tolerance`。
    static func sameRow(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(lhs.midY - rhs.midY) <= tolerance
    }
}
