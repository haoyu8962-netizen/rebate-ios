/*
 FU-X-CLIP-DEFAULT-ON-ios 测试（先红；测试作者写，实现者接）。依据：规划 docs/changes/20261030-剪贴板默认开启.md、08 BR-ID-16
 （2026-10-30 版「默认开启」「开关的适用范围」「撤回与关闭」）；任务书 NATIVE/FU-X-CLIP-DEFAULT-ON/brief.md §1 C1、C5、C6、C7，§2.2。

 接线约定（Clipboard 模块新增，交回 §5）：
 - `ClipboardAutoSwitch(store: ClipboardHashStore)`：本机开关「打开 App 自动识别剪贴板」（设备级，不随账号）。
   `isOn: Bool`（从未选择 = true）；`@discardableResult set(_ on: Bool) -> Bool`（返回是否确认落盘；不论落盘与否内存里立即生效）。
   iOS 旧版本机从未有过剪贴板开关键（交回 §3）：迁移 = 没有存过值一律开启；只做一次、幂等，之后只认用户在设置里的选择。
 - `ClipboardReadState.enabled: Bool`（缺省 true），向量 readPolicy.state 同名字段 `enabled`；iOS 开关关闭时读取策略 skip，
   reasonRaw `switch_off`（与 Android 同一个原因码），不做 detectPatterns、探测结果迟到也不出提示条。
 */

@testable import Clipboard
import Foundation
import XCTest

@MainActor
final class ClipDefaultOnSwitchTests: XCTestCase {
    // MARK: - C1 默认开启

    func testNeverChosenIsOnC1() {
        XCTAssertTrue(ClipboardAutoSwitch(store: MemoryClipboardHashStore()).isOn, "从未作出选择：同意隐私政策后即为开启")
    }

    // MARK: - C5 关闭态保持

    func testOffAndOnPersistAcrossRestartC5() {
        let store = MemoryClipboardHashStore()
        let first = ClipboardAutoSwitch(store: store)
        XCTAssertTrue(first.set(false), "关闭确认落盘")
        XCTAssertFalse(first.isOn)
        XCTAssertFalse(ClipboardAutoSwitch(store: store).isOn, "重启（新实例读同一存储）后仍关闭")
        XCTAssertTrue(ClipboardAutoSwitch(store: store).set(true))
        XCTAssertTrue(ClipboardAutoSwitch(store: store).isOn, "用户重新打开后保持开启")
    }

    func testOffTakesEffectInMemoryEvenWhenWriteFailsC5() {
        let store = MemoryClipboardHashStore()
        let autoSwitch = ClipboardAutoSwitch(store: store)
        store.failWrites = true
        XCTAssertFalse(autoSwitch.set(false), "存储故障：报告没有落盘")
        XCTAssertFalse(autoSwitch.isOn, "关闭立即生效，不因写盘失败继续读取")
    }

    // MARK: - C6 迁移（iOS：没有旧开关键 → 开启）

    func testMigrationNoLegacySwitchKeyIsOnIdempotentAndUserChoiceWinsC6() throws {
        let store = MemoryClipboardHashStore()
        // iOS 旧版本机真实存过的只有识别记录（APP-07：ios_change_seen、自写与提示 hash），以及 APP-04 时期 H5 桥写进 UserDefaults 的
        // couli.clipboard.autoDetect（不是用户开关，H5 也不能改开关；这里放进同一存储也不得被当作开关值）
        try store.write("ios_change_seen", "12")
        try store.write("couli.clipboard.autoDetect", "false")
        for round in 1...3 {
            XCTAssertTrue(ClipboardAutoSwitch(store: store).isOn, "第 \(round) 次启动：从未选择 → 开启")
        }
        XCTAssertTrue(ClipboardAutoSwitch(store: store).set(false))
        for round in 1...3 {
            XCTAssertFalse(ClipboardAutoSwitch(store: store).isOn, "第 \(round) 次启动：迁移只做一次，不把用户的关闭改回开启")
        }
        try store.write("couli.clipboard.autoDetect", "true")
        XCTAssertFalse(ClipboardAutoSwitch(store: store).isOn, "旧键不再作判定依据")
        XCTAssertTrue(ClipboardAutoSwitch(store: store).set(true))
        try store.write("couli.clipboard.autoDetect", "false")
        XCTAssertTrue(ClipboardAutoSwitch(store: store).isOn)
    }

