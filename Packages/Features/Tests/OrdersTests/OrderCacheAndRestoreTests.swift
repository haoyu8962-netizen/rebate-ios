@testable import OrderCore
import XCTest

/// 断网缓存的落盘与清理（G10，共性第 20、28 条）与订单 Tab 根的保存 / 恢复（共性第 10、17、19、21、23、24 条）。
@MainActor
final class OrderCacheAndRestoreTests: XCTestCase {
    private func page(_ ids: [String]) -> OrderListData {
        OrderListData(items: ids.map { summary($0) }, nextCursor: "c2", earliestVisibleDate: nil)
    }

    private func summary(_ id: String) -> OrderSummary {
        OrderSummary(
            orderId: id, platform: "taobao", title: "t", imageUrl: nil, payAmountFen: 100, quantity: 1,
            orderNo: "37" + id, maskedOrderNo: nil, displayStatusRaw: "PAID", reason: nil, estRebateFen: 1, paidAt: nil,
            isOtherProduct: false, actualFen: nil, clawbackFen: nil
        )
    }

    private func detail(_ id: String) -> OrderDetail {
        OrderDetail(summary: summary(id), productKey: nil, reasonAction: [], timeline: [], expectedCreditPeriod: nil,
                    creditOverdue: false, appealPending: false, isPriceCompare: nil)
    }

    // MARK: - 缓存

