import ClientCore
import Config
import Foundation

/// 本机偏好文件的读写端口（生产为 ClientCore 的 `ClientFile`：原子写、删除失败抛错；测试注入写入 / 删除失败）。
/// `read` 返回 nil = 文件不存在；读不了抛错。`write(nil)` = 删除，删不掉抛错，不存在算成功。
public protocol MeLocalFile: Sendable {
    func read() throws -> String?
    func write(_ text: String?) throws
}

extension ClientFile: MeLocalFile {}

/// 本任务新增的设备级本机偏好（G03、G28、G29）：`Application Support/com.couli.app/couli_me_prefs.json`（R1-01 起不再用 UserDefaults 套件，
/// I25），按设备、不按账号。
/// - 通知引导条最近一次关闭的时刻（G28）；
/// - 个性化推荐开关与最近一次切换时刻（G03，缺省打开）。
///
/// 只在撤回同意时随撤回清理名单清空（`MeLocalCleaner`，登记在 `PrivacyWithdrawalCleanup.registry`）；退出、换账号、会话失效、切换环境、回后台都
/// 不清（`MeLocalData`）。
///
/// 删除要确认落盘（R1-01，G29，APP-03a 第 33、38 条，APP-08 第 28、40 条）——不以内存回读当落盘：
/// 1. 先原子写入同目录的作废标记 `couli_me_prefs.pending`（落盘的「待清理」，跨进程有效）；
/// 2. 删除偏好文件，并按文件系统再读一次确认已不存在；
/// 3. 确认之后才删作废标记（同样再读确认）。任一步失败抛错：撤回清理名单据此保留全局待清理标记、下次重试。
/// 作废标记在盘上（或本进程清理失败过）时，读取前先重试删除；删不掉一律按缺省值读（不读回旧数据），写入一律不做。
/// 只在主线程使用；网络层读 `personalizationOffNow`（线程安全，不碰磁盘）。
public final class MeLocalStore: @unchecked Sendable {
    public static let fileName = "couli_me_prefs.json"
    public static let pendingFileName = "couli_me_prefs.pending"
    static let keyGuideClosed = "guide_bar_closed_at"
    static let keyPersonalization = "personalization_on"
    static let keyPersonalizationAt = "personalization_at"

    private let file: any MeLocalFile
    private let pendingMark: any MeLocalFile
    private let lock = NSLock()
    private var offNow: Bool
    /// 本进程里有一次清理没确认完成（作废标记也可能没写进去）：清理确认之前一律按缺省值读、不写。
    private var mustClear = false

    /// 生产：Application Support 下的偏好文件与同目录的作废标记。`baseDirectory` 只给测试。
    public convenience init(baseDirectory: URL? = nil) {
        let file = ClientFile(name: Self.fileName, baseDirectory: baseDirectory)
        self.init(file: file, pending: file.sibling(Self.pendingFileName))
    }

    public init(file: any MeLocalFile, pending: any MeLocalFile) {
        self.file = file
        pendingMark = pending
        offNow = false
        offNow = !personalizationOn
    }

    /// 网络层每个请求读（线程安全，不碰磁盘）：个性化已关闭。
    public var personalizationOffNow: Bool {
        lock.withLock { offNow }
    }

    /// 盘上有作废标记（读不了按「有」处理，保守）。
    private var pendingOnDisk: Bool {
        do {
            return try pendingMark.read() != nil
        } catch {
            return true
        }
    }

    /// 有「待清理」（本进程失败过或盘上有作废标记）时先重试；仍删不掉为 false（按缺省值读、不写）。
    private var readable: Bool {
        guard mustClear || pendingOnDisk else { return true }
        return (try? clearAll()) != nil
    }

    /// 读出全部偏好；文件不存在为空表，读不了 / 坏数据为 nil（按缺省值读、不写，避免覆盖掉别的项）。
    private func load() -> [String: Any]? {
        do {
            guard let text = try file.read() else { return [:] }
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        } catch {
            return nil
        }
    }

