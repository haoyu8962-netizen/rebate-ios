import Combine
import CouliNetwork
import Foundation
import WalletCore

/// 设置页的页内状态：子页（修改昵称、通知设置）、半屏（一次性编号）、确认框（一次性编号，R1-02）、轻提示、缓存大小。
public struct SettingsState: Equatable, Sendable {
    public enum Sub: Equatable, Sendable {
        case none, nickname, notify
    }

    public static let clearDialog = "clear"
    public static let logoutDialog = "logout"

    public var sub: Sub = .none
    public var sheet: Int?
    public var dialog: MeDialog?
    public var toast: MeNotice?
    public var cacheBytes: Int64?
    public var busy = false
    public var clearing = false
    public var version = 0
}

/// 设置页执行器（Settings 路由；brief §2.3，G01、G02、G07、G30、G32；BR-ID-02）。构造时固定身份（共性第 18 条：身份变了 App 重建本执行器，子页随之
/// 关闭、输入清空）；行、子页、半屏、确认框的回调都捕获渲染时的执行器与版本，执行时核对身份与版本（鸿蒙 R2-02 / H22）：
/// - 条目只按 `SettingsItems`（基本模式五项、游客五项、已登录三组；iOS 没有剪贴板开关）；
/// - 修改昵称、通知设置是页内子页（不注册路由，G32），子页执行器只按已登录身份建；
/// - 「重新显示下单须知」调 resetTip jump_tip（42901 执行层 + 页面）；清除缓存先确认；【退出登录】先确认，确认才调已有 logout()。
@MainActor
public final class SettingsController: ObservableObject, MeReader {
    public static let resetTipOperation = "resetTip"
    public static let jumpTip = "jump_tip"
    public static let savedKey = "nickname.saved"
    public static let clearedKey = "settings.clear_cache.done"
    public static let resetDoneKey = "settings.reset_tip.done"
    public static let deleteAccount = "DeleteAccount"
    public static let login = "Login"

    public let identity: MeIdentity
    public let deps: MeDeps
    public let page: UUID?
    @Published public private(set) var state = SettingsState()
    /// 子页执行器（只在已登录身份下建；身份变了整页重建，旧子页随旧执行器作废）。
    @Published public private(set) var nickname: NicknameController?
    @Published public private(set) var notify: NotifySettingsController?
    /// 共享读取闸门（getMe）与「重新显示下单须知」闸门的禁用状态（R1-06，共性第 32 条）：显式订阅两个 `RetryAfterGate.blocked`，禁用期开始与
    /// 结束都经本执行器发布、驱动页面重绘（【重试】与「重新显示下单须知」行置灰 / 恢复）；执行层照旧另行核对。离开时取消订阅。
    @Published public private(set) var readBlocked = false
    @Published public private(set) var resetTipBlocked = false
    private var gateWatch: Set<AnyCancellable> = []
    private var left = false
    private var ids = 0
    private var dialogIds = 0
    /// 缓存大小读取的世代：清除缓存开始与完成时推进，之前发起的大小读取晚到不把旧大小写回（共性第 29 条同类）。
    private var cacheSeq = 0

    public init(deps: MeDeps, identity: MeIdentity, page: UUID?) {
        self.deps = deps
        self.identity = identity
        self.page = page
        watchGates()
    }

    public var alive: Bool {
        !left && deps.env.isCurrent(identity)
    }

    /// 本页发起的 Me 读取仍有效（R1-03）：出栈、换代即停。
    public var reading: Bool {
        alive
    }

    /// 渲染时的条目（只按本执行器固定的身份档）。
    public func model() -> SettingsModel {
        let me = deps.repo.me(of: identity)
        return SettingsItems.model(
            level: identity.level, platform: MePlatform.ios, phoneBound: me?.phoneBound,
            nicknameEditable: deps.nickname != nil && me != nil, serviceSwitchAvailable: deps.notify != nil,
            deleteAccountAvailable: deps.env.availableRoutes().contains(Self.deleteAccount)
        )
    }

    /// 进入、回到本页：已登录时取 Me（昵称、手机号行）；重算缓存大小。
    public func refresh() {
        guard alive else { return }
        if identity.member {
            deps.repo.refresh(identity, page: self)
        }
        cacheSeq += 1
        let mine = cacheSeq
        Task { @MainActor [weak self] in
            guard let self else { return }
            let bytes = await deps.env.cacheBytes()
            guard alive, cacheSeq == mine else { return }
            state.cacheBytes = bytes
        }
    }

    /// 账号资料加载失败的【重试】：受读取闸门控制（禁用期内执行层与页面都拦）。
    public func retryMe() {
        guard alive, identity.member else { return }
        deps.repo.refresh(identity, page: self)
    }

    private func bound(_ version: Int) -> Bool {
        alive && state.version == version && !deps.withdraw.busy
    }

