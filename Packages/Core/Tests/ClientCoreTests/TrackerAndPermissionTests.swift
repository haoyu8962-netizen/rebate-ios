import ClientCore
import Foundation
import Generated
import XCTest

/// 假的周期触发：测试手动 tick。
final class ManualTicker: RepeatingTicker {
    private(set) var interval: Int64?
    private var tick: (() -> Void)?

    func start(intervalMillis: Int64, tick: @escaping () -> Void) {
        interval = intervalMillis
        self.tick = tick
    }

    func stop() {
        tick = nil
    }

    func fire() {
        tick?()
    }
}

/// Tracker 的撤回清空、计时批量上报、device_id 补齐、持久化失败；PermissionRequester 的落盘位置与读失败。
final class TrackerAndPermissionTests: XCTestCase {
    private final class Sink {
        var online = true
        var uploaded: [String] = []
        var calls = 0

        func send(_ events: [String]) -> Bool {
            calls += 1
            if online {
                uploaded += events
            }
            return online
        }
    }

    private func makeQueue(
        _ file: MemoryFile,
        _ sink: Sink,
        privacy: String = "consented",
        device: @escaping () -> String? = { "device-t" },
        canUpload: @escaping () -> Bool = { true }
    ) -> TrackerQueue {
        TrackerQueue(
            readFile: file.read, writeFile: file.write, sink: sink.send, privacy: privacy, userId: { nil },
            currentDeviceId: device, platform: "ios", appVersion: "1.2.0", channel: "appstore",
            sessionId: "session-t", clock: { 1_790_661_600_000 }, canUpload: canUpload
        )
    }

    /// 验收：撤回同意后队列清空（含文件），之后不再采集、不再上报。
    func testWithdrawalClearsQueueAndStopsUploading() {
        let file = MemoryFile()
        let sink = Sink()
        sink.online = false
        let queue = makeQueue(file, sink)
        for _ in 0..<3 {
            queue.track(event: ClientEvents.appLaunch(page: "Home"))
        }
        XCTAssertEqual(queue.queueSize, 3)
        XCTAssertNotNil(file.value)

        queue.onPrivacyChanged(state: "basic_mode")

        XCTAssertEqual(queue.queueSize, 0)
        XCTAssertNil(file.value, "持久化的队列一并清掉")
        sink.online = true
        XCTAssertFalse(queue.track(event: ClientEvents.appLaunch(page: "Home")))
        queue.flush()
        XCTAssertTrue(sink.uploaded.isEmpty, "撤回后不再上报")

        let reopened = makeQueue(file, sink)
        reopened.flush()
        XCTAssertTrue(sink.uploaded.isEmpty, "重启后也不会复活撤回前的事件")
    }

    func testCleanupRegistryClearAndFailedClearIsRetried() {
        let file = MemoryFile()
        let sink = Sink()
        sink.online = false
        let queue = makeQueue(file, sink)
        queue.track(event: ClientEvents.appLaunch(page: "Home"))
        file.failWrites = true
        XCTAssertThrowsError(try queue.clearForCleanup())
        XCTAssertEqual(queue.queueSize, 0, "内存先清")
        file.failWrites = false
        queue.onPrivacyChanged(state: "consented")
        XCTAssertNil(file.value, "之后的隐私变化再清一次文件")
    }

    /// 共性 11：删队列文件失败时置上持久化的待清理标记；重启后确认清空前不加载、不上报旧队列。
    func testFailedClearKeepsPersistentMarkerAndBlocksReload() throws {
        let file = MemoryFile()
        let marker = MemoryFile()
        let sink = Sink()
        func make() -> TrackerQueue {
            TrackerQueue(
                readFile: file.read, writeFile: file.write, sink: sink.send, privacy: "consented", userId: { nil },
                currentDeviceId: { "device-t" }, platform: "ios", appVersion: "1.2.0", channel: nil,
                sessionId: "session-t", clock: { 0 }, canUpload: { false },
                readClearMarker: { marker.value != nil },
                writeClearMarker: { pending in try marker.write(pending ? "1" : nil) }
            )
        }
        let queue = make()
        queue.track(event: ClientEvents.appLaunch(page: "Home"))
        file.failWrites = true
        XCTAssertThrowsError(try queue.clearForCleanup())
        XCTAssertNotNil(marker.value, "待清理标记持久化")
        XCTAssertNotNil(file.value, "旧队列文件仍在")

        let restarted = make()
        XCTAssertEqual(restarted.queueSize, 0, "确认清空前不加载旧队列")
        XCTAssertFalse(restarted.track(event: ClientEvents.appLaunch(page: "Home")), "清不掉时不采集")
        restarted.flush()
        XCTAssertTrue(sink.uploaded.isEmpty)

        file.failWrites = false
        XCTAssertTrue(restarted.track(event: ClientEvents.appLaunch(page: "Home")), "重试清理成功后恢复")
        XCTAssertNil(marker.value, "清空后去掉标记")
        XCTAssertEqual(restarted.queueSize, 1)
    }

