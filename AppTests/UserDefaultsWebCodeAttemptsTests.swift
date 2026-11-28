import AuthenticationServices
import Config
@testable import Couli
import Foundation
import Trade
import XCTest

/// FU-IOS-TB-WEBCODE-A：本机尝试记录 `UserDefaultsWebCodeAttempts`（独立 suite；同安卓甲 s01–s05 语义）。
/// 只写 sha256(state)（64 位小写十六进制）与发起时间（毫秒 Int64），只存 1 条；不写 state 原文、不写 code；
/// `current` 要两个键都在、哈希合格式才返回；`clear` 删两个键；`clearIfCurrent` 哈希相同才删；切环境随命名空间清理清掉。
/// 底座各方法都是空 / nil：正向用例按断言红，「不完整 / 不合格式 → nil」类反向用例在底座上就绿。
@MainActor
final class UserDefaultsWebCodeAttemptsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "UserDefaultsWebCodeAttemptsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private var stateKey: String {
        UserDefaultsWebCodeAttempts.stateSha256Key
    }

    private var startedKey: String {
        UserDefaultsWebCodeAttempts.startedAtKey
    }

    private func makeStore() -> UserDefaultsWebCodeAttempts {
        UserDefaultsWebCodeAttempts(defaults: defaults)
    }

    /// 本 suite 里本 App 命名空间下的全部键。
    private func namespacedKeys() -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(AppNamespace.userDefaultsPrefix) }.sorted()
    }

    /// suite 里（含键名与取值）有没有出现 `secret`。
    private func suiteMentions(_ secret: String) -> [String] {
        defaults.dictionaryRepresentation().compactMap { key, value in
            key.contains(secret) || "\(value)".contains(secret) ? key : nil
        }
    }

    // MARK: - 键名（底座已是真值）

    func testKeysLiveUnderTheAppNamespace() {
        XCTAssertEqual(stateKey, "com.couli.app.trade.webcode_attempt.state_sha256")
        XCTAssertEqual(startedKey, "com.couli.app.trade.webcode_attempt.started_at")
        XCTAssertTrue(stateKey.hasPrefix(AppNamespace.userDefaultsPrefix))
        XCTAssertTrue(startedKey.hasPrefix(AppNamespace.userDefaultsPrefix))
        XCTAssertFalse(AppNamespace.preservedOnEnvironmentSwitchKeys.contains(stateKey), "切环境不保留")
        XCTAssertFalse(AppNamespace.preservedOnEnvironmentSwitchKeys.contains(startedKey), "切环境不保留")
    }

    // MARK: - 正向（底座按断言红）

    func testRecordThenCurrent() {
        let store = makeStore()
        store.record(state: "S1", nowMillis: 1_700_000_000_123)
        XCTAssertEqual(
            store.current(),
            WebCodeAttempt(stateSha256: webCodeReferenceSha256("S1"), startedAtMillis: 1_700_000_000_123)
        )
        XCTAssertEqual(
            makeStore().current()?.stateSha256, webCodeReferenceSha256("S1"), "另起一个实例读同一 suite：已落盘"
        )
    }

    func testRecordWritesOnlyTheHashAndTheTimeNeverTheState() {
        let store = makeStore()
        store.record(state: "SECRETstate42", nowMillis: 42)
        XCTAssertEqual(defaults.string(forKey: stateKey), webCodeReferenceSha256("SECRETstate42"), "存的是哈希")
        XCTAssertEqual((defaults.object(forKey: startedKey) as? NSNumber)?.int64Value, 42, "存的是毫秒数")
        XCTAssertEqual(namespacedKeys(), [startedKey, stateKey].sorted(), "只有这两个键")
        XCTAssertEqual(suiteMentions("SECRETstate42"), [], "state 原文不落盘")
    }

    func testNewerRecordReplacesTheOlderOne() {
        let store = makeStore()
        store.record(state: "S1", nowMillis: 1)
        store.record(state: "S2", nowMillis: 2)
        XCTAssertEqual(store.current(), WebCodeAttempt(stateSha256: webCodeReferenceSha256("S2"), startedAtMillis: 2))
        XCTAssertEqual(namespacedKeys(), [startedKey, stateKey].sorted(), "只存 1 条")
    }

    func testClearRemovesBothKeys() {
        let store = makeStore()
        store.record(state: "S1", nowMillis: 1)
        XCTAssertNotNil(store.current(), "前提：已记下")
        store.clear()
        XCTAssertNil(store.current())
        XCTAssertEqual(namespacedKeys(), [], "两个键都删掉")
    }

    func testClearIfCurrentOnlyClearsTheMatchingHash() {
        let store = makeStore()
        store.record(state: "S2", nowMillis: 2)
        store.clearIfCurrent(stateSha256: webCodeReferenceSha256("S1"))
        XCTAssertEqual(store.current()?.stateSha256, webCodeReferenceSha256("S2"), "哈希不同：不删后一次的记录")
        store.clearIfCurrent(stateSha256: webCodeReferenceSha256("S2"))
        XCTAssertNil(store.current(), "哈希相同：删")
        XCTAssertEqual(namespacedKeys(), [])
    }

    func testCurrentReadsAWellFormedRecord() {
        let hash = webCodeReferenceSha256("S1")
        defaults.set(hash, forKey: stateKey)
        defaults.set(Int64(7), forKey: startedKey)
        XCTAssertEqual(makeStore().current(), WebCodeAttempt(stateSha256: hash, startedAtMillis: 7))
    }

    func testEnvironmentSwitchCleanerRemovesTheRecord() throws {
        let store = makeStore()
        store.record(state: "S1", nowMillis: 1)
        XCTAssertNotNil(store.current(), "前提：已记下")
        try UserDefaultsNamespaceCleaner(defaults: defaults).cleanForEnvironmentSwitch()
        XCTAssertNil(store.current(), "切环境随命名空间清理清掉")
    }

    /// 授权器全程（启动 → 回跳拿到凭证）：UserDefaults 里从不出现 code、state 原文；拿到凭证后记录按哈希删掉。
    func testAuthorizerNeverPersistsCodeOrStatePlaintext() async throws {
        let rig = WebCodeAuthorizerRig(attempts: makeStore())
        let (probe, start) = try await rig.beginAndStart(state: "SECRETstate77")
        XCTAssertEqual(start.attemptAtStart?.stateSha256, webCodeReferenceSha256("SECRETstate77"), "启动前已落哈希")
        XCTAssertEqual(suiteMentions("SECRETstate77"), [], "会话期间：state 原文不落盘")
        start.completion(URL(string: "couli://auth/taobao?code=SECRETcode77&state=SECRETstate77"), nil)
        await rig.waitUntil { probe.done }
        XCTAssertEqual(probe.outcome, "credential:SECRETcode77")
        XCTAssertEqual(suiteMentions("SECRETcode77"), [], "code 不落盘")
        XCTAssertEqual(suiteMentions("SECRETstate77"), [], "state 原文不落盘")
        XCTAssertEqual(namespacedKeys(), [], "拿到凭证后按哈希删掉记录")
    }

    /// canceledLogin 时记录保留在 UserDefaults 里（只有哈希与时间）。
    func testCancelledAuthorizationKeepsTheHashedRecord() async throws {
        let rig = WebCodeAuthorizerRig(attempts: makeStore())
        let (probe, start) = try await rig.beginAndStart(state: "S1")
        start.completion(nil, ASWebAuthenticationSessionError(.canceledLogin))
        await rig.waitUntil { probe.done }
        XCTAssertEqual(probe.outcome, "cancelled")
        XCTAssertEqual(
            makeStore().current(),
            WebCodeAttempt(stateSha256: webCodeReferenceSha256("S1"), startedAtMillis: WebCodeAuthorizerRig.startedAt)
        )
    }

    // MARK: - 反向（底座上就绿）

    func testIncompleteOrMalformedRecordReadsAsNil() {
        let hash = webCodeReferenceSha256("S1")
        struct Row {
            let why: String
            let hash: Any?
            let time: Any?
        }
        let rows = [
            Row(why: "什么都没有", hash: nil, time: nil),
            Row(why: "只有哈希", hash: hash, time: nil),
            Row(why: "只有时间", hash: nil, time: Int64(7)),
            Row(why: "哈希大写", hash: hash.uppercased(), time: Int64(7)),
            Row(why: "哈希 63 位", hash: String(hash.dropLast()), time: Int64(7)),
            Row(why: "哈希 65 位", hash: hash + "0", time: Int64(7)),
            Row(why: "哈希含非十六进制", hash: "g" + String(hash.dropFirst()), time: Int64(7)),
            Row(why: "哈希是 state 原文", hash: "S1", time: Int64(7)),
            Row(why: "哈希不是字符串", hash: 12345, time: Int64(7)),
        ]
        for row in rows {
            let (why, storedHash, storedTime) = (row.why, row.hash, row.time)
            defaults.removeObject(forKey: stateKey)
            defaults.removeObject(forKey: startedKey)
            if let storedHash {
                defaults.set(storedHash, forKey: stateKey)
            }
            if let storedTime {
                defaults.set(storedTime, forKey: startedKey)
            }
            XCTAssertNil(makeStore().current(), "\(why) → nil")
        }
    }

    func testClearOnEmptyStoreIsHarmless() {
        let store = makeStore()
        store.clear()
        store.clearIfCurrent(stateSha256: webCodeReferenceSha256("S1"))
        XCTAssertNil(store.current())
        XCTAssertEqual(namespacedKeys(), [])
    }
}
