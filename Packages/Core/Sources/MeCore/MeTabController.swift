import Combine
import Foundation

/// 「我的」Tab 的执行器（brief §2.2；G04、G05、G06、G28、G31、G36）。构造时固定身份（APP-09 第 65 条）；每一次进入 Tab 建一个（Android R1-03、
/// R2-01）：切走 Tab、被下一页盖住、身份变了都在同步出口 `leave`，之后它的回调一律被拒、它发起的 getMe 作废并取消。按钮回调都带渲染时的
/// 快照版本与身份，执行前核对（APP-09 第 4、63 条）。
@MainActor
public final class MeTabController: ObservableObject, MeReader {
    public static let route = "Me"
    public static let login = "Login"
    public static let copied = "invite.copy_code.done"
    public static let copyFailed = "me.copy_failed"

    public let identity: MeIdentity
    public let deps: MeDeps
    /// 一次性的复制结果提示（polite 播报一次）。
    @Published public private(set) var toast: MeNotice?
    /// 通知引导条（G28）：进入、回前台、从系统设置回来时重新判断。
    @Published public private(set) var guideVisible = false
    private var left = false
    private var toastIds = 0
    private var guideSerial = 0

    public init(deps: MeDeps, identity: MeIdentity) {
        self.deps = deps
        self.identity = identity
    }

    /// 本执行器仍有效：没离开、身份仍是当前身份。
    public var alive: Bool {
        !left && deps.env.isCurrent(identity)
    }

    /// 本执行器（这一次进入）仍可读取（R1-03）：离开 Tab 或身份变了即停。
    public var reading: Bool {
        alive
    }

    /// 进入 Tab、下拉、回前台、从子页返回（G36）：读取许可绑定本执行器（这一次进入）。
    @discardableResult
    public func refresh(pull: Bool = false) -> Bool {
        guard alive, identity.member else { return false }
        return deps.repo.refresh(identity, page: self, pull: pull)
    }

    /// 页面显示的规则（MeView）。只用本执行器身份的快照。
    public func view(_ snapshot: MeSnapshot, masked: Bool) -> MeViewModel {
        let me = snapshot.identity == identity ? snapshot.me : nil
        return MeView.model(
            level: identity.level, me: me?.raw, masked: masked, availableRoutes: deps.env.availableRoutes(),
            earningsFlag: deps.env.earningsFlag()
        )
    }

    /// 重新判断引导条（G28）：已登录 && 系统通知未开启（拒绝过）&& 被拒满 48 小时 && 关闭满 7 天。系统状态是异步查询：等待后复核本执行器仍有效、
    /// 不是更早的一次查询（APP-04 第 30 条）。
    public func checkGuideBar() {
        guard alive, identity.member else {
            guideVisible = false
            return
        }
        guideSerial += 1
        let serial = guideSerial
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await deps.env.permissionStatus("push")
            guard alive, serial == guideSerial else { return }
            guideVisible = NotifyGuideBar.visible(
                loggedIn: identity.member, systemStatus: status, lastDeniedMs: deps.env.permissionDeniedAt("push"),
                lastClosedMs: deps.local?.guideClosedAt, nowMs: deps.env.nowMillis()
            )
        }
    }

    /// 【复制】邀请码（G19）：捕获渲染时的码与版本，执行时核对仍是当前快照里的同一个码；只走统一写入口。
    public func copyInviteCode(version: Int, code: String) {
        let snapshot = deps.repo.state
        guard alive, snapshot.version == version, snapshot.identity == identity, snapshot.me?.inviteCode == code else {
            return
        }
        let written = deps.env.copy(code)
        toastIds += 1
        toast = MeNotice(written ? Self.copied : Self.copyFailed, id: toastIds, assertive: false)
    }

    public func consumeToast(_ id: Int) {
        if toast?.id == id {
            toast = nil
        }
    }

    /// 宫格一格（G31）：渲染时的格；执行时核对本执行器仍有效、格仍在当前规则里。
    public func tap(_ cell: GridCell) {
        guard alive else { return }
        let grid = view(deps.repo.state, masked: false).grid
        guard grid.contains(cell) else { return }
        guard let route = cell.route else {
            deps.env.customerService(from: Self.route)
            return
        }
        deps.env.open(route, params: [:], from: nil)
    }

    /// 【提现】→ Wallet（G06）：只在渲染时的快照仍是当前快照时打开。
    public func withdraw(version: Int) {
        let snapshot = deps.repo.state
        guard alive, snapshot.version == version, snapshot.identity == identity, snapshot.me != nil else { return }
        deps.env.open(MeView.wallet, params: [:], from: nil)
    }

    /// 铃铛 → Messages（G04，h5；无红点）。
    public func bell() {
        guard alive, identity.member else { return }
        deps.env.open(MeView.messages, params: [:], from: nil)
    }

    /// 游客【登录 / 注册】。
    public func openLogin() {
        guard alive, !identity.member else { return }
        deps.env.open(Self.login, params: [:], from: nil)
    }

    /// 引导条点击：只跳系统里本 App 的通知设置，不经 PermissionRequester 申请（G28）。
    public func openGuide() {
        guard alive, guideVisible else { return }
        deps.env.openNotificationSettings()
    }

    /// 引导条关闭：记下关闭时刻（设备级，G28）；写不进也收起（本次进入内不再显示）。
    public func closeGuide() {
        guard alive else { return }
        deps.local?.markGuideClosed(deps.env.nowMillis())
        guideSerial += 1
        guideVisible = false
    }

    /// 眼睛按钮（金额隐藏，与订单、钱包页共用本机偏好 AmountMaskStore，键 amount_mask.hidden 不变）。
    public func toggleMask() {
        guard alive else { return }
        deps.mask?.toggle()
    }

    /// 离开（切到其他 Tab、进入下一页、身份变了）的同步出口：撤销并取消本次进入发起的 Me 读取（R1-03、R2-01）。
    public func leave() {
        guard !left else { return }
        left = true
        guideSerial += 1
        deps.repo.release(self)
    }

    public var hasLeft: Bool {
        left
    }
}