    /// 共性 16：批次交给 sink 之前再核对原始世代与发送守卫；取出后撤回的批次不提交。
    func testBatchIsRecheckedRightBeforeSink() {
        let file = MemoryFile()
        let sink = Sink()
        var queue: TrackerQueue?
        var withdrawOnFill = false
        var guardOpen = true
        var device: String?
        let made = TrackerQueue(
            readFile: file.read, writeFile: file.write, sink: sink.send, privacy: "consented", userId: { nil },
            currentDeviceId: {
                if withdrawOnFill {
                    queue?.onPrivacyChanged(state: "basic_mode")
                }
                return device
            },
            platform: "ios", appVersion: "1.2.0", channel: nil, sessionId: "session-t", clock: { 0 },
            canUpload: { true }, uploadGuard: { guardOpen }
        )
        queue = made
        made.track(event: ClientEvents.appLaunch(page: "Home"))
        device = "device-t"
        guardOpen = false
        made.flush()
        XCTAssertEqual(sink.calls, 0, "发送守卫关闭（撤回、切换环境中）不提交")
        XCTAssertEqual(made.queueSize, 1)

        guardOpen = true
        withdrawOnFill = true
        made.flush()
        XCTAssertEqual(sink.calls, 0, "取出批次后撤回：不提交")
        XCTAssertEqual(made.queueSize, 0)
    }

    func testTimerFlushesEveryTenSeconds() {
        let file = MemoryFile()
        let sink = Sink()
        let queue = makeQueue(file, sink)
        let ticker = ManualTicker()
        let timer = TrackerUploadTimer(queue: queue, ticker: ticker)
        timer.start()
        XCTAssertEqual(ticker.interval, 10000)

        queue.track(event: ClientEvents.appLaunch(page: "Home"))
        XCTAssertTrue(sink.uploaded.isEmpty, "不满 10 条不立即上报")
        ticker.fire()
        XCTAssertEqual(sink.uploaded.count, 1, "10 秒到了上报")
        XCTAssertEqual(queue.queueSize, 0)

        // 共性 8：定时上报与撤回同意遵守同一套状态检查。
        queue.track(event: ClientEvents.appLaunch(page: "Home"))
        queue.onPrivacyChanged(state: "basic_mode")
        ticker.fire()
        XCTAssertEqual(sink.uploaded.count, 1, "撤回后定时触发也不上报")
        timer.stop()
        ticker.fire()
        XCTAssertEqual(sink.uploaded.count, 1)
    }

