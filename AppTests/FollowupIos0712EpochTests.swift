import Config
@testable import Couli
import CouliNetwork
import Foundation
import Login
@testable import OrderCore
import Privacy
import SecureStore
import Session
@testable import WalletCore
import XCTest

/// FU-IOS-0712 第 1 项（App 层）：按「账号 + 持久化登录世代」分区的本机缓存（订单断网缓存、钱包摘要与金额草稿、订单恢复记录、phone_bound）。
/// 多重故障（令牌所在 Keychain 整体不可写 + 各缓存删不掉 + 待清理标记写不进）→ 未重新登录即重建进程 → 同账号重新登录 → 再重建：
/// 一律读不回旧登录的数据（旧文件确实还在盘上）。另核对生产接线。
@MainActor
final class FollowupIos0712EpochTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fuios0712-epoch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("cache"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("marks"),
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        for path in ["cache/orders", "cache/wallet", "cache"] {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent(path).path
            )
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /// 一个「进程」：真实 SecureSessionTokens（同一份 Keychain 内存替身 + 同一个独立撤销文件）、真实 ApiClient、真实缓存存储，按 App 的接线
    /// 接登录世代来源。待清理标记换成写不进的（多重故障：标记也落不下）。
    private struct Process {
        let tokens: SecureSessionTokens
        let client: ApiClient
        let orders: OrderCacheStore
        let wallet: WalletCacheStore
        let restorer: OrderPageRestorer
        let phone: PhoneBindingStore
    }

    private func process(_ keychain: MemorySecureStore) -> Process {
        let tokens = SecureSessionTokens(
            store: keychain,
            revocationFile: FileSessionRevocationMarks(url: dir.appendingPathComponent("marks/session.revoked"))
        )
        let network = AppNetwork(
            tokens: tokens, pendingBackend: MemoryPendingKeyBackend(), device: UnregisteredDevice(),
            withdrawalRegistry: EnvironmentSwitchCleanerRegistry(),
            environmentRegistry: EnvironmentSwitchCleanerRegistry(),
            credentialsReadable: { true }
        )
        let client = network.client
        let orders = OrderCacheStore(root: dir.appendingPathComponent("cache/orders"), flag: UnwritableFlag())
        orders.partitionedByLoginEpoch = true
        let wallet = WalletCacheStore(root: dir.appendingPathComponent("cache/wallet"), flag: UnwritableFlag())
        wallet.partitionedByLoginEpoch = true
        let restorer = OrderPageRestorer(file: orders.pageState, unit: nil)
        restorer.partitionKey = { orders.partitionKey(account: $0, loginEpoch: $1) }
        let phone = PhoneBindingStore()
        phone.loginEpoch = { client.loginEpoch(ifGeneration: $0, credentialsReadable: true) }
        return Process(tokens: tokens, client: client, orders: orders, wallet: wallet, restorer: restorer, phone: phone)
    }

    private static let list = OrderListData(items: [], nextCursor: nil, earliestVisibleDate: "2026-10-01")
    private static let summary = WalletSummary(
        availableFen: 1234, withdrawableFen: 1000, negativeFen: 0, frozenFen: 0, estimatedTotalFen: 0, estimatedFen: 0,
        pendingCreditFen: 0, pendingCreditPausedFen: 0, nextCreditPeriod: nil, creditOverdue: false, withdrawnFen: 0,
        riskPausedReason: nil, withdrawEnabled: true
    )

    /// 此刻构造的页面会固定的登录世代（R1-01：缓存读写只用页面固定身份的世代；这里模拟「此刻打开的页面」）。
    private func epochNow(_ proc: Process) -> String? {
        proc.client.currentIdentity(credentialsReadable: true).loginEpoch
    }

    private func readsNothingOld(_ proc: Process, _ label: String) {
        let epoch = epochNow(proc)
        XCTAssertNil(
            proc.orders.readList(account: "user-a", loginEpoch: epoch, scope: OrderQuery.selfScope),
            "\(label)：订单缓存读不回"
        )
        XCTAssertNil(proc.wallet.read(account: "user-a", loginEpoch: epoch), "\(label)：钱包摘要读不回")
        XCTAssertNil(proc.wallet.readDraft(account: "user-a", loginEpoch: epoch), "\(label)：金额草稿读不回")
        XCTAssertNil(proc.restorer.decide(account: "user-a", loginEpoch: epoch), "\(label)：订单恢复记录不恢复")
    }

    /// 第一次登录（E1）写下四类数据。
    private func seedFirstLogin(_ first: Process) throws {
        try first.tokens.save(access: "at-1", refresh: "rt-1", scope: "full", account: "user-a", loginEpoch: "E1")
        first.orders.writeList(
            account: "user-a", loginEpoch: "E1", scope: OrderQuery.selfScope, data: Self.list, fetchedAt: 1
        )
        first.wallet.write(
            account: "user-a", loginEpoch: "E1", summary: Self.summary, fetchedAt: 1, ticket: first.wallet.generation
        )
        first.wallet.writeDraft(account: "user-a", loginEpoch: "E1", amount: "8.5", ticket: first.wallet.generation)
        XCTAssertNil(first.restorer.decide(account: "user-a", loginEpoch: "E1"))
        first.restorer.persist(
            conditions: OrderConditions(scope: OrderQuery.selfScope),
            anchor: "o-1",
            account: "user-a", loginEpoch: "E1"
        )
        first.phone.record(true, generation: first.client.sessionGeneration)
        XCTAssertNotNil(
            first.orders.readList(account: "user-a", loginEpoch: "E1", scope: OrderQuery.selfScope), "前提：写进了"
        )
        XCTAssertEqual(first.wallet.readDraft(account: "user-a", loginEpoch: "E1"), "8.5")
        XCTAssertNotNil(first.restorer.stored)
        XCTAssertEqual(first.phone.bound(generation: first.client.sessionGeneration), true)
    }

    private func setCachePermissions(_ mode: Int) throws {
        for path in ["cache/orders", "cache/wallet", "cache"] {
            try FileManager.default.setAttributes(
                [.posixPermissions: mode], ofItemAtPath: dir.appendingPathComponent(path).path
            )
        }
    }

    func testMultiFaultSameAccountReloginAndRebuildNeverReadBackOldLoginCaches() throws {
        let keychain = MemorySecureStore()
        let first = process(keychain)
        try seedFirstLogin(first)

        // 多重故障：Keychain 整体不可写（撤销标记与令牌删除都失败）+ 缓存目录删不掉 + 待清理标记写不进
        keychain.failWrites = true
        try setCachePermissions(0o555)
        first.client.signOut()
        XCTAssertThrowsError(try first.orders.clearAll())
        XCTAssertThrowsError(try first.wallet.clearAll())
        XCTAssertFalse(first.restorer.clear(), "恢复记录删不掉")
        XCTAssertNotNil(try? keychain.data(forAccount: SecureSessionTokens.keychainAccount), "令牌还在 Keychain")

        // 未重新登录即重建进程（故障仍在）：会话读不回、世代未知，四类数据都读不回
        let rebuilt = process(keychain)
        XCTAssertNil(try rebuilt.tokens.readSession(), "独立撤销文件阻断旧会话")
        XCTAssertNil(rebuilt.client.sessionLoginEpoch(credentialsReadable: true))
        readsNothingOld(rebuilt, "重建")
        XCTAssertNil(rebuilt.phone.bound(generation: rebuilt.client.sessionGeneration))

        // 存储恢复、同账号重新登录（换新世代），旧文件仍在盘上
        keychain.failWrites = false
        let relogin = process(keychain)
        try relogin.tokens.save(access: "at-2", refresh: "rt-2", scope: "full", account: "user-a")
        let epoch = try XCTUnwrap(relogin.client.sessionLoginEpoch(credentialsReadable: true))
        XCTAssertNotEqual(epoch, "E1")
        XCTAssertFalse(
            (try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("cache/orders").path))
                .filter { $0 != "owner" }.isEmpty, "旧登录的订单缓存文件确实还在"
        )
        XCTAssertTrue(relogin.orders.pageState.exists, "旧恢复记录文件确实还在")
        readsNothingOld(relogin, "同账号重新登录")
        // 与此同时：同一进程里记在旧世代下的 phone_bound，会话世代相同而登录世代换了也不认
        first.phone.loginEpoch = { _ in "E-new" }
        XCTAssertNil(first.phone.bound(generation: first.client.sessionGeneration), "登录世代换了：phone_bound 未知")

        // 再重建：仍读不回旧数据；新世代自己写的照常可读
        let again = process(keychain)
        readsNothingOld(again, "再重建")
        try setCachePermissions(0o755)
        again.wallet.write(
            account: "user-a", loginEpoch: epochNow(again), summary: Self.summary, fetchedAt: 2,
            ticket: again.wallet.generation
        )
        XCTAssertEqual(again.wallet.read(account: "user-a", loginEpoch: epochNow(again))?.fetchedAt, 2, "新世代写入可读")
    }

    /// 世代未知（升级前没有世代的会话、凭据不可读）：不读不写，也不按归属删别人的缓存；页面绑定时世代未知，之后世代恢复也不补写（教训 11）。
    func testUnknownEpochNeitherReadsNorWritesAndUnknownBindingNeverWrites() throws {
        let keychain = MemorySecureStore()
        try keychain.set(
            Data(#"{"access":"a","refresh":"r","scope":"full","account":"user-a"}"#.utf8),
            forAccount: SecureSessionTokens.keychainAccount
        )
        let proc = process(keychain)
        XCTAssertNil(proc.client.sessionLoginEpoch(credentialsReadable: true), "升级前的会话没有世代")
        let fixed = epochNow(proc)
        XCTAssertNil(fixed, "此刻打开的页面固定的世代也未知")
        proc.orders.writeList(
            account: "user-a", loginEpoch: fixed, scope: OrderQuery.selfScope, data: Self.list, fetchedAt: 1
        )
        proc.wallet.write(
            account: "user-a", loginEpoch: fixed, summary: Self.summary, fetchedAt: 1, ticket: proc.wallet.generation
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cache/orders/owner").path),
                       "世代未知：不写")
        XCTAssertNil(proc.wallet.read(account: "user-a", loginEpoch: fixed))
        XCTAssertNil(proc.restorer.decide(account: "user-a", loginEpoch: fixed))
        XCTAssertEqual(proc.restorer.binding, .unknown)
        // 世代恢复（同账号重新登录）后，绑定时未知的页面仍不写（页面带的仍是它固定的未知世代；恢复记录的绑定也不补）
        try proc.tokens.save(access: "a2", refresh: "r2", scope: "full", account: "user-a")
        XCTAssertNotNil(epochNow(proc))
        proc.restorer.persist(
            conditions: OrderConditions(scope: OrderQuery.selfScope), anchor: nil, account: "user-a", loginEpoch: fixed
        )
        XCTAssertNil(proc.restorer.stored, "未知绑定不用此刻的世代补绑")
        proc.phone.record(true, generation: proc.client.sessionGeneration)
        XCTAssertEqual(proc.phone.bound(generation: proc.client.sessionGeneration), true)
    }

    /// 生产接线：令牌存储接了独立撤销文件；AppOrders / AppWallet 把缓存与恢复记录接到 ApiClient 的登录世代；phone_bound 同样接上。
    func testProductionWiringBindsLoginEpochEverywhere() throws {
        XCTAssertTrue(SecureSessionTokens.production().hasIndependentRevocation)
        let suite = "fuios0712-wiring-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = OrdersAppFixture.make(suiteName: suite, defaults: defaults)
        let epoch = try XCTUnwrap(fixture.tokens.loginEpoch)
        XCTAssertTrue(fixture.orders.cache.partitionedByLoginEpoch)
        // R1-01：执行器固定身份与登录世代同一次读取；分区键只按固定身份算
        let owner = fixture.orders.currentOwner()
        XCTAssertEqual(owner.account, "user-a")
        XCTAssertEqual(owner.loginEpoch, epoch)
        XCTAssertEqual(
            fixture.orders.cache.partitionKey(account: "user-a", loginEpoch: owner.loginEpoch),
            OrderCacheStore.hash("user-a\u{1F}" + epoch)
        )
        XCTAssertNil(fixture.orders.cache.partitionKey(account: "user-a", loginEpoch: nil), "世代未知：无分区")
        XCTAssertEqual(
            fixture.orders.restorer.partitionKey("user-a", epoch),
            fixture.orders.cache.partitionKey(account: "user-a", loginEpoch: epoch)
        )
        let generation = fixture.network.client.sessionGeneration
        XCTAssertEqual(fixture.login.phone.loginEpoch?(generation), epoch)
        XCTAssertNil(fixture.login.phone.loginEpoch?(generation &+ 1), "不是那一代会话：未知")
        let wallet = WalletAppFixture.make(suiteName: suite + "-w", defaults: defaults)
        XCTAssertTrue(wallet.cleaner.store.partitionedByLoginEpoch)
        XCTAssertEqual(wallet.wallet.currentOwner().loginEpoch, "fixture-login-user-a")
        // 撤回同意 / 切换环境竖起禁读屏障：世代未知、不读令牌
        wallet.network.client.invalidateSessions()
        XCTAssertNil(wallet.wallet.currentOwner().loginEpoch)
        XCTAssertNil(fixture.orders.cache.partitionKey(
            account: "user-a",
            loginEpoch: wallet.wallet.currentOwner().loginEpoch
        ))
    }
}

/// 写不进的待清理标记（多重故障）。
private final class UnwritableFlag: OrderPendingClearFlag {
    func isSet() -> Bool {
        false
    }

    func set() -> Bool {
        false
    }

    func clear() -> Bool {
        true
    }
}
