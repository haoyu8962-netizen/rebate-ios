import ClientCore
import CouliNetwork
import Foundation
import Generated
@testable import MeCore
import WalletCore
import XCTest

/// FU-IOS-DELETION-REAPPLY-STALE-KEY 写测第 2 次（独立写测方）：注销页在「申请结果未知、本机还有未决记录」时的真实保证——页面是待确认卡、
/// 没有【撤回注销】（服务端读到冷静期 can_cancel = true 也一样），出口只有【确认】/【放弃】，两条都结束旧键，之后再申请用新键。
///
/// 依据：编排 D10-3452（MeCore/DeletionPresentation.swift 待确认卡优先于冷静期；网络层不加入口）、D10-2914。
/// 夹具：真实 `DeleteAccountController` / `SensitiveFlow`，网络换成 `FuPendingStoreApi`——在 App13a1FakeApi（按 operationId 脚本回答）
/// 外面加一份最小的本机未决记录（只模拟 requestDeletion 一个键；语义取自 PendingKeyStore：没有统一外壳 → 记录 unknown；有外壳的首次
/// 发送结果 → 删除；确认得 0 / 3xxxx / 20903、放弃得 abandoned → 删除；同一操作已有记录时新的首次发送本地拒绝 pending_key_unresolved）。
/// 真实 PendingKeyStore 下的同一组保证另见 WalletCoreTests/FuIosDeletionReapplyPipelineTests。
@MainActor
final class FuIosDeletionPendingCardTests: App13a1ControllerTestCase {
    private var pages: [FuPendingPage] = []

    override func tearDown() async throws {
        for page in pages {
            page.controller.leave()
        }
        pages = []
        try await super.tearDown()
    }

    // MARK: - 待确认卡在时没有撤回入口

    /// 申请超时 → 待确认卡；再次进入页面读到冷静期（can_cancel = true）：页面仍是待确认卡、没有【撤回注销】；旧的撤回回调零请求，
    /// 再点申请也不发。
    func testPendingCardHidesCancelWhileServerShowsCooling() async {
        let page = await pageWithPendingCard()
        page.api.base.on("getDeletion", App13a1Replies.ok(App13a1Replies.cooling(true)))
        await reenter(page) { $0.state.read?.deletion?.status == Deletion.cooling }

        let controller = page.controller
        XCTAssertEqual(controller.view.kind, .pendingConfirm, "待确认卡优先于冷静期")
        XCTAssertFalse(controller.view.showCancel, "待确认卡在：没有【撤回注销】")
        XCTAssertEqual(controller.flow.state.pending?.key, "fu-key-1", "待确认卡是原键")

        controller.cancelDeletion(version: controller.state.version, owner: controller.identity.owner)
        controller.apply(version: controller.state.version, owner: controller.identity.owner)
        await quiet(0.3)
        await page.idle()
        XCTAssertEqual(page.api.base.calls("cancelDeletion").count, 0, "待确认卡在：撤回回调零请求")
        XCTAssertFalse(controller.state.cancelling)
        XCTAssertEqual(page.api.base.calls("requestDeletion").count, 1, "待确认卡在：再点申请不发")
    }

    // MARK: - 跨设备撤回

    /// 本机申请结果未知、他端已撤回（getDeletion 读到 cancelled）→ 回到页面仍是待确认卡、没有撤回 →【确认上一次提交】（服务端回放这个键
    /// 存下的旧冷静期应答，code 0）→ 记录删除 → 再进页读到已撤回 → 再申请：新键、照常发出。
    func testCrossDeviceCancelThenConfirmNextApplyUsesNewKey() async throws {
        let page = await pageWithPendingCard(then: App13a1Replies.ok(App13a1Replies.cooling(true)))
        page.api.base.on("getDeletion", App13a1Replies.ok(App13a1Replies.cancelled))
        await reenter(page) { $0.state.read?.deletion?.status == Deletion.cancelled }
        let controller = page.controller
        XCTAssertEqual(controller.view.kind, .pendingConfirm, "他端已撤回：本机记录还在，仍是待确认卡")
        XCTAssertFalse(controller.view.showCancel)

        let key = try XCTUnwrap(controller.flow.state.pending?.key)
        controller.confirmPending(key: key, owner: controller.identity.owner)
        await waitFor("确认没有结算") { controller.flow.state.pending == nil }
        await page.idle()
        XCTAssertNil(page.api.record, "确认得 0：本机记录删除")

        try await reapplyWithNewKey(page, expected: ["fu-key-1", "fu-key-1", "fu-key-2"], "跨设备撤回后确认")
    }