    func testMissingDeviceIdIsFilledBeforeUploadOrWaits() throws {
        let file = MemoryFile()
        let sink = Sink()
        var device: String?
        let queue = makeQueue(file, sink, device: { device })
        queue.track(event: ClientEvents.appLaunch(page: "Home"))
        queue.flush()
        XCTAssertEqual(sink.calls, 0, "还没有 device_id 时先不上报")
        device = "device-late"
        queue.flush()
        let packet = try XCTUnwrap(sink.uploaded.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(packet.utf8)) as? [String: Any])
        XCTAssertEqual(object["device_id"] as? String, "device-late")
        XCTAssertEqual(object["channel"] as? String, "appstore")
        XCTAssertNil(object["user_id"], "游客不带 user_id")
    }

    func testPersistFailureRejectsEventAndKeepsUploadedOnesQueued() {
        let file = MemoryFile()
        let sink = Sink()
        let queue = makeQueue(file, sink, canUpload: { false })
        file.failWrites = true
        XCTAssertFalse(queue.track(event: ClientEvents.appLaunch(page: "Home")), "落盘失败不收")
        file.failWrites = false
        XCTAssertTrue(queue.track(event: ClientEvents.appLaunch(page: "Home")))
        file.failWrites = true
        let uploading = makeQueue(file, sink)
        uploading.flush()
        XCTAssertEqual(uploading.queueSize, 1, "移除没能落盘：保留在队列（先写文件再改内存）")
    }

    func testConditionalRequiredFieldsAreRejected() {
        let queue = makeQueue(MemoryFile(), Sink())
        let incomplete = ClientEvents.linkJump(
            page: "Home", phase: .purchase, unionPlatform: .taobao, step: .sdk, result: .launched
        )
        XCTAssertFalse(incomplete.missingRequired.isEmpty)
        XCTAssertFalse(queue.track(event: incomplete), "purchase 缺 attempt_id 等条件必填字段")
        let startup = ClientEvents.linkJump(
            page: "Home", phase: .startup, unionPlatform: .taobao, step: .sdk, result: .sdkInitFailed
        )
        XCTAssertTrue(queue.track(event: startup))
    }

    // MARK: - 权限

    func testThrottleAndLKGFilesAreNotInCaches() {
        for name in ["permission-throttle.json", "config-lkg.json", "tracker-queue.json"] {
            let path = ClientFile(name: name).url.path
            XCTAssertTrue(path.contains("Application Support"), path)
            XCTAssertFalse(path.contains("/Caches/"), "「清除缓存」不清：\(path)")
        }
    }

    /// 共性 1：清理时连同原子写的临时文件一起删。
    func testClearRemovesLeftoverTemporaryFile() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = ClientFile(name: "queue.json", baseDirectory: base)
        try file.write("{}")
        try Data("partial".utf8).write(to: file.temporaryURL)
        try file.write(nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.temporaryURL.path), "残留的 .tmp 一并删除")
    }

    func testClientFileRoundTrip() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = ClientFile(name: "probe.json", baseDirectory: base)
        XCTAssertNil(try file.read())
        try file.write("{\"v\":1}")
        XCTAssertEqual(try file.read(), "{\"v\":1}")
        try file.write(nil)
        XCTAssertNil(try file.read())
    }

    func testUnreadableThrottleRecordIsTreatedAsThrottledWhenDenied() async {
        let file = MemoryFile()
        file.failReads = true
        var guides = 0
        var systemCalls = 0
        let requester = PermissionRequester(
            readFile: file.read, writeFile: file.write, clock: { 0 }, platform: "ios",
            status: { _ in PermissionStatusRaw.denied },
            showRationale: { _, _ in },
            systemRequest: { _ in
                systemCalls += 1
                return PermissionStatusRaw.granted
            },
            showSettingsGuide: { _, _ in guides += 1 }
        )
        let result = await requester.request(permission: "photos")
        XCTAssertEqual(result.resultRaw, PermissionResultRaw.throttled, "节流记录读不出：不主动再弹")
        XCTAssertEqual(systemCalls, 0)
        XCTAssertEqual(guides, 1)

        let fromSettings = await requester.request(permission: "photos", fromSettingsEntry: true)
        XCTAssertEqual(fromSettings.resultRaw, PermissionResultRaw.granted, "设置入口主动点击不受节流")
    }

    func testUnknownPermissionIsUnavailableWithoutSystemCall() async {
        var systemCalls = 0
        let requester = PermissionRequester(
            readFile: { nil }, writeFile: { _ in }, clock: { 0 }, platform: "ios",
            status: { _ in PermissionStatusRaw.notAsked },
            showRationale: { _, _ in },
            systemRequest: { _ in
                systemCalls += 1
                return PermissionStatusRaw.granted
            },
            showSettingsGuide: { _, _ in }
        )
        let camera = await requester.request(permission: "camera")
        XCTAssertEqual(camera.resultRaw, PermissionResultRaw.unavailable, "相机 MVP 不提供")
        XCTAssertEqual(systemCalls, 0)
    }

    func testPurposeAlreadyShownSkipsRationale() async {
        var rationales = 0
        let requester = PermissionRequester(
            readFile: { nil }, writeFile: { _ in }, clock: { 0 }, platform: "ios",
            status: { _ in PermissionStatusRaw.notAsked },
            showRationale: { _, _ in rationales += 1 },
            systemRequest: { _ in PermissionStatusRaw.granted },
            showSettingsGuide: { _, _ in }
        )
        let result = await requester.request(permission: "push", purposeShown: true)
        XCTAssertEqual(result.resultRaw, PermissionResultRaw.granted)
        XCTAssertEqual(rationales, 0, "入口已经展示了用途（待跟单卡）")
    }
}