    /// 原子写入并读回核对（按文件内容，不按内存）；失败返回 false。
    private func save(_ values: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        do {
            try file.write(text)
            return try file.read() == text
        } catch {
            return false
        }
    }

    private func number(_ key: String) -> Int64? {
        guard readable, let value = load()?[key] as? NSNumber else { return nil }
        return value.int64Value
    }

    public var guideClosedAt: Int64? {
        number(Self.keyGuideClosed)
    }

    /// 记下关闭引导条的时刻；写不进返回 false（本次照样收起，下次按没关过）。
    @discardableResult
    public func markGuideClosed(_ now: Int64) -> Bool {
        guard readable, var all = load() else { return false }
        all[Self.keyGuideClosed] = now
        return save(all)
    }

    /// 个性化推荐开关（缺省打开）。
    public var personalizationOn: Bool {
        guard readable, let value = load()?[Self.keyPersonalization] as? Bool else { return true }
        return value
    }

    public var personalizationChangedAt: Int64? {
        number(Self.keyPersonalizationAt)
    }

    /// 切换个性化（本机先保存，用户意愿优先，brief §2.5）；返回是否落盘。网络头按新值立即生效（落盘失败也生效，本进程内）。
    @discardableResult
    public func setPersonalization(_ on: Bool, now: Int64) -> Bool {
        lock.withLock { offNow = !on }
        guard readable, var all = load() else { return false }
        all[Self.keyPersonalization] = on
        all[Self.keyPersonalizationAt] = now
        return save(all)
    }

    /// 撤回同意：先落盘作废标记 → 删偏好文件并按文件系统确认 → 删作废标记并确认。任一步失败抛错（待清理保留）。内存值立即回到缺省（开）。
    public func clearAll() throws {
        lock.withLock { offNow = false }
        mustClear = true
        // 作废标记先落盘：之后进程中断或删除失败，下次启动（新进程）读之前也会先重试，不读回旧偏好
        try? pendingMark.write("1")
        do {
            try file.write(nil)
            guard try file.read() == nil else { throw MeLocalStoreError.notCleared }
        } catch {
            throw MeLocalStoreError.notCleared
        }
        do {
            try pendingMark.write(nil)
            guard try pendingMark.read() == nil else { throw MeLocalStoreError.pendingNotCleared }
        } catch {
            throw MeLocalStoreError.pendingNotCleared
        }
        mustClear = false
    }

    /// 是否有没完成的清理（测试与诊断）。
    public var clearPending: Bool {
        mustClear || pendingOnDisk
    }
}

public enum MeLocalStoreError: Error, Equatable {
    case notCleared
    case pendingNotCleared
}

/// 撤回清理名单里的一项（G29）：删 `couli_me_prefs.json`（设备级偏好）。只登记进撤回同意的注册表——切换环境不清设备级偏好（G29），所以不进切换环境的
/// 注册表。删不掉抛错：撤回清理不算完成、待清理标记保留，读之前先重试（APP-03b 共性）。
@MainActor
public final class MeLocalCleaner: EnvironmentSwitchCleaning {
    public static let name = "Me.localPrefs"
    public let cleanerName = MeLocalCleaner.name
    public let store: MeLocalStore
    /// 删完（成功或失败都调）：App 同步收起依赖它的界面（引导条、个性化开关）。
    public var onCleared: (@MainActor () -> Void)?

    public init(store: MeLocalStore) {
        self.store = store
    }

    public func cleanForEnvironmentSwitch() throws {
        defer { onCleared?() }
        try store.clearAll()
    }

    public static let shared = MeLocalCleaner(store: MeLocalStore())

    /// 登记进撤回同意的注册表（已登记过就不重复）。在启动对账之前调用。
    public static func register(_ cleaner: MeLocalCleaner = shared, withdrawal: EnvironmentSwitchCleanerRegistry) {
        guard !withdrawal.registeredNames.contains(name) else { return }
        withdrawal.register(cleaner)
    }
}