    /// 同上，出口走【放弃上一次提交】（二次确认后，得 abandoned）→ 记录删除 → 再申请：新键、照常发出。
    func testCrossDeviceCancelThenAbandonNextApplyUsesNewKey() async throws {
        let page = await pageWithPendingCard()
        page.api.base.on("getDeletion", App13a1Replies.ok(App13a1Replies.cancelled))
        await reenter(page) { $0.state.read?.deletion?.status == Deletion.cancelled }
        let controller = page.controller
        XCTAssertEqual(controller.view.kind, .pendingConfirm)
        XCTAssertFalse(controller.view.showCancel)

        let key = try XCTUnwrap(controller.flow.state.pending?.key)
        let owner = controller.identity.owner
        controller.askAbandon(key: key, owner: owner)
        XCTAssertEqual(controller.flow.state.abandonConfirmKey, key, "前提：弹出放弃二次确认")
        controller.abandon(key: key, owner: owner)
        await waitFor("放弃没有结算") { controller.flow.state.pending == nil }
        await page.idle()
        XCTAssertEqual(page.api.base.calls("abandonIdempotencyKey").count, 1, "作废请求发出 1 次")
        XCTAssertNil(page.api.record, "放弃得 abandoned：本机记录删除")

        try await reapplyWithNewKey(page, expected: ["fu-key-1", "fu-key-2"], "跨设备撤回后放弃")
    }

    // MARK: - 驱动

    /// 进页 → 勾选 → 申请超时：本机记录 unknown、页面待确认卡。`then` 是之后 requestDeletion（确认 / 再申请）的回答。
    private func pageWithPendingCard(
        then next: ApiResult = App13a1Replies.ok(App13a1Replies.cooling(true)),
        file: StaticString = #filePath, line: UInt = #line
    ) async -> FuPendingPage {
        let page = FuPendingPage()
        pages.append(page)
        page.api.base.on("requestDeletion", App13a1Replies.transport, next)
        let controller = page.controller
        controller.start()
        await waitFor("进度与资金没有读到", file: file, line: line) {
            controller.state.read != nil && controller.state.funds != nil
        }
        await page.idle()
        page.check()
        controller.apply(version: controller.state.version, owner: controller.identity.owner)
        await waitFor("申请超时后没有待确认卡", file: file, line: line) { controller.flow.state.pending != nil }
        await page.idle()
        XCTAssertEqual(page.api.record?.stateRaw, PendingKeyStore.unknown, "前提：本机记录 unknown", file: file, line: line)
        XCTAssertEqual(controller.view.kind, .pendingConfirm, "前提：待确认卡", file: file, line: line)
        return page
    }

    /// 离开再回到页面：按本机记录重建待确认、重读进度与资金，等到 `ready`。
    private func reenter(
        _ page: FuPendingPage, file: StaticString = #filePath, line: UInt = #line,
        until ready: @escaping (DeleteAccountController) -> Bool
    ) async {
        page.controller.setVisible(false)
        page.controller.setVisible(true)
        await waitFor("再次进入后没有读到预期进度", file: file, line: line) { ready(page.controller) }
        await page.idle()
    }

    /// 键结束后：再进页读到已撤回 → 回到初始态 → 再申请照常发出、带新键（请求记录含确认用的原键）。
    private func reapplyWithNewKey(
        _ page: FuPendingPage, expected: [String?], _ label: String, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let controller = page.controller
        await reenter(page, file: file, line: line) { $0.view.kind == .initial && $0.state.funds != nil }
        XCTAssertNil(controller.flow.state.pending, "\(label)：待确认卡不回来", file: file, line: line)
        page.check()
        XCTAssertTrue(controller.applyEnabled, "\(label)：前提：【申请注销】可点", file: file, line: line)
        controller.apply(version: controller.state.version, owner: controller.identity.owner)
        await waitFor("\(label)：再申请没有发出", file: file, line: line) {
            page.api.base.calls("requestDeletion").count == expected.count
        }
        await page.idle()
        XCTAssertEqual(
            page.api.base.calls("requestDeletion").map(\.idempotencyKey), expected, "\(label)：再申请必须用新键",
            file: file, line: line
        )
        XCTAssertNil(controller.flow.state.error, "\(label)：再申请没有被本地拒绝", file: file, line: line)
        XCTAssertNil(page.api.record, "\(label)：再申请成功后无未决记录", file: file, line: line)
    }
}

