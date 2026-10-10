import CouliNetwork
import Foundation
@testable import Trade
import XCTest

/// APP-08 iOS 第五次修复 NEW-02（S0）：授权拒绝、授权失败、50303 弹窗保存产生它们的尝试与固定来源。换号（来源变了）之后点旧弹窗的
/// 【仍去购买（无返利）】或【重试】：作废弹窗、不清授权上下文、零 open，提示重新点购买。对照：来源未变时照常发新 open，无返利原因
/// 只来自产生弹窗的同一来源（授权拒绝 auth_declined、授权失败 auth_failed、50303 没有原因）。
@MainActor
final class OldDialogOwnershipR3eTests: XCTestCase {
    private let authData: TradeObject = [
        "auth_url": "https://oauth.test/a?state=st1", "state": "st1", "auth_methods": ["web_code"],
    ]

    private enum Kind: CaseIterable {
        case declined
        case failed
        case unavailable50303
    }

    private enum Action: CaseIterable {
        case noRebate
        case retry
    }

    /// 停在 `kind` 弹窗的执行器；来源取 `origin` 盒子里的值（换号 = 改盒子）。
    private func rig(_ kind: Kind, origin: Locked<String>) async -> PurchaseHarness {
        let rig = PurchaseHarness()
        rig.controller.jumpOrigin = { origin.get() }
        rig.controller.jumpSource = { JumpSource(origin: origin.get(), request: nil) }
        rig.api.auto = { call in
            switch call.operationId {
            case TradeOperations.getTips: TradeFixtures.ok(["jump_tip": ["taobao": "x"]])
            case TradeOperations.bindUnion: TradeFixtures.ok(["platform": "taobao", "status": "invalid"])
            default: nil
            }
        }
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        switch kind {
        case .declined:
            rig.replyOpen(0, TradeFixtures.fail(30101, authData))
            await eventually { rig.controller.state.dialog == .authSheet(platform: "taobao", busy: false) }
            rig.controller.dismissDialog()
            XCTAssertEqual(rig.controller.state.dialog, .authDeclined(platform: "taobao", failed: false))
        case .failed:
            rig.replyOpen(0, TradeFixtures.fail(30101, authData))
            await eventually { rig.controller.state.dialog == .authSheet(platform: "taobao", busy: false) }
            rig.controller.authorize()
            await eventually { rig.controller.state.dialog == .authDeclined(platform: "taobao", failed: true) }
        case .unavailable50303:
            rig.replyOpen(0, TradeFixtures.fail(50303))
            await eventually {
                if case .notice(_, _, true, _, true) = rig.controller.state.dialog {
                    return true
                }
                return false
            }
        }
        return rig
    }

    private func perform(_ action: Action, _ rig: PurchaseHarness) {
        switch action {
        case .noRebate: rig.controller.buyWithoutRebate(rig.controller.state.dialogTicket)
        case .retry: rig.controller.retryPurchase(rig.controller.state.dialogTicket)
        }
    }

    /// 换号之后点旧弹窗：零 open、弹窗作废、授权上下文保留、提示重新点购买。
    func testOldDialogsAfterSwitchSendNoOpen() async {
        for kind in Kind.allCases {
            for action in Action.allCases {
                let origin = Locked("user-a#1#0#slot1")
                let rig = await rig(kind, origin: origin)
                let authCode = rig.controller.pendingAuthCode
                origin.set("user-b#2#0#slot1")
                perform(action, rig)
                await settle()
                XCTAssertEqual(rig.opens().count, 1, "\(kind) / \(action)：旧弹窗换号后零 open")
                XCTAssertNil(rig.controller.state.dialog, "\(kind) / \(action)：旧弹窗作废")
                XCTAssertEqual(rig.controller.state.toast?.key, PurchaseTextKeys.jumpExpired)
                XCTAssertEqual(rig.controller.pendingAuthCode, authCode, "\(kind) / \(action)：不清上下文")
            }
        }
    }

    /// 对照：来源未变时照常发新 open；无返利原因只来自弹窗本身。
    func testSameSourceDialogsStillWork() async {
        let reasons: [Kind: String] = [.declined: "auth_declined", .failed: "auth_failed"]
        for kind in Kind.allCases {
            for action in Action.allCases {
                let origin = Locked("user-a#1#0#slot1")
                let rig = await rig(kind, origin: origin)
                perform(action, rig)
                await eventually("\(kind) / \(action)：照常发新 open") { rig.opens().count == 2 }
                let body = TradeFixtures.body(rig.opens()[1])
                XCTAssertNotEqual(rig.opens()[1].idempotencyKey, rig.opens()[0].idempotencyKey, "新键")
                switch action {
                case .noRebate:
                    XCTAssertEqual(body["no_rebate"] as? Bool, true)
                    XCTAssertEqual(body["no_rebate_reason"] as? String, reasons[kind], "\(kind)：原因来自同一来源")
                case .retry:
                    XCTAssertNil(body["no_rebate"])
                }
            }
        }
    }
}
