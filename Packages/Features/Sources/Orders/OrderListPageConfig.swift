import CouliNetwork
import OrderCore
import SwiftUI

/// 订单列表页的配置（App 给）：执行器、文案、跳转出口与恢复。一个会话一份（会话换代时 App 换一份新的）。
@MainActor
public final class OrderListPageConfig: ObservableObject {
    public let controller: OrderListController
    public let texts: OrderTexts
    public let mask: AmountMaskStore
    /// 自购子 Tab 顶部的待跟单卡（G07 ①，显示全部未关闭的卡）；nil = 不显示。
    public let pendingTrack: PendingTrackService?
    /// 滚动锚点（进程回收恢复的一次性顶对齐与视口顶部记录）。
    public let anchor: OrderAnchorKeeper
    /// 打开详情（经 Router：OrderDetail {order_id}）。
    public var onOpenDetail: (_ orderId: String) -> Void = { _ in }
    /// 「未跟单？去找回」（经 Router：FindOrder）。
    public var onFindOrder: () -> Void = {}
    /// 空态【去首页逛逛】（经 Router：Home）。
    public var onHome: () -> Void = {}
    /// 自购单【复制】：经统一写入口写入 order_no 原文；返回 false = 记 hash 失败没写（不提示成功）。
    public var copy: (_ orderNo: String) -> Bool = { _ in false }
    /// 条件或视口顶部那张卡变化（App 持久化恢复记录）。
    public var onStateChange: () -> Void = {}
    /// 当前时刻（毫秒；列表时间、月份选项、缓存提示条用；App 给服务端校准后的时钟，测试注入）。
    public var now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    /// 页面仍有效（App 给：仍是当前会话的那一份，会话 / 隐私 / 环境版本没变）。延迟回调执行前复核（共性第 24、35 条）。
    public var isCurrent: () -> Bool = { true }
    /// 页面身份核对的三态（App 给：仍是当前这一份 + 执行器固定身份一次读取的核对；FU-IOS-0712 整体重理——恢复任务只在页面确定作废时
    /// 取消，身份暂时未知时等待）。nil = 按执行器固定身份核对并合上 `isCurrent`。
    public var identityCheck: (() -> IdentityCheck)?
    /// 放到下一轮主循环执行（默认 DispatchQueue.main.async；测试替换以在回调前插入会话换代、用户滚动等）。
    public var nextLoop: (@escaping @MainActor () -> Void) -> Void = { work in
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    /// 已失效（会话 / 环境 / 页面失效的同步出口 `invalidate` 之后）：不再滚动、不再记录。
    public private(set) var invalidated = false

    /// 半屏筛选（平台 / 月份）。
    @Published public var sheet: OrderFilterSheet?
    /// 复制等页顶轻提示。
    @Published public var toastKey: OrderToast?
    private var toastSeq = 0

    public init(
        controller: OrderListController, texts: OrderTexts, mask: AmountMaskStore, pendingTrack: PendingTrackService?,
        anchor: OrderAnchorKeeper = OrderAnchorKeeper()
    ) {
        self.controller = controller
        self.texts = texts
        self.mask = mask
        self.pendingTrack = pendingTrack
        self.anchor = anchor
    }

    /// 进程恢复的一次性顶对齐（共性第 10、17、21、24、35 条）：目标未加载时翻页等待；对齐放到下一轮主循环，执行前复核页面有效、
    /// 会话与环境版本（`isCurrent`）、查询轮次与任务编号；任一失效即取消恢复，不滚动、不记录。
    public func restoreStep(scroll: @escaping @MainActor (_ orderId: String) -> Void) {
        let check = pageCheck()
        guard check != .stale else {
            anchor.cancel()
            return
        }
        guard check == .current else {
            // 身份暂时未知：不滚动、不放弃，身份确认后由执行器的统一补做再走一次（FU-IOS-0712 整体重理）
            holdRestore(scroll)
            return
        }
        switch anchor.step(controller.snapshot) {
        case .none, .giveUp:
            break
        case .loadMore:
            controller.loadMore()
        case let .align(id, task):
            nextLoop { [weak self] in
                guard let self, alignStillValid(task, scroll: scroll) else { return }
                scroll(id)
            }
        }
    }

    /// 延迟对齐执行前的复核。页面已失效时同时取消恢复任务；身份暂时未知时这次不挪动、不取消，身份确认后重新安排。
    func alignStillValid(_ task: Int, scroll: @escaping @MainActor (_ orderId: String) -> Void) -> Bool {
        let check = pageCheck()
        guard check != .stale else {
            anchor.cancel()
            return false
        }
        guard check == .current else {
            if task == anchor.taskId, anchor.aligning {
                anchor.deferAlign()
            }
            holdRestore(scroll)
            return false
        }
        return anchor.confirm(task: task, round: controller.snapshot.query.round)
    }

    /// 恢复任务因身份暂时未知暂停：登记进执行器的待补做（与读取补取同一套，App 在身份确认时统一补做）。
    private func holdRestore(_ scroll: @escaping @MainActor (_ orderId: String) -> Void) {
        guard anchor.restoring else { return }
        controller.deferral.hold(OrderListController.anchorSlot) { [weak self] in
            self?.restoreStep(scroll: scroll)
        }
    }

    /// 页面与固定身份的核对（一次读取）：页面已失效 / 执行器已离开 / App 已换掉这一份 → 已作废；否则按执行器固定身份核对。
    func pageCheck() -> IdentityCheck {
        guard !invalidated, !controller.isLeft else { return .stale }
        if let identityCheck {
            return identityCheck()
        }
        let check = controller.ownerCheck
        return check == .current && !isCurrent() ? .stale : check
    }

    /// 列表滚动位置变化（内容顶边在视口里的纵坐标）：恢复进行中被本任务以外的原因移动即取消（APP-06a 第 38、41 条）。身份暂时未知时
    /// 照样观察（用户滚动仍要取消恢复）。
    public func scrolled(offset: Double) {
        guard pageCheck() != .stale else { return }
        anchor.observe(offset: offset)
    }

    /// 视口顶部那张卡变化：恢复进行中冻结；页面失效后不再记录。返回是否记录了（记录了才持久化）。
    public func recordTop(_ top: String?) -> Bool {
        guard live else { return false }
        return anchor.record(top: top)
    }

    /// 挂载过的视图实例个数（每个 OrdersScreen 实例只算一次）。
    public private(set) var mounts = 0

    /// 列表视图是不是本进程第一次挂上（冷启动恢复）；Tab 切回重建时为假。恢复后的补对齐只用于冷启动恢复（FU-IOS-NATIVE-TABBAR r5）。
    public var firstMount: Bool {
        mounts <= 1
    }

    /// 一个新的列表视图实例挂上这份配置（OrdersScreen 的 StateObject 初始化时调用，早于它的第一次排版与位置报告）。
    /// 第二次起（主 Tab 切走再切回：Tab 外壳重建了视图、ScrollView 回到顶部；执行器、条件与已加载的列表都保留）：以切走前记录的锚点
    /// 开始一次一次性顶对齐（共性第 37 条）。恢复进行中冻结记录，新视图首次排版报告的「顶部那张卡」不会覆盖旧锚点；对齐复用进程恢复的
    /// 同一套判定与复核（轮次、任务编号、页面有效、用户滚动即取消）。被详情盖住、前后台切换不重建视图，不走这里。
    public func viewMounted() {
        mounts += 1
        guard mounts > 1, pageCheck() != .stale, !anchor.restoring else { return }
        anchor.begin(target: anchor.recorded)
    }

    /// 页面失效的同步出口（会话换代、撤回同意、切换环境；App 在换掉这一份时调用）：取消恢复任务、冻结记录（共性第 35 条）。
    public func invalidate() {
        invalidated = true
        anchor.cancel()
    }

    /// 页面有效：没失效、执行器没离开、执行器的固定身份仍是当前会话（只比较）、App 侧仍是当前这一份。
    var live: Bool {
        !invalidated && !controller.isLeft && controller.ownerCurrent && isCurrent()
    }

    /// 渲染这张卡时取出【复制】票据（共性第 41 条，iOS R3-02 / RC-01）：页面、执行器的固定身份（构造时取得，不是此刻的会话）、查询轮次
    /// 与子 Tab、订单号都在此刻固定。分享单（脱敏）、坏数据、页面已失效（含会话通知还没处理时重画旧页面）返回 nil（没有复制路径）。
    public func copyTicket(_ item: OrderSummary) -> OrderCopyTicket? {
        guard live else { return nil }
        let number = OrderNumberDisplay.view(item)
        guard number.copyable, let text = number.text else { return nil }
        let query = controller.snapshot.query
        return OrderCopyTicket(
            page: ObjectIdentifier(self), owner: controller.owner, round: query.round, scope: query.scope,
            orderId: item.orderId, orderNo: text
        )
    }

    /// 自购单【复制】：执行前核对渲染时的票据——仍是这一页且页面有效（`live`）、票据身份就是执行器的固定身份且仍是当前会话、查询轮次与子 Tab 没变、
    /// 当前列表里这张卡仍可复制且单号一致、按钮上的单号就是票据里的单号；任一不符零写入、不提示。通过后经统一写入口（ClipboardWriter）。
    public func copyOrderNo(_ ticket: OrderCopyTicket?, rendered: String) {
        guard let ticket, copyStillValid(ticket), ticket.orderNo == rendered else { return }
        toastSeq += 1
        let ok = copy(ticket.orderNo)
        toastKey = OrderToast(key: ok ? "order_detail.copy.done" : "order_detail.copy.failed", error: nil, id: toastSeq)
    }

    func copyStillValid(_ ticket: OrderCopyTicket) -> Bool {
        guard ticket.page == ObjectIdentifier(self), live, ticket.owner == controller.owner else { return false }
        let snapshot = controller.snapshot
        guard snapshot.query.round == ticket.round, snapshot.query.scope == ticket.scope,
              let current = snapshot.items.first(where: { $0.orderId == ticket.orderId })
        else { return false }
        let number = OrderNumberDisplay.view(current)
        return number.copyable && number.text == ticket.orderNo
    }
}

/// 列表卡【复制】的渲染时票据（共性第 41 条）：不可变值，回调只用它，不在执行时重新绑定当前页面或会话。
public struct OrderCopyTicket: Equatable, Sendable {
    let page: ObjectIdentifier
    let owner: OrderOwner
    let round: Int
    let scope: String
    public let orderId: String
    public let orderNo: String
}

/// 半屏筛选。
public enum OrderFilterSheet: String, Sendable {
    case platform
    case month
}