    func testCacheIsPerAccountAndClearedOnAccountSwitch() throws {
        let root = temporaryDirectory()
        let store = OrderCacheStore(root: root)
        store.writeList(account: "a", scope: "self", data: page(["o1"]), fetchedAt: 10)
        XCTAssertEqual(store.readList(account: "a", scope: "self")?.data.items.map(\.orderId), ["o1"])
        XCTAssertNil(store.readList(account: "a", scope: "self")?.data.nextCursor, "缓存只存第一页，不存游标")
        XCTAssertNil(store.readList(account: "b", scope: "self"), "按账号隔离")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains("a"), "目录名是账号哈希，不落明文账号")
        store.reconcileOwner(account: "b")
        XCTAssertNil(store.readList(account: "a", scope: "self"), "换账号时删除旧账号缓存")
        store.reconcileOwner(account: nil)
        XCTAssertFalse(store.isPendingClear)
        let excluded = try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        _ = excluded
    }

    func testDetailCacheKeepsMostRecent30() {
        let store = OrderCacheStore(root: temporaryDirectory())
        for index in 0..<32 {
            store.writeDetail(account: "a", detail: detail("o\(index)"), fetchedAt: Int64(index))
        }
        XCTAssertNil(store.readDetail(account: "a", orderId: "o0"))
        XCTAssertNil(store.readDetail(account: "a", orderId: "o1"))
        XCTAssertNotNil(store.readDetail(account: "a", orderId: "o2"))
        store.writeDetail(account: "a", detail: detail("o2"), fetchedAt: 99)
        store.writeDetail(account: "a", detail: detail("o40"), fetchedAt: 100)
        XCTAssertNotNil(store.readDetail(account: "a", orderId: "o2"), "最近使用的排到最新")
        XCTAssertNil(store.readDetail(account: "a", orderId: "o3"))
    }

    func testEnumerationFailureKeepsPendingAndBlocksReadsAcrossRestart() throws {
        let root = temporaryDirectory()
        let store = OrderCacheStore(root: root)
        store.writeList(account: "a", scope: "self", data: page(["o1"]), fetchedAt: 10)
        store.lister = { _ in nil }
        XCTAssertThrowsError(try store.clearAll(), "目录在却枚举失败：不当成空目录，报失败")
        XCTAssertTrue(store.isPendingClear)
        XCTAssertNil(store.readList(account: "a", scope: "self"), "清理完成前不读回")
        // 「重启」：新实例同一位置，同账号重新登录；待清理标记在缓存目录之外（共性第 28 条），读之前先完成清理
        let restarted = OrderCacheStore(root: root)
        restarted.reconcileOwner(account: "a")
        XCTAssertNil(restarted.readList(account: "a", scope: "self"), "重启后不读回旧缓存")
        XCTAssertFalse(restarted.isPendingClear, "能枚举时完成清理并清掉标记")
        let flag = root.deletingLastPathComponent().appendingPathComponent("orders.pending_clear")
        XCTAssertFalse(FileManager.default.fileExists(atPath: flag.path))
    }

    func testPendingFlagLivesOutsideCacheDirectory() {
        let root = temporaryDirectory()
        let flag = OrderSiblingPendingFlag(root: root)
        XCTAssertTrue(flag.set())
        XCTAssertTrue(flag.isSet())
        let url = root.deletingLastPathComponent().appendingPathComponent("orders.pending_clear")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "标记与缓存目录同级、不在其中")
        try? FileManager.default.removeItem(at: root)
        XCTAssertTrue(flag.isSet(), "删掉缓存目录不会顺带删掉标记")
        XCTAssertTrue(flag.clear())
        XCTAssertFalse(flag.isSet())
    }

    func testCorruptFileTreatedAsNoCache() throws {
        let root = temporaryDirectory()
        let store = OrderCacheStore(root: root)
        store.writeList(account: "a", scope: "self", data: page(["o1"]), fetchedAt: 10)
        let file = root.appendingPathComponent(OrderCacheStore.hash("a")).appendingPathComponent("list_self.json")
        try Data("{broken".utf8).write(to: file)
        XCTAssertNil(store.readList(account: "a", scope: "self"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "坏文件删掉")
    }

    // MARK: - 恢复记录

    func testRestorerDoesNotPersistBeforeDecisionAndBindsAccount() throws {
        let file = OrderPageStateFile.beside(root: temporaryDirectory())
        let saved = OrderPageRecord(
            owner: OrderCacheStore.hash("a"), conditions: OrderConditions(
                scope: "share",
                group: "credited",
                keyword: "37123"
            ),
            anchor: "o9"
        )
        try file.save(JSONEncoder().encode(saved))
        let restorer = OrderPageRestorer(file: file)
        // 冷启动隐藏的默认条件先到：决策前不写盘，不覆盖恢复记录（共性第 23 条）
        restorer.persist(conditions: OrderConditions(scope: "self"), anchor: nil, account: "a")
        XCTAssertEqual(restorer.stored, saved)
        XCTAssertEqual(restorer.decide(account: "a"), saved)
        restorer.persist(conditions: OrderConditions(scope: "self"), anchor: "o1", account: "a")
        XCTAssertEqual(restorer.stored?.anchor, "o1")

        let other = OrderPageRestorer(file: file)
        XCTAssertNil(other.decide(account: "b"), "不是同一账号的记录丢弃（共性第 19 条）")
        XCTAssertNil(other.stored)

        restorer.persist(
            conditions: OrderConditions(scope: "self", keyword: "3712345678901234567"),
            anchor: nil,
            account: "a"
        )
        restorer.clear()
        XCTAssertNil(restorer.stored, "会话换代删除记录（可能含上一账号的完整订单号）")
    }

    func testAnchorRestoreWaitsLoadsMoreAlignsOnceAndFreezesRecording() {
        let keeper = OrderAnchorKeeper()
        keeper.begin(target: "o7")
        var snapshot = OrderListSnapshot(query: .initial(nil))
        snapshot.phase = .loading
        XCTAssertEqual(keeper.step(snapshot), .none)
        XCTAssertFalse(keeper.record(top: "o1"), "恢复进行中冻结记录（共性第 17 条）")
        XCTAssertEqual(keeper.recorded, "o7")
        snapshot.phase = .content
        snapshot.items = [summary("o1")]
        snapshot.nextCursor = "c2"
        XCTAssertEqual(keeper.step(snapshot), .loadMore, "目标未加载时不丢弃任务，继续翻页")
        snapshot.items.append(summary("o7"))
        // FU-IOS-0712 第 1 轮修复（F-X-19 实走）：目标之后不够一屏且还能翻页时先翻页；这里让列表到底，保持本例「目标出现即对齐一次」的原意
        snapshot.nextCursor = nil
        guard case let .align(id, task) = keeper.step(snapshot) else {
            return XCTFail("目标出现后安排一次对齐")
        }
        XCTAssertEqual(id, "o7")
        XCTAssertEqual(keeper.step(snapshot), .none, "对齐安排中不重复安排")
        XCTAssertFalse(keeper.confirm(task: task, round: snapshot.query.round + 1), "延迟回调复核轮次（共性第 24 条）")
        keeper.begin(target: "o7")
        guard case let .align(_, again) = keeper.step(snapshot) else {
            return XCTFail("应安排对齐")
        }
        XCTAssertTrue(keeper.confirm(task: again, round: snapshot.query.round))
        XCTAssertEqual(keeper.moves, 1, "只挪动一次")
        XCTAssertTrue(keeper.record(top: "o8"), "完成后按实际视口记录")
    }

    func testAnchorRestoreCancelledWhenRoundChanges() {
        let keeper = OrderAnchorKeeper()
        keeper.begin(target: "o7")
        var snapshot = OrderListSnapshot(query: .initial(nil))
        snapshot.phase = .loading
        _ = keeper.step(snapshot)
        var query = snapshot.query
        query.setGroup("credited")
        snapshot.query = query
        XCTAssertEqual(keeper.step(snapshot), .giveUp, "用户改了条件：取消旧恢复，不用旧条件覆盖新条件（共性第 21 条）")
        XCTAssertFalse(keeper.restoring)
    }
}