// MARK: - 夹具

/// App13a1FakeApi 外加 requestDeletion 一个键的本机未决记录（语义见上方类注释）。
final class FuPendingStoreApi: WalletApi, @unchecked Sendable {
    static let operation = "requestDeletion"
    let base = App13a1FakeApi()
    private let lock = NSLock()
    private var held: PendingKeyRecord?

    var record: PendingKeyRecord? {
        lock.withLock { held }
    }

    func send(
        _ call: ApiCall, isValid: @escaping @Sendable () -> Bool, sendAllowed: @escaping @Sendable () -> Bool,
        expected: RequestOwnership?
    ) async -> ApiResult {
        guard call.operationId == Self.operation else {
            return await base.send(call, isValid: isValid, sendAllowed: sendAllowed, expected: expected)
        }
        // PendingKeyStore.admit：同一操作已有记录 → 不发
        if record != nil {
            return .localReject(reason: LocalRejectReason.pendingKeyUnresolved)
        }
        let result = await base.send(call, isValid: isValid, sendAllowed: sendAllowed, expected: expected)
        lock.withLock {
            if case .transportFailure = result {
                held = PendingKeyRecord(
                    key: call.idempotencyKey ?? "", operationId: Self.operation, body: call.body ?? "",
                    account: "user-a", summary: call.summary, stateRaw: PendingKeyStore.unknown, everUnknown: true
                )
            } else {
                held = nil
            }
        }
        return result
    }

    func confirmPending(operationId: String, stepUpToken: String?, target: PendingTarget) async -> ApiResult {
        guard record?.key == target.key else {
            return .localReject(reason: LocalRejectReason.pendingKeyUnresolved)
        }
        let result = await base.confirmPending(operationId: operationId, stepUpToken: stepUpToken, target: target)
        lock.withLock {
            if Self.ends(result) {
                held = nil
            }
        }
        return result
    }

    func abandonPending(operationId: String, target: PendingTarget) async -> ApiResult {
        guard record?.key == target.key else {
            return .localReject(reason: LocalRejectReason.pendingKeyUnresolved)
        }
        let result = await base.abandonPending(operationId: operationId, target: target)
        lock.withLock { held = nil }
        return result
    }

    func pendingStatus(operationId: String) async -> PendingLookup {
        guard operationId == Self.operation, let record else { return .none }
        return .record(record)
    }

    func restorePending() async {}

    /// 出现过结果未知的键：成功、3xxxx、20903 结束；其余（5xxxx、1xxxx、无响应）保持 unknown。
    private static func ends(_ result: ApiResult) -> Bool {
        switch result {
        case .success:
            true
        case let .failure(code, _, _, _, _, _):
            code == 20903 || (30000...39999).contains(code)
        default:
            false
        }
    }
}

/// 一张注销页（full 会话、从「其他」进入：撤回成功留在本页），键按点击顺序为 fu-key-1、fu-key-2…。
@MainActor
final class FuPendingPage {
    let api = FuPendingStoreApi()
    let env = App13a1ControllerEnv()
    let ports = App13a1FakePorts(scope: DeletionScope.full)
    let deps: WalletDeps
    let controller: DeleteAccountController

    init() {
        env.bound = true
        deps = WalletDeps(
            api: api, env: env, gates: WalletGates(), cache: nil, mask: AmountMaskStore(), realname: nil, labor: nil
        )
        let keys = FuReapplyKeys()
        deps.newKey = { keys.next() }
        controller = DeleteAccountController(
            deps: deps, identity: DeletionIdentity(owner: env.owner, scope: DeletionScope.full, source: .other),
            page: UUID(), ports: ports
        )
        controller.setVisible(true)
    }

    /// 勾选框保持勾上（`toggleWaiver` 是切换）。
    func check() {
        guard !controller.state.waiver else { return }
        controller.toggleWaiver(version: controller.state.version, owner: controller.identity.owner)
    }

    func idle() async {
        for _ in 0..<8 {
            await controller.flow.stepUp.whenIdle()
            await controller.flow.whenIdle()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