    /// 一行被点（渲染时的行与版本）：每个分支前核对身份与页面世代（鸿蒙 R2-02）。
    public func onRow(_ row: SettingsRow, version: Int) {
        guard bound(version), !state.busy, model().groups.flatMap(\.rows).contains(row) else { return }
        switch row.id {
        case SettingsItems.idNickname:
            guard row.clickable, identity.member, let backend = deps.nickname,
                  let current = deps.repo.me(of: identity)?.nickname
            else { return }
            nickname = NicknameController(
                deps: deps,
                identity: identity,
                current: current,
                backend: backend,
                host: self
            )
            state.sub = .nickname
            state.version += 1
        case SettingsItems.idNotify:
            guard identity.member else { return }
            let controller = NotifySettingsController(deps: deps, identity: identity)
            notify = controller
            state.sub = .notify
            state.version += 1
            controller.load()
        case SettingsItems.idAgreement:
            dialogIds += 1
            state.sheet = dialogIds
        case SettingsItems.idResetTip:
            resetTip()
        case SettingsItems.idClearCache:
            dialogIds += 1
            state.dialog = MeDialog(kind: SettingsState.clearDialog, id: dialogIds)
        default:
            guard let route = row.route, row.clickable else { return }
            deps.env.open(route, params: [:], from: page)
        }
    }

    /// 协议半屏的一个按钮（G32：半屏两个按钮 → Agreement {type}）：只认正显示的这一个半屏（编号），用过即作废。
    public func openAgreement(_ choice: SettingsChoice, version: Int, sheet: Int) {
        guard state.sheet == sheet else { return }
        state.sheet = nil
        guard bound(version) else { return }
        deps.env.open(choice.route, params: ["type": choice.type], from: page)
    }

    /// 关闭半屏（同一编号才生效）。
    public func closeSheet(_ sheet: Int) {
        if state.sheet == sheet {
            state.sheet = nil
        }
    }

    /// 取消确认框（【取消】；同一编号才生效）。
    public func closeDialog(_ dialog: MeDialog) {
        if state.dialog == dialog {
            state.dialog = nil
        }
    }

    /// 消费一次确认（R1-02）：类型与编号都是正显示的这一个才放行，并立即作废。
    private func consume(_ dialog: MeDialog, kind: String) -> Bool {
        guard dialog.kind == kind, state.dialog == dialog else { return false }
        state.dialog = nil
        return true
    }

    /// 关掉子页（只关发起的这一个，H13）；子页的输入与读请求随执行器作废。
    public func closeSub() {
        nickname?.leave()
        notify?.leave()
        nickname = nil
        notify = nil
        state.sub = .none
        state.version += 1
        refresh()
    }

    /// 只关指定的那个子页（旧子页的回调不关新子页）。
    public func close(nickname sub: NicknameController) {
        guard sub === nickname else { return }
        closeSub()
    }

    public func close(notify sub: NotifySettingsController) {
        guard sub === notify else { return }
        closeSub()
    }

    /// 昵称保存成功：轻提示「昵称已修改」，只关发起的这个子页（APP-09 第 50 条）。
    func nicknameSaved(_ sub: NicknameController) {
        guard sub === nickname, alive else { return }
        nickname?.leave()
        nickname = nil
        state.sub = .none
        state.version += 1
        toast(MeNotice(Self.savedKey, id: nextId(), assertive: false))
    }

    /// 底部【去登录】（游客）。
    public func openLogin(version: Int) {
        guard bound(version), identity.level == MeLevel.guest else { return }
        deps.env.open(Self.login, params: [:], from: page)
    }

    /// 底部【开启完整功能】（基本模式）。
    public func enableFull(version: Int) {
        guard bound(version), identity.level == MeLevel.basic else { return }
        deps.env.requestFullFunction()
    }

    public func askLogout(version: Int) {
        guard bound(version), identity.member, !state.busy else { return }
        dialogIds += 1
        state.dialog = MeDialog(kind: SettingsState.logoutDialog, id: dialogIds)
    }

    /// 【退出登录】确认（确认框生成时的编号与渲染时的版本）：核对身份、页面、弹窗类型与编号（R1-02），只调已有 logout()，落点由 App 按发起
    /// 实例判断（R1-09）。
    public func confirmLogout(_ dialog: MeDialog, version: Int) {
        guard consume(dialog, kind: SettingsState.logoutDialog), bound(version), identity.member else { return }
        state.busy = true
        deps.env.logout(identity, from: page)
    }

