import Combine
import CouliNetwork
import Foundation
import Generated
@testable import HomeCore
import Router
import XCTest

/// 一套控制器依赖（每个用例独立的存储目录与 UserDefaults 套件）。
@MainActor
final class HomeRig {
    let port: FakePort?
    let articles = FakeArticles()
    let clock: ManualClock
    let signals = FakeSignals()
    let images = FakeImages()
    let gate: RetryAfterGate
    let dedupe = CardErrorDedupeBox()
    let root: URL
    let lkg: HomeLkgStore
    let prefs: HomePrefsStore
    let defaults: UserDefaults
    private let suiteName: String
    var bundled: Data? = HomeBundled.data()
    var events: [TrackEvent] = []
    var opened: [HomeTap] = []
    var forceUpdates = 0

    init(port: FakePort? = FakePort(), clock: ManualClock = ManualClock(), name: String = #function) {
        self.port = port
        self.clock = clock
        let unique = "home-test-\(name.filter(\.isLetter))-\(UUID().uuidString)"
        root = FileManager.default.temporaryDirectory.appendingPathComponent(unique, isDirectory: true)
            .appendingPathComponent(HomeLkgStore.directoryName, isDirectory: true)
        suiteName = unique
        defaults = UserDefaults(suiteName: unique)!
        lkg = HomeLkgStore(root: root)
        prefs = HomePrefsStore(defaults: defaults)
        gate = RetryAfterGate(clock: clock.clock)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        defaults.removePersistentDomain(forName: suiteName)
    }

    func deps(lkg: HomeLkgStore? = nil, prefs: HomePrefsStore? = nil, port: HomeContractPort?? = nil) -> HomeDeps {
        HomeDeps(
            port: port ?? self.port, articles: articles, lkg: lkg ?? self.lkg, prefs: prefs ?? self.prefs,
            signals: signals, timers: clock, clock: clock.clock, images: images,
            bundled: { [unowned self] in bundled }, appVersion: "1.10.0", gate: gate, dedupe: dedupe,
            track: { [unowned self] in events.append($0) }, open: { [unowned self] in opened.append($0) },
            forceUpdate: { [unowned self] in forceUpdates += 1 }, text: HomeKit.text
        )
    }

    func controller(
        _ identity: HomeIdentity = HomeKit.memberA, preview: Bool = false, lkg: HomeLkgStore? = nil,
        port: HomeContractPort?? = nil
    ) -> HomeController {
        HomeController(identity: identity, deps: deps(lkg: lkg, port: port), preview: preview)
    }

    /// 冷启动并等这一轮已发起的任务结算（不推进计时）。
    func start(_ controller: HomeController) async {
        controller.start()
        await controller.whenIdle()
    }

    func seedLkg(_ page: [String: Any], for identity: HomeIdentity = HomeKit.memberA) throws {
        let key = try XCTUnwrap(identity.lkgScope, "该身份没有 LKG 分区")
        XCTAssertTrue(lkg.write(key, HomeVectors.data(page), ticket: lkg.ticket()), "LKG 种子没写进")
    }

    func readLkgVersion(for identity: HomeIdentity = HomeKit.memberA) -> Int? {
        guard let key = identity.lkgScope, let data = lkg.read(key),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["version"] as? Int
    }

    var cardErrors: [TrackEvent] {
        events.filter { $0.name == "sdui_card_error" }
    }
}

extension HomeKit {
    static let memberA = HomeIdentity(env: "test", level: .member, userId: "user-a", loginEpoch: "e1")
    static let memberB = HomeIdentity(env: "test", level: .member, userId: "user-b", loginEpoch: "e1")
    static let guest = HomeIdentity(env: "test", level: .guest, userId: nil, loginEpoch: nil)
    static let basic = HomeIdentity(env: "test", level: .basic, userId: nil, loginEpoch: nil)

    /// 文案：返回「键|变量」，测试据此核对文案键与 trace6（真实文字由 App 的文案函数给）。
    static let text: @MainActor (String, [String: String]) -> String = { key, vars in
        vars.isEmpty ? key : key + "|" + vars.keys.sorted().map { "\($0)=\(vars[$0] ?? "")" }.joined(separator: ",")
    }
}

extension HomeUiState {
    func section(_ id: String) -> HomeSectionUi? {
        sections.first { $0.id == id }
    }

    var sectionIds: [String] {
        sections.map(\.id)
    }
}

/// 在 MainActor 上轮询一个条件（只用于等待「已发生」的结果；负向断言一律在 `whenIdle()` 之后做）。
@MainActor
func waitFor(_ message: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("等待超时：\(message)")
            return
        }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// 用一套 HomeRig 的执行器测试基类（每个用例独立的存储目录与 UserDefaults 套件）。
@MainActor
class HomeRigTestCase: XCTestCase {
    var rig: HomeRig!

    override func setUp() async throws {
        rig = HomeRig()
    }

    override func tearDown() async throws {
        rig.tearDown()
    }

    /// 一张活动入口卡的页面。
    func page(_ version: Int, title: String = "测试网络版") -> [String: Any] {
        HomeKit.page(version: version, [HomeKit.activity("act_\(version)", titles: [title])])
    }

    /// 有请求被测试挂住时的冷启动：不能等 whenIdle（它要等全部在途请求），改为等「请求已发到端口入口」。
    func startHeld(_ controller: HomeController, calls: Int = 1) async {
        controller.start()
        await waitFor("冷启动的页面请求没发出") { (rig.port?.pageCalls.count ?? 0) >= calls }
    }

    /// 没有 LKG 的冷启动显示这一页的网络版（只看网络版的渲染）。
    func show(_ page: [String: Any], identity: HomeIdentity = HomeKit.memberA) async -> HomeController {
        try? rig.lkg.clearAll()
        rig.port?.setPage(HomeKit.ok(page))
        let controller = rig.controller(identity)
        await rig.start(controller)
        XCTAssertEqual(controller.state.source, .network, "前提：显示的是网络版")
        return controller
    }
}
