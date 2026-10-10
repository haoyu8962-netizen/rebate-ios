import Foundation
import OrderCore
import Orders
import Privacy
import Router
import SwiftUI
import Trade

/// 发起购买的页面上的待跟单卡（AppOrders 的一部分；G07 ②，共性第 43 条，iOS RC-06）。
extension AppOrders {
    /// 商品详情 / 搜索页的待跟单卡：外跳（拉起 App、交浏览器、复制口令）之后，回到前台时拉一次，只显示同平台那一张；页面出栈时作废。
    func pendingSlot(for destination: RouteDestination, purchase: OpenPurchaseController?,
                     trade: AppTrade?) -> AnyView {
        let service = PendingTrackService(api: api, hub: hub, env: self)
        let host = PendingTrackSlotHost(service: service)
        let id = destination.id
        slotSerial += 1
        slots[id] = PendingSlot(service: service, host: host, serial: slotSerial, awaiting: nil)
        // 外跳发起时固定来源（会话、环境与 slot 世代，iOS RC-06）；完成事件带着它交付，与持有者此刻的来源比较
        purchase?.jumpOrigin = { [weak self] in self?.jumpOrigin(id) }
        // 来源与请求归属一次读取（JumpTip 的 getTips / markTipRead 带固定归属交网络层比较，iOS RC-06）
        purchase?.jumpSource = { [weak self] in self?.jumpSource(id) ?? JumpSource(origin: nil, request: nil) }
        purchase?.onJumpedOut = { [weak self, weak trade] platform, origin in
            self?.jumped(id, platform: platform, origin: origin, visible: trade?.isPageVisible(id) ?? false)
        }
        lifetimes.register(destination) { [weak self] in
            self?.slots.removeValue(forKey: id)?.service.leave()
        }
        let router = router
        return AnyView(PendingTrackSlotView(host: host, texts: texts, padded: true) {
            router.open(RouteRequest(route: AppOrderRoutes.findOrder, from: .inApp))
        })
    }

    /// 外跳发起时的来源（一次读取：会话 / 隐私 / 环境版本 + slot 世代）；没有这个 slot 为 nil。
    func jumpOrigin(_ id: UUID) -> String? {
        guard let slot = slots[id], credentialsReadable() else { return nil }
        return "\(currentOwner().key)#slot\(slot.serial)"
    }

    /// 发起获取方案时的来源与请求归属（同一次 `currentOwner()` 读取；撤回清理未完成时不读凭据，来源为 nil）。之后只比较。
    func jumpSource(_ id: UUID) -> JumpSource {
        let readable = credentialsReadable()
        let owner = currentOwner()
        guard let slot = slots[id], readable else {
            return JumpSource(origin: nil, request: owner.request)
        }
        return JumpSource(origin: "\(owner.key)#slot\(slot.serial)", request: owner.request)
    }

    /// 外跳完成：完成事件携带发起时固定的来源，与持有者此刻的来源比较（只比较）——对不上（旧会话 / 旧环境 / 已换执行器）的迟到事件
    /// 零动作，不改新 slot、不驱动新执行器（iOS RC-06）。对得上：记下平台与来源，发起页回到前台时拉；完成回调晚于回前台（此刻已在前台）
    /// 时立即拉（鸿蒙 H17 同口径）。
    func jumped(_ id: UUID, platform: String, origin: String?, visible: Bool) {
        guard let origin, slots[id] != nil, jumpOrigin(id) == origin else { return }
        slots[id]?.awaiting = (platform, origin)
        if visible {
            slots[id]?.service.refresh(onlyPlatform: platform)
        }
    }

    /// 发起页回到前台（AppTrade：场景在前台且是栈顶）。等待期间来源变了（会话换代、换执行器）的不拉。
    func pageForeground(_ id: UUID) {
        guard let slot = slots[id], let awaiting = slot.awaiting else { return }
        slots[id]?.awaiting = nil
        guard jumpOrigin(id) == awaiting.origin else { return }
        refreshNotificationStatus()
        slot.service.refresh(onlyPlatform: awaiting.platform)
    }

    /// 发起页的待跟单卡执行器（测试核对）。
    func pendingService(_ id: UUID) -> PendingTrackService? {
        slots[id]?.service
    }

    var pendingSlotCount: Int {
        slots.count
    }

    var detailCount: Int {
        details.values.filter { $0.controller != nil }.count
    }
}