    // MARK: - 读取策略（C1 / C5 / C7）

    private func state(consent: String = ClipboardReadPolicy.consentAgreed,
                       event: String = ClipboardReadPolicy.eventForeground) -> ClipboardReadState {
        ClipboardReadState(consent: consent, event: event, route: "Home")
    }

    private func decide(_ state: ClipboardReadState) -> ClipboardReadDecision {
        ClipboardReadPolicy.decide(platform: ClipboardReadPolicy.platformIOS, state: state)
    }

    func testReadPolicySwitchOnDetectsOffSkipsWithoutDetectC1C5() {
        var current = state()
        XCTAssertTrue(current.enabled, "ClipboardReadState 的缺省（中性前提）为开启")
        XCTAssertEqual(decide(current).actionRaw, ClipboardReadPolicy.actionDetect, "开关开：按原门槛探测")
        current.enabled = false
        XCTAssertEqual(
            decide(current),
            ClipboardReadDecision(
                actionRaw: ClipboardReadPolicy.actionSkip,
                reasonRaw: ClipboardReadPolicy.reasonSwitchOff
            ),
            "开关关：不探测（detectPatterns 也不做）"
        )
        current.iosDetectHit = true
        XCTAssertEqual(decide(current).actionRaw, ClipboardReadPolicy.actionSkip, "关闭后迟到的探测结果不出提示条")
        var cold = state(event: ClipboardReadPolicy.eventColdStart)
        cold.enabled = false
        XCTAssertEqual(decide(cold).reasonRaw, ClipboardReadPolicy.reasonSwitchOff, "冷启动同样不读")
    }

    func testReadPolicyPrivacyStillFirstC7() {
        var basic = state(consent: ClipboardReadPolicy.consentBasic)
        basic.enabled = true
        XCTAssertEqual(decide(basic).reasonRaw, ClipboardReadPolicy.reasonBasicMode, "基本模式不读，开关开也不读")
        basic.enabled = false
        XCTAssertEqual(decide(basic).reasonRaw, ClipboardReadPolicy.reasonBasicMode)
    }

    func testReadPolicyJsonFormReadsEnabledC5() {
        let base: [String: Any] = ["consent": "agreed", "event": "foreground_after_background", "route": "Home"]
        XCTAssertEqual(
            ClipboardReadPolicy.decide(platform: "ios", state: base).actionRaw,
            "detect_patterns",
            "缺 enabled 按开启"
        )
        var off = base
        off["enabled"] = false
        XCTAssertEqual(ClipboardReadPolicy.decide(platform: "ios", state: off).reasonRaw, "switch_off")
        var notBool = base
        notBool["enabled"] = 0
        XCTAssertEqual(
            ClipboardReadPolicy.decide(platform: "ios", state: notBool).actionRaw, "detect_patterns", "类型不对按缺失（同其他字段）"
        )
    }

    /// 向量改写不空转：clipboard-vectors.json readPolicy 里 iOS 带 enabled=false 的行存在且都期望 skip。
    func testVectorRowsWithSwitchOffExist() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return XCTFail("找不到 contract.lock") }
            directory = parent
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("specs/clipboard-vectors.json"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(root["readPolicy"] as? [[String: Any]])
        let off = rows.filter {
            ($0["platform"] as? String) == "ios" && (($0["state"] as? [String: Any])?["enabled"] as? Bool) == false
        }
        XCTAssertGreaterThanOrEqual(off.count, 6)
        for row in off {
            XCTAssertEqual(
                (row["expect"] as? [String: Any])?["actionRaw"] as? String,
                "skip",
                row["name"] as? String ?? ""
            )
        }
    }
}