    /// 清除缓存确认（确认框编号，R1-02）：只清图片与网页缓存（AC-S1-137）；全部完成后才提示「已清除」并重算大小，失败按失败提示。
    public func confirmClear(_ dialog: MeDialog, version: Int) {
        guard consume(dialog, kind: SettingsState.clearDialog), bound(version) else { return }
        state.clearing = true
        cacheSeq += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cleared = await deps.env.clearCache()
            let bytes = await deps.env.cacheBytes()
            guard alive else { return }
            // 清除完成：推进大小读取的世代，清除期间发起的大小读取（可能读到清除前的大小）不再写回
            cacheSeq += 1
            state.cacheBytes = bytes
            state.clearing = false
            toast(MeNotice(cleared ? Self.clearedKey : "error.50001", id: nextId(), assertive: !cleared))
        }
    }

    /// 「重新显示下单须知」：DELETE /v1/me/tips/jump_tip（gate true、x-error-codes 20001 / 10405）；42901 执行层与页面都拦。写请求离开页面不
    /// 取消，但响应回来不得改动已出栈的页面；共享结算（禁用期、提示缓存世代）只按点击时的身份。
    private func resetTip() {
        guard identity.member else { return }
        let gate = deps.gates.resetTip
        if gate.active {
            toast(MeNotice(MeCodes.rateKey, id: nextId()))
            return
        }
        let probe = gate.probe()
        let identity = identity
        let deps = deps
        state.busy = true
        Task { @MainActor [weak self] in
            let result = await deps.api.send(
                ApiCall(operationId: Self.resetTipOperation, pathParams: ["tip_key": Self.jumpTip]),
                isValid: { true }, sendAllowed: probe.allowed, expected: identity.request
            )
            guard deps.env.isCurrent(identity) else { return }
            let error = MeErrors.of(result, probe: probe)
            if case .success = result {
                deps.env.tipsReset()
            } else if error.kind == .retryAfter {
                gate.start(error.disableMillis)
            }
            guard let self, alive else { return }
            state.busy = false
            if case .success = result {
                toast(MeNotice(Self.resetDoneKey, id: nextId(), assertive: false))
                return
            }
            switch error.kind {
            case .cancelled, .forceUpdate:
                break
            case .gated, .retryAfter:
                toast(MeNotice(MeCodes.rateKey, id: nextId()))
            default:
                toast(MeErrors.notice(error, id: nextId()))
            }
        }
    }

    private func nextId() -> Int {
        ids += 1
        return ids
    }

    private func toast(_ notice: MeNotice) {
        state.toast = notice
    }

    public func consumeToast(_ id: Int) {
        if state.toast?.id == id {
            state.toast = nil
        }
    }

    /// 出栈、换代、撤回的同步出口：撤销本页发起的 Me 读取（R1-03），清空子页草稿、关闭确认框与半屏。
    public func leave() {
        guard !left else { return }
        left = true
        cacheSeq += 1
        nickname?.leave()
        notify?.leave()
        nickname = nil
        notify = nil
        state = SettingsState(version: state.version + 1)
        gateWatch.removeAll()
        deps.repo.release(self)
    }

    public var hasLeft: Bool {
        left
    }
}

extension SettingsController {
    /// R1-06：订阅读取闸门与 resetTip 闸门（构造时一次；`leave` 时取消）。
    private func watchGates() {
        deps.gates.read.$blocked.removeDuplicates().sink { [weak self] blocked in
            MainActor.assumeIsolated { self?.readBlocked = blocked }
        }.store(in: &gateWatch)
        deps.gates.resetTip.$blocked.removeDuplicates().sink { [weak self] blocked in
            MainActor.assumeIsolated { self?.resetTipBlocked = blocked }
        }.store(in: &gateWatch)
    }

    /// 账号资料区域的读取提示（R1-05，共性第 23、31 条；Android R1-06）：
    /// - 没有快照：加载失败态（统一错误文案 + trace6）；
    /// - 已有快照：本页发起的刷新失败同样呈现（「没有刷新，下面是上次读到的信息」+ 统一错误文案 + trace6），不静默保留旧资料；
    /// 两种都配受共享读取闸门约束的【重试】（`readBlocked` 置灰，执行层另拦）。只给本执行器身份的快照。
    public func accountNotice(_ snapshot: MeSnapshot) -> SettingsAccountNotice? {
        guard identity.member, snapshot.identity == identity, let error = snapshot.error else { return nil }
        if snapshot.me == nil {
            return snapshot.phase == .error ? SettingsAccountNotice(notice: error, refreshFailed: false) : nil
        }
        guard snapshot.errorSource == ObjectIdentifier(self) else { return nil }
        return SettingsAccountNotice(notice: error, refreshFailed: true)
    }
}

/// 设置页账号资料区域的读取提示：`refreshFailed` = 已有快照时的刷新失败（文案前加「没有刷新」一句）。
public struct SettingsAccountNotice: Equatable, Sendable {
    public static let refreshFailedKey = "settings.refresh_failed"

    public let notice: MeNotice
    public let refreshFailed: Bool

    public init(notice: MeNotice, refreshFailed: Bool) {
        self.notice = notice
        self.refreshFailed = refreshFailed
    }

    /// 页面文案：统一错误消息（含 trace6）；刷新失败时前加「没有刷新」一句。
    public func message(_ texts: MeTexts) -> String {
        (refreshFailed ? texts.text(Self.refreshFailedKey) : "") + notice.message(texts)
    }
}

extension SettingsState {
    init(version: Int) {
        self.init()
        self.version = version
    }
}
