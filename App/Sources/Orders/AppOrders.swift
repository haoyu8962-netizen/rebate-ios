import Combine
import Config
import CouliNetwork
import Foundation
import OrderCore
import Orders
import Privacy
import Router
import SwiftUI
import Trade
import UserNotifications

/// 订单页打开的路由名（都在 routes.json 里登记；OrdersWiringTests 逐个核对）。
enum AppOrderRoutes {
    static let orderList = "OrderList"
    static let orderDetail = "OrderDetail"
    static let findOrder = "FindOrder"
    static let productDetail = "ProductDetail"
    static let help = "Help"
    static let ledger = "Ledger"
    static let withdraw = "Withdraw"
    static let appeal = "Appeal"
    static let authManage = "AuthManage"
    static let home = "Home"
    static let all = [
        orderList,
        orderDetail,
        findOrder,
        productDetail,
        help,
        ledger,
        withdraw,
        appeal,
        authManage,
        home,
    ]
}

/// App 侧的订单（APP-08）：订单列表、订单详情、待跟单卡（订单列表自购子 Tab 顶部、商品详情 / 搜索页外跳回前台后）。
/// - 会话（登录、退出、换账号、会话失效、撤回同意、切换环境）换代时同步：共享禁用期与关闭记录重置；列表执行器整份换新（清空搜索框、筛选、
///   锚点、半屏，共性第 19 条）；栈里的详情先清空快照再移出导航栈（共性第 1 条，鸿蒙 H18 同口径）；恢复记录删除；缓存按归属清理；
/// - 撤回同意 / 切换环境（OrderCacheCleaner 回调，共性第 36、38、43 条）：除上面各项外，商品详情 / 搜索页已显示的待跟单卡清空、旧执行器作废，
///   仍在栈里的页面换上新环境的执行器（再次外跳回来照常出卡）；
/// - 订单 Tab 被切走再切回（Tab 外壳重建视图）：以切走前记录的锚点做一次顶对齐，首次排版不覆盖旧锚点（共性第 37 条，OrderListPageConfig）；
/// - 详情页出栈的同步出口作废请求（WebRouteLifetimes：只看 Router 栈）；被详情盖住的列表保留筛选、搜索词与滚动位置；
/// - 订单号复制只经剪贴板的统一写入口（AppClipboard.writer）；
/// - 断网缓存按账号隔离，登记进撤回同意与切换环境的清理名单（OrderCacheCleaner）。
@MainActor
final class AppOrders: ObservableObject, OrderListEnv, PendingTrackEnv {
    /// 会话换代时加一（订单 Tab 根视图据此重建）。
    @Published private(set) var sessionEpoch = 0

    let hub: OrderSessionHub
    let cache: OrderCacheStore
    let mask: AmountMaskStore
    let restorer: OrderPageRestorer
    let texts = OrderDraftTexts()
    let lifetimes: WebRouteLifetimes
    let api: OrderApi
    let client: ApiClient
    let router: Router
    private let config: AppConfig
    private(set) var listConfig: OrderListPageConfig?
    private var sessionKey: String
    var details: [UUID: WeakDetail] = [:]
    var slots: [UUID: PendingSlot] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    /// 撤回同意 / 切换环境删掉订单缓存的次数（有效性票据的一部分）。
    private(set) var clearedCount = 0
    /// 剪贴板的统一写入口（APP-07）；nil = 没接（复制提示失败，不写剪贴板）。
    weak var clipboard: AppClipboard?
    /// 统一权限入口（APP-03b）。
    weak var permissions: AppPermissions?
    /// 统一客服出口（APP-12 AppMe.cs；详情【联系客服】）。
    var customerService: (@MainActor (String) -> Void)?
    /// 当前时刻：服务端校准后的时钟（BR-TEXT-11，共性第 34 条；ApiClient 按响应头 Date 校出的偏移）。订单相对时间、缓存时间提示、
    /// 缓存获取时刻都用它（测试注入）。
    lazy var clock: () -> Int64 = { [client] in client.calibratedNowMillis }

    struct WeakDetail {
        weak var controller: OrderDetailController?
    }

    /// 发起页的待跟单位置：`serial` 是 slot 世代（换执行器即换新）；`awaiting` 是已完成外跳、等回前台拉卡的平台与发起时固定的来源。
    struct PendingSlot {
        var service: PendingTrackService
        let host: PendingTrackSlotHost
        var serial: Int
        var awaiting: (platform: String, origin: String)?
    }

