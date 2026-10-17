import Foundation

/// 订单 Tab 根的保存状态（进程回收后恢复子 Tab、分组、平台、月份、搜索词与滚动锚点；APP-06a 第 17、20 条）。绑定账号（账号哈希，
/// 共性第 19 条：恢复前校验，不是同一账号的丢弃）。锚点是视口顶部那张卡的 order_id（稳定标识，共性第 10 条）。
public struct OrderPageRecord: Codable, Equatable, Sendable {
    public var owner: String
    public var conditions: OrderConditions
    public var anchor: String?

    public init(owner: String, conditions: OrderConditions, anchor: String?) {
        self.owner = owner
        self.conditions = conditions
        self.anchor = anchor
    }
}

/// 订单 Tab 根恢复记录的落盘（可能含完整订单号搜索词与锚点订单；APP-08 共性第 36、40 条，iOS R3-01）：
/// - 放在 Application Support 下的单个文件（与断网缓存目录同级、不在其中），原子写；读、写、删都报告成败（抛错 / 返回 false），
///   不再用 UserDefaults（内存更新即时生效、写盘异步，「删后回读为空」不能证明磁盘上的旧记录已删）；
/// - 删除以 `removeItem` 的结果为准（文件本来不存在算成功，其余错误算失败）；失败时调用方保留待清理 / 禁止恢复并重试；
/// - 旧版本留在 UserDefaults（`orders.page_state`）的记录：不迁移内容（一律作废，不用它恢复）；迁移清理（启动时发现旧记录、每次决策与
///   每次清理）删除后**同步写盘并确认**（`synchronize` 报告写盘成功、且回读已不在才算删掉，iOS RC-03）；没确认前调用方保留持久待清理
///   状态（缓存目录之外的标记），之后启动 / 恢复前重试。
@MainActor
public final class OrderPageStateFile {
    public static let fileName = "orders.page_state.json"
    /// 旧版本的 UserDefaults 键（只删不读）。
    public static let legacyKey = "orders.page_state"
    public let url: URL
    private let legacy: UserDefaults?
    /// 写入（测试替换以模拟写盘失败）。
    var writer: (Data, URL) throws -> Void = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    /// 删除（测试替换以模拟删除失败）。
    var remover: (URL) throws -> Void = { url in try FileManager.default.removeItem(at: url) }

    /// 旧 UserDefaults 的写盘确认（返回是否写盘成功；测试替换以模拟写盘失败）。
    var legacySync: (UserDefaults) -> Bool = { $0.synchronize() }

    public init(url: URL, legacyDefaults: UserDefaults? = nil) {
        self.url = url
        legacy = legacyDefaults
    }

    /// 与断网缓存根目录同级的那个文件（缓存目录整体删除时它不受影响，由清理单元单独删除并确认）。
    public static func beside(root: URL, legacyDefaults: UserDefaults? = nil) -> OrderPageStateFile {
        OrderPageStateFile(
            url: root.deletingLastPathComponent().appendingPathComponent(fileName), legacyDefaults: legacyDefaults
        )
    }

    /// 读：没有文件为 nil；读不出（I/O 故障）抛错。
    public func load() throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    /// 原子写；失败抛错。
    public func save(_ data: Data) throws {
        try writer(data, url)
    }

