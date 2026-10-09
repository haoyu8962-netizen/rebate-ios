import ClientCore
import Foundation
import Generated
import XCTest

/// APP-06a 共性 2、8、10：拉取编号、304 确认、「此刻之后」的刷新（search_disabled 后恢复平台用）。
final class ConfigStoreConfirmTests: XCTestCase {
    /// 手动结算的拉取器：记下每次拉取的 If-None-Match 与回调。
    private final class ManualFetcher {
        var calls: [(etag: String?, done: (ConfigReply) -> Void)] = []
    }

    private func makeStore(_ fetcher: ManualFetcher, file: MemoryFile = MemoryFile()) -> ConfigStore {
        ConfigStore(
            readFile: file.read, writeFile: file.write,
            fetcher: { etag, done in fetcher.calls.append((etag, done)) },
            clock: { 1 }, bundled: DefaultConfig.json
        )
    }

    private let jdOn = "{\"features\":{\"search_status\":{\"taobao\":\"on\",\"jd\":\"on\"}}}"

    func testOkAdvancesAppliedIdAndExposesLayers() {
        let fetcher = ManualFetcher()
        let store = makeStore(fetcher)
        store.onColdStart()
        XCTAssertEqual(store.issuedFetchId, 1)
        XCTAssertEqual(store.appliedFetchId, 0)
        fetcher.calls[0].done(ConfigReply(kindRaw: ConfigReply.ok, bodyJson: jdOn, etag: "e1"))
        XCTAssertEqual(store.appliedFetchId, 1)
        XCTAssertEqual(store.confirmedSearchStatus?["jd"] as? String, "on")
        let layers = store.searchStatusLayers()
        XCTAssertEqual((layers["current"] as? [String: Any])?["jd"] as? String, "on")
        XCTAssertNotNil(layers["bundled"])
    }

    func testValid304ConfirmsAndNotifies() {
        let fetcher = ManualFetcher()
        let store = makeStore(fetcher)
        store.onColdStart()
        fetcher.calls[0].done(ConfigReply(kindRaw: ConfigReply.ok, bodyJson: jdOn, etag: "e1"))
        var notified = 0
        let token = store.observe { _ in notified += 1 }
        store.requestFresh()
        XCTAssertEqual(fetcher.calls[1].etag, "e1")
        fetcher.calls[1].done(ConfigReply(kindRaw: ConfigReply.notModified, bodyJson: nil, etag: "e1"))
        XCTAssertEqual(store.appliedFetchId, 2, "304 也推进确认编号")
        XCTAssertEqual(notified, 1, "并通知订阅者")
        XCTAssertEqual(store.sourceRaw, ConfigStore.sourceCurrent)
        token.cancel()
    }

    func test304WithoutEtagOrConfigDoesNothing() {
        let fetcher = ManualFetcher()
        let store = makeStore(fetcher)
        store.onColdStart()
        fetcher.calls[0].done(ConfigReply(kindRaw: ConfigReply.notModified, bodyJson: nil, etag: nil))
        XCTAssertEqual(store.appliedFetchId, 0)
    }

    func testRequestFreshWhileInFlightFetchesAgainAfterSettle() {
        let fetcher = ManualFetcher()
        let store = makeStore(fetcher)
        store.onColdStart()
        fetcher.calls[0].done(ConfigReply(kindRaw: ConfigReply.ok, bodyJson: jdOn, etag: "e1"))
        store.onForeground()
        XCTAssertEqual(fetcher.calls.count, 2)
        let mark = store.issuedFetchId
        store.requestFresh()
        XCTAssertEqual(fetcher.calls.count, 2, "在途时不并发")
        // 分界之前的在途拉取结算（304）：编号不大于分界，调用方不能据此恢复。
        fetcher.calls[1].done(ConfigReply(kindRaw: ConfigReply.notModified, bodyJson: nil, etag: "e1"))
        XCTAssertLessThanOrEqual(store.appliedFetchId, mark)
        XCTAssertEqual(fetcher.calls.count, 3, "结算后补发一次")
        fetcher.calls[2].done(ConfigReply(kindRaw: ConfigReply.notModified, bodyJson: nil, etag: "e1"))
        XCTAssertGreaterThan(store.appliedFetchId, mark, "补发的拉取经 304 确认后可恢复")
    }

    func testEnvironmentSwitchDropsLateConfirm() throws {
        let fetcher = ManualFetcher()
        let store = makeStore(fetcher)
        store.onColdStart()
        fetcher.calls[0].done(ConfigReply(kindRaw: ConfigReply.ok, bodyJson: jdOn, etag: "e1"))
        store.requestFresh()
        try store.clearForEnvironmentSwitch()
        fetcher.calls[1].done(ConfigReply(kindRaw: ConfigReply.notModified, bodyJson: nil, etag: "e1"))
        XCTAssertEqual(store.appliedFetchId, 0)
        XCTAssertNil(store.confirmedSearchStatus)
    }
}