    var slotSerial = 0
    /// 撤回同意的清理已完成、会话凭据可读（生产为 `PrivacyWithdrawalCleanup.runner`；测试注入）。只读内存标记，不读凭据。
    let credentialsReadable: @MainActor () -> Bool

    init(
        network: AppNetwork, config: AppConfig, routing: AppRouting, login: AppLogin,
        cleaner: OrderCacheCleaner = .shared, defaults: UserDefaults = .standard,
        credentialsReadable: @escaping @MainActor () -> Bool = { PrivacyWithdrawalCleanup.runner.credentialsReadable }
    ) {
        self.credentialsReadable = credentialsReadable
        client = network.client
        api = network.client
        router = routing.router
        self.config = config
        cache = cleaner.store
        hub = OrderSessionHub(defaults: defaults)
        mask = AmountMaskStore(defaults: defaults)
        // 恢复记录的删除失败登记进持久清理单元（缓存目录之外的标记，跨重启；iOS RC-04）
        restorer = OrderPageRestorer(file: cleaner.store.pageState, unit: cleaner.store)
        lifetimes = WebRouteLifetimes(router: routing.router)
        sessionKey = ""
        sessionKey = currentSessionKey()
        // 启动时：旧版本 UserDefaults 恢复记录的迁移清理（删后同步写盘确认，没确认保留持久待清理，iOS RC-03）；再核验缓存目录之外的
        // 待清理状态与归属（共性第 28 条）：上次没清完的先清完，别的账号的缓存删掉
        cache.migrateLegacyPageState()
        cache.reconcileOwner(account: account)
        login.$sessionVersion.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSession() }
        }.store(in: &subscriptions)
        cleaner.onCleared = { [weak self] in self?.cacheCleared() }
        refreshNotificationStatus()
    }

    // MARK: - 环境

    /// 当前会话账号（经会话隔离判断；撤回清理未完成时不读）。只给 `currentOwner`（一次读取）、会话换代检测与缓存归属对账（只删不绑定）用；
    /// 执行器的数据、票据、缓存读写与恢复记录保存一律用执行器构造时固定的身份（APP-09 共性第 65 条）。
    private var account: String? {
        guard credentialsReadable() else { return nil }
        return client.isolatedAccount
    }

    func now() -> Int64 {
        clock()
    }

    /// 此刻的身份（一次读取：账号、会话世代、网络作废世代、订单清理次数、是否登录）。只在执行器构造时（或会话换代通知里随清空重建时）调用。
    /// 账号、会话世代与环境票据在网络层同一把锁里一次读出（`currentOwnership(credentialsReadable:)`），并原样作为订单请求的网络归属（iOS RC-01）。
    /// 凭据可读性先读（内存标记），再按它取受约束的原子快照：撤回清理未完成时只读内存里的会话世代与作废世代，不调用令牌存储（iOS NEW-01）。
    func currentOwner() -> OrderOwner {
        let readable = credentialsReadable()
        let network = client.currentOwnership(credentialsReadable: readable)
        let account = network.account
        let key = "\(account ?? "-")#\(network.generation)#\(network.epoch)#\(clearedCount)"
        return OrderOwner(
            account: account, key: readable ? key : key + "#withdrawing",
            member: readable && client.isolatedSessionScope != nil,
            request: RequestOwnership(account: account, generation: network.generation, epoch: network.epoch)
        )
    }

    /// 固定身份仍是当前会话（只比较；撤回清理进行中一律不是）。
    func isCurrent(_ owner: OrderOwner) -> Bool {
        credentialsReadable() && currentOwner() == owner
    }

    /// iOS 系统已拒绝（系统不会再弹框）即视为申请过（I03）。
    var requestedBefore: Bool {
        hub.notification == PendingTrackRaw.denied
    }

    /// 系统通知申请（默认经统一权限入口；测试替换）。`isValid` 交给 PermissionRequester，在每次等待结束、弹系统框前复核。
    lazy var pushRequest: AppPushRequest = { [weak self] isValid in
        _ = await self?.permissions?.request("push", purposeShown: true, isValid: {
            MainActor.assumeIsolated { isValid() }
        })
    }

    /// 读系统通知状态（只读，不申请）：.notDetermined → not_determined；.denied → denied；已授权 → granted。
    func refreshNotificationStatus() {
        Task { @MainActor [weak self] in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            self?.hub.notification = Self.notificationRaw(settings.authorizationStatus)
        }
    }

    nonisolated static func notificationRaw(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: PendingTrackRaw.notDetermined
        case .denied: PendingTrackRaw.denied
        default: PendingTrackRaw.granted
        }
    }

    // MARK: - 会话

    func currentSessionKey() -> String {
        "\(account ?? "-")#\(client.sessionGeneration)"
    }

    /// 会话可能变了（AppLogin 的会话版本变化、页面打开时）：账号或会话世代不同即换代。
    func checkSession() {
        let key = currentSessionKey()
        guard key != sessionKey else { return }
        sessionKey = key
        sessionChanged()
    }

    private func sessionChanged() {
        clearDisplays()
        cache.reconcileOwner(account: account)
        sessionEpoch += 1
    }

    /// 撤回同意 / 切换环境（OrderCacheCleaner 删了缓存与恢复记录，删除失败时同样回调）：内存里的订单显示全部作废（共性第 36、38 条）——
    /// 列表执行器与恢复记录、栈里的详情、商品详情 / 搜索页已显示的待跟单卡（清空并作废旧执行器，旧执行器之后不再拉卡）。
    private func cacheCleared() {
        clearedCount += 1
        clearDisplays()
        // 旧执行器同步清空并作废；仍在栈里的商品详情 / 搜索页换上新环境的执行器（同一持有者），之后再次外跳回来照常出卡（共性第 43 条）
        for (id, slot) in slots {
            slot.service.discard()
            let fresh = PendingTrackService(api: api, hub: hub, env: self)
            // 新 slot 世代：之前发起的外跳迟到的完成事件对不上，不驱动新执行器（iOS RC-06）
            slotSerial += 1
            slots[id] = PendingSlot(service: fresh, host: slot.host, serial: slotSerial, awaiting: nil)
            slot.host.replace(with: fresh)
        }
        sessionEpoch += 1
    }

    /// 各订单显示位置的同步出口（会话换代、撤回同意、切换环境共用）。
    private func clearDisplays() {
        // 共享禁用期、关闭记录重置；各位置的待跟单卡（订单列表、商品详情、搜索页）随 hub 换代同步清空、作废在途
        hub.sessionChanged()
        // 旧列表页的同步出口：先取消待执行的恢复对齐、冻结记录（共性第 35 条），再作废执行器
        listConfig?.invalidate()
        listConfig?.controller.leave()
        listConfig?.pendingTrack?.discard()
        listConfig = nil
        // 恢复记录（可能含完整订单号搜索词）删除；之后的保存只认新的一份
        restorer.clear()
        // 栈里的旧详情：先同步清空快照（不再显示旧账号 / 旧环境的订单号与金额），再移出导航栈
        for entry in details.values {
            entry.controller?.sessionChanged()
        }
        if router.path.contains(where: { $0.route == AppOrderRoutes.orderDetail }) {
            router.path.removeAll { $0.route == AppOrderRoutes.orderDetail }
        }
    }

    /// 回前台：刷新系统通知状态（通知行按新状态重算）。
    func sceneBecameActive() {
        refreshNotificationStatus()
        checkSession()
    }

    /// 进后台：先核对会话（换代了就先清空、换掉旧页面），再保存一次订单 Tab 的恢复记录（只认仍有效的页面，iOS RC-02）。
    func sceneEnteredBackground() {
        checkSession()
        persist()
    }

    // MARK: - 订单列表

    /// 订单 Tab 根的页面配置（一个会话一份；被详情盖住、切到别的 Tab 都保留）。路由参数 scope=share 时切到分享子 Tab。
    func listPage(_ destination: RouteDestination) -> OrderListPageConfig {
        checkSession()
        let page = listConfig ?? makeListPage()
        page.controller.openScope(destination.params["scope"]?.stringValue)
        return page
    }

    private func makeListPage() -> OrderListPageConfig {
        // 执行器构造时一次性取得固定身份（APP-09 共性第 65 条）；恢复记录的校验用同一份（恢复数据与页面身份来自同一次读取）
        let controller = OrderListController(api: api, gate: hub.gate, env: self, cache: cache)
        let pending = PendingTrackService(api: api, hub: hub, env: self)
        let page = OrderListPageConfig(controller: controller, texts: texts, mask: mask, pendingTrack: pending)
        page.now = { [weak self] in self?.clock() ?? 0 }
        // 首次持久化前先读取并校验恢复记录（共性第 23 条）：同一账号的才恢复子 Tab、分组、平台、月份、搜索词与锚点
        // 持久清理单元还在「待清理」（撤回 / 切环境 / 恢复记录删除没确认）：决策时先完成清理、本次不恢复（共性第 36 条，iOS RC-04）
        if let record = restorer.decide(account: controller.owner.account) {
            controller.restore(record.conditions)
            page.anchor.begin(target: record.anchor)
        }
        let router = router
        page.onOpenDetail = { orderId in
            router.open(RouteRequest(
                route: AppOrderRoutes.orderDetail, values: ["order_id": .string(orderId)], from: .inApp
            ))
        }
        page.onFindOrder = { router.open(RouteRequest(route: AppOrderRoutes.findOrder, from: .inApp)) }
        page.onHome = { router.open(RouteRequest(route: AppOrderRoutes.home, from: .inApp)) }
        page.copy = { [weak self] text in self?.writeClipboard(text) ?? false }
        // 持久化与延迟回调只认当前这一份、且执行器的固定身份仍是当前会话（共性第 35 条；APP-06a 第 39 条；固定身份另由 page.live 核对）
        page.isCurrent = { [weak self, weak page] in
            guard let self, let page else { return false }
            return listConfig === page && isCurrent(page.controller.owner)
        }
        page.onStateChange = { [weak self, weak page] in
            guard let self, let page, page.isCurrent() else { return }
            persist()
        }
        listConfig = page
        return page
    }

    /// 保存恢复记录（所有保存入口：条件 / 锚点变化、进后台）：只认仍有效的页面（仍是当前这一份、没失效、固定身份仍是当前会话），写入账号
    /// 只取页面执行器的固定身份，不读当前会话（iOS RC-02）；决策完成后才写，恢复进行中保存的仍是恢复目标。
    func persist() {
        guard let page = listConfig, !page.invalidated, !page.controller.isLeft, page.isCurrent(),
              !cache.isPendingClear
        else { return }
        restorer.persist(
            conditions: page.controller.snapshot.query.conditions, anchor: page.anchor.recorded,
            account: page.controller.owner.account
        )
    }

    private func writeClipboard(_ text: String) -> Bool {
        clipboard?.writer.write(text) ?? false
    }

    // MARK: - 订单详情

    func detailPage(_ destination: RouteDestination) -> OrderDetailPageConfig {
        checkSession()
        let orderId = destination.params["order_id"]?.stringValue ?? ""
        let controller = OrderDetailController(api: api, orderId: orderId, gate: hub.gate, env: self, cache: cache)
        controller.copy = { [weak self] text in self?.writeClipboard(text) ?? false }
        // 返回列表时只替换那一行（G17）：只替换同一固定身份的列表
        let owner = controller.owner
        controller.onLoaded = { [weak self] detail in
            guard let list = self?.listConfig?.controller, list.owner == owner else { return }
            list.replaceRow(with: detail)
        }
        details[destination.id] = WeakDetail(controller: controller)
        let id = destination.id
        lifetimes.register(destination) { [weak self, weak controller] in
            controller?.leave()
            self?.details[id] = nil
        }
        let page = OrderDetailPageConfig(controller: controller, texts: texts, mask: mask)
        page.now = { [weak self] in self?.clock() ?? 0 }
        let router = router
        page.onBack = { router.close(destination) }
        page.onOpen = { target in
            router.open(RouteRequest(
                route: target.route,
                values: target.params.mapValues { .string($0) },
                from: .inApp
            ))
        }
        page.helpLinks = { [weak self] in self?.helpLinks() }
        // APP-12：详情【联系客服】（CONTACT_CS）改走统一客服出口；没接时仍打开帮助中心（onOpen 的 Help，接入前一致）
        page.onContactService = { [weak self] in
            guard let customerService = self?.customerService else { return false }
            customerService("OrderDetail")
            return true
        }
        return page
    }

    /// /v1/config.help_links（生效配置）。
    func helpLinks() -> [String: Any]? {
        guard let text = config.store.value(key: "help_links"), let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// 系统通知申请（`isValid`：点击时捕获的有效性，等待结束后、弹系统框前复核）。
typealias AppPushRequest = @MainActor (_ isValid: @escaping @MainActor () -> Bool) async -> Void