    /// 删除并确认：文件删掉（或本来就没有）且旧 UserDefaults 记录已删才返回 true。
    public func erase() -> Bool {
        var erased = true
        do {
            try remover(url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // 本来就没有
        } catch {
            erased = false
        }
        return eraseLegacy() && erased
    }

    /// 是否还有旧版本的 UserDefaults 记录（只判断在不在，不读内容；启动时据此登记迁移清理）。
    public var hasLegacy: Bool {
        legacy?.object(forKey: Self.legacyKey) != nil
    }

    /// 删旧版本的 UserDefaults 记录（只删不读）并确认写盘：删除后同步写盘，写盘报告成功且回读已不在才返回 true。
    /// 本进程里之前的删除可能还没落盘，所以内存里已不在时也照样同步一次（不能以「内存回读为空」当删除完成，共性第 40 条）。
    @discardableResult
    public func eraseLegacy() -> Bool {
        guard let legacy else { return true }
        if legacy.object(forKey: Self.legacyKey) != nil {
            legacy.removeObject(forKey: Self.legacyKey)
        }
        guard legacySync(legacy) else { return false }
        return legacy.object(forKey: Self.legacyKey) == nil
    }

    /// 文件是否在（测试核对）。
    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

/// 订单 Tab 根的状态保存（APP-08 共性第 19、21、23、36、40 条）：
/// - 首次持久化前先读取并校验恢复记录（`decide`）；决策完成前 `persist` 一律不写盘，冷启动时默认条件 / 空锚点不会覆盖恢复记录；
///   订单 Tab 一直不打开则原记录原样保留到下次；
/// - 记录绑定账号，`decide` 时不是当前账号的丢弃并删除；会话换代 `clear` 删除记录并重新进入「待决策」；
/// - 落盘在 `OrderPageStateFile`（报告成败的原子文件）；任何一次删除没确认成功（会话清理、恢复校验、旧记录迁移）：除内存里的
///   `eraseOutstanding` 外，同时登记进持久清理单元（`unit`，生产为 OrderCacheStore：缓存目录之外的待清理标记，跨重启；不依赖缓存 owner
///   文件在不在，iOS RC-04）。之后不恢复、不写入；启动核验、下一次决策、保存之前先完成清理（同账号重启也一样）。
@MainActor
public final class OrderPageRestorer {
    public let file: OrderPageStateFile
    /// 持久清理单元（nil = 只记在内存，执行层单测用）。
    public let unit: OrderCleanupUnit?
    public private(set) var decided = false
    /// 上一次删除没确认成功：禁止恢复与写入，下一次决策 / 清除时重试。
    public private(set) var eraseOutstanding = false

    /// 恢复记录绑定的分区（FU-IOS-0712，跨端教训 11）：没绑（还没决策、决策时没有账号、会话换代清除之后）/ 决策时登录世代读不出（未知：
    /// 之后一律不写，不用此刻的世代补绑）/ 已知分区键。
    public enum LoginBinding: Equatable, Sendable {
        case unbound
        case unknown
        case known(String)
    }

    public private(set) var binding = LoginBinding.unbound
    /// 分区键算法（账号 + 登录世代 → 键，世代未知为 nil；只按传入的身份算，R1-01）。缺省只按账号哈希；App 接 `OrderCacheStore.partitionKey`。
    public var partitionKey: @MainActor (String?, String?) -> String? = { account, _ in
        account.flatMap { $0.isEmpty ? nil : OrderCacheStore.hash($0) }
    }

    public init(file: OrderPageStateFile, unit: OrderCleanupUnit? = nil) {
        self.file = file
        self.unit = unit
    }

    /// 读取并校验恢复记录（只做一次）：同一账号的返回记录，否则删除并返回 nil。旧 UserDefaults 记录一律作废；
    /// 删不掉（或之前的删除没确认，含持久清理单元里上次没完成的清理）不恢复。`account` / `loginEpoch` 是页面执行器构造时固定的身份。
    public func decide(account: String?, loginEpoch: String?) -> OrderPageRecord? {
        guard !decided else {
            if binding == .unbound {
                binding = bind(account, loginEpoch)
            }
            return nil
        }
        decided = true
        binding = bind(account, loginEpoch)
        // 持久清理单元里还有没完成的清理（上次进程删不掉、旧记录没确认写盘）：先完成，本次一律不恢复
        if let unit, unit.isPendingClear {
            eraseOutstanding = !unit.completePendingClear()
            return nil
        }
        let legacyErased = file.eraseLegacy()
        if eraseOutstanding {
            discard()
            return nil
        }
        guard legacyErased else {
            markOutstanding()
            return nil
        }
        // 登录世代读不出：不读记录（也不删，世代可能只是暂时读不了）
        guard binding != .unknown else { return nil }
        let data: Data?
        do {
            data = try file.load()
        } catch {
            discard()
            return nil
        }
        guard let data else { return nil }
        guard let record = try? JSONDecoder().decode(OrderPageRecord.self, from: data),
              case let .known(key) = binding, record.owner == key
        else {
            discard()
            return nil
        }
        return record
    }

    /// 保存（决策完成后才写；没有会话不写；之前的删除没确认时先重试删除，仍删不掉不写）。写不进只记日志（下次照常保存）。
    /// `account` / `loginEpoch` 是页面执行器构造时固定的身份（随页面带到写入点，不读当前会话补绑，R1-01）。
    public func persist(conditions: OrderConditions, anchor: String?, account: String?, loginEpoch: String?) {
        guard decided, let account else { return }
        if binding == .unbound {
            binding = bind(account, loginEpoch)
        }
        // 写入必须带已知的分区键且与页面固定身份的一致（未知即拒写，FU-IOS-0712）
        guard case let .known(key) = binding, partitionKey(account, loginEpoch) == key else { return }
        if let unit, eraseOutstanding || unit.isPendingClear {
            eraseOutstanding = !unit.completePendingClear()
            guard !eraseOutstanding else { return }
        } else if eraseOutstanding {
            discard()
            guard !eraseOutstanding else { return }
        }
        let record = OrderPageRecord(owner: key, conditions: conditions, anchor: anchor)
        guard let data = try? JSONEncoder().encode(record) else { return }
        do {
            try file.save(data)
        } catch {
            OrderLog.warn("orders: page state not saved")
        }
    }

    /// 读当前记录（测试核对）。
    public var stored: OrderPageRecord? {
        guard let data = try? file.load() else { return nil }
        return try? JSONDecoder().decode(OrderPageRecord.self, from: data)
    }

    /// 会话换代、撤回同意、切换环境：删除记录（可能含上一账号的完整订单号搜索词），新会话的第一次打开重新决策（读到的是空）。
    /// 删除没确认成功：记下，之后不恢复、不写入并重试。返回是否确认删除。
    @discardableResult
    public func clear() -> Bool {
        discard()
        decided = true
        binding = .unbound
        return !eraseOutstanding
    }

    private func bind(_ account: String?, _ loginEpoch: String?) -> LoginBinding {
        guard let account, !account.isEmpty else { return .unbound }
        return partitionKey(account, loginEpoch).map(LoginBinding.known) ?? .unknown
    }

    private func discard() {
        if file.erase() {
            eraseOutstanding = false
        } else {
            markOutstanding()
        }
    }

    /// 删除没确认：内存里禁止恢复与写入，并登记进持久清理单元（跨重启，启动与恢复前先处理）。
    private func markOutstanding() {
        eraseOutstanding = true
        OrderLog.warn("orders: page state not erased")
        if let unit, !unit.markPendingClear() {
            OrderLog.warn("orders: page state pending clear not persisted")
        }
    }
}

/// 一次滚动锚点恢复（共性第 10、17、21、24 条；APP-06a 第 40–43 条：iOS 只做一次性顶对齐，不做卡内偏移细调）：
/// - 绑定恢复开始时的查询轮次；轮次变了（换筛选、搜索、下拉刷新、重试、切子 Tab）即取消恢复（不用旧条件覆盖新条件）；
/// - 恢复进行中冻结普通的锚点记录（保存的仍是恢复目标），完成、取消或放弃后才按实际视口记录；
/// - 目标尚未加载时不丢弃任务：还能翻页就翻页，到底、翻页失败、首屏失败时放弃（回到顶部，compare 写明）；
/// - 目标出现后安排一次对齐（下一轮主循环），执行前复核任务编号与轮次（`confirm`），失效即不滚动、不记录；
///   页面 / 会话 / 环境的有效性由页面配置在回调里另行复核（共性第 35 条）；
/// - 位置基准在列表第一次报告滚动位置时就建立（不等自动补页结束）；之后位置被本任务以外的任何原因改变（触摸、惯性、读屏滚动、
///   键盘 / 辅助功能滚动）即取消，不会在补页结束后把用户拉回旧目标（APP-06a 第 38、41 条，I07）。
@MainActor
public final class OrderAnchorKeeper {
    public private(set) var target: String?
    public private(set) var boundRound: Int?
    public private(set) var taskId = 0
    public internal(set) var aligning = false
    /// 已记录的锚点（视口顶部那张卡；恢复期间不更新）。
    public private(set) var recorded: String?
    /// 挪动次数（测试核对「每个任务至多一次」）。
    public private(set) var moves = 0
    /// 恢复期间的位置基准（列表内容顶边在视口里的纵坐标；第一次报告时建立）。
    public private(set) var baseline: Double?
    /// 最近一次报告的位置（延迟对齐执行前再复核一次，共性第 39 条）。
    public private(set) var lastOffset: Double?
    /// 位置偏离基准多少点以上算「被移动过」（排版取整的误差以内不算）。
    public static let moveTolerance = 1.0
    /// 目标卡之后至少还要加载多少张卡（能翻页时），免得内容太短、目标卡顶不到视口顶部。
    public static let tailCards = 6

    public init() {}

    public var restoring: Bool {
        target != nil
    }

    /// 开始恢复（冷启动决策读到记录时）。轮次在第一次看到列表快照时绑定。
    public func begin(target: String?) {
        guard let target else { return }
        taskId += 1
        self.target = target
        recorded = target
        boundRound = nil
        aligning = false
        baseline = nil
        lastOffset = nil
    }

    /// 列表滚动位置变化（内容顶边在视口里的纵坐标）。恢复进行中：第一次报告建立基准；之后偏离基准即说明被本任务以外的原因移动过
    /// （本任务只在 `confirm` 之后挪动一次，挪动后任务已结束），取消恢复。返回是否因此取消。
    @discardableResult
    public func observe(offset: Double) -> Bool {
        guard target != nil else { return false }
        lastOffset = offset
        guard let baseline else {
            baseline = offset
            return false
        }
        guard abs(offset - baseline) > Self.moveTolerance else { return false }
        cancel()
        return true
    }

    /// 列表快照变化：返回此刻要做的事。
    public enum Step: Equatable {
        case none
        case loadMore
        /// 安排一次对齐（下一轮主循环执行，执行前 `confirm`）。
        case align(id: String, task: Int)
        /// 放弃（回到顶部，按实际视口记录）。
        case giveUp
    }

    public func step(_ snapshot: OrderListSnapshot) -> Step {
        guard let target else { return .none }
        if let boundRound, boundRound != snapshot.query.round {
            cancel()
            return .giveUp
        }
        boundRound = boundRound ?? snapshot.query.round
        guard !aligning else { return .none }
        switch snapshot.phase {
        case .idle, .loading:
            return .none
        case .error where snapshot.identityPending: // 身份暂时未知中止：等同一轮次补取，不放弃（整体重理）
            return .none
        case .error, .empty, .stale:
            cancel()
            return .giveUp
        case .content:
            break
        }
        if let index = snapshot.items.firstIndex(where: { $0.orderId == target }) {
            return stepOnLoadedTarget(target, at: index, snapshot)
        }
        if snapshot.loadingMore || snapshot.refreshing {
            return .none
        }
        if snapshot.canLoadMore {
            return .loadMore
        }
        cancel()
        return .giveUp
    }

    /// 目标已在列表里：目标之后不够一屏且还能翻页时先翻页（翻页在途时等），否则安排一次对齐。
    private func stepOnLoadedTarget(_ target: String, at index: Int, _ snapshot: OrderListSnapshot) -> Step {
        // 目标之后不够撑满一屏（能翻页时）：先翻页，免得目标卡被列表底部截住、顶不到视口顶部（FU-IOS-0712 第 1 轮修复 F-X-19 实走
        // 发现：冷启动只有第一页时目标停在倒数，恢复落到前两张；搜索页同口径，SearchScrollTracker.tailCards）
        if snapshot.loadingMore || snapshot.refreshing {
            return .none
        }
        if snapshot.items.count - 1 - index < Self.tailCards, snapshot.canLoadMore {
            return .loadMore
        }
        aligning = true
        return .align(id: target, task: taskId)
    }

    /// 延迟回调执行前复核（共性第 24、39 条）：任务编号、轮次都还对、且最近报告的位置没偏离基准（用实际滚动偏移判断，不看顶部条目，
    /// 同一卡片内的小幅滚动、惯性、读屏滚动都算）才挪动；挪动后任务结束。位置已偏离即取消。
    public func confirm(task: Int, round: Int) -> Bool {
        guard task == taskId, target != nil, aligning, boundRound == round else { return false }
        if let baseline, let lastOffset, abs(lastOffset - baseline) > Self.moveTolerance {
            cancel()
            return false
        }
        moves += 1
        target = nil
        aligning = false
        return true
    }

    /// 取消（用户拖动、条件变化、页面销毁）：解冻，记录按此后的实际视口。
    public func cancel() {
        taskId += 1
        target = nil
        aligning = false
        baseline = nil
        lastOffset = nil
    }

    /// 视口顶部那张卡变化：恢复进行中不记录（冻结），返回是否记录了。
    @discardableResult
    public func record(top: String?) -> Bool {
        guard target == nil, top != recorded else { return false }
        recorded = top
        return true
    }
}
