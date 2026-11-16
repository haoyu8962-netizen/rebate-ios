import Combine
import CouliNetwork
import Foundation
import WalletCore

/// 隐私中心的页面状态。
public struct PrivacyCenterState: Equatable, Sendable {
    public static let withdrawDialog = "withdraw"

    /// 系统权限一节各类型的状态（PermissionRequester 同一套映射；只查不申请）。
    public var permissionStatus: [String: String] = [:]
    public var personalizationOn = true
    public var dialog: MeDialog?
    public var toast: MeNotice?
    public var version = 0
}

/// 隐私中心执行器（PrivacyCenter 路由；brief §2.4–§2.6，§0 第 1、2 条；G03、G24、G25、G26；BR-ID-11、BR-ID-13）。构造时固定身份与强更受限上下文：
/// - 分节只按 `PrivacyCenterView`（basic 只读并在原位显示【开启完整功能】；guest、member 有个性化开关与【撤回同意】；从强更页进入时只留清单、协议
///   与【撤回同意】）；
/// - 系统权限一节：iOS 列通知、相册（生成物里的锁定清单），状态只查不申请，点击跳系统设置（不改节流），回前台重新查询；
/// - 个性化开关：本机先保存（按设备），切换后记 recordConsent（channel=privacy_center）；登录用户这条请求没成功（含身份未知被本地拒、限流中没发）
///   时本机开关回滚到切换前并提示一次，游客只写本地、失败只提示不回滚（D10-1728，BR-ID-13：登录用户以服务端为准）；
/// - 【撤回同意】先出确认框（【取消】主按钮、【确认撤回】次按钮）；确认交给应用级协调器（`MeEnv.withdrawConsent`，F-HM-24），撤回进行中页面其余
///   操作禁用。确认框编号一次性（R1-02），身份变了 App 重建本执行器、旧确认框随旧执行器消失（鸿蒙 R3-02）。
@MainActor
public final class PrivacyCenterController: ObservableObject {
    public static let recordConsent = "recordConsent"
    public static let agreement = "Agreement"
    public static let failedKey = "privacy_center.personalization_failed"
    /// 登录用户切换没保存成功、开关已回滚时的提示（草稿键，D10-1838；游客仍用 `failedKey`）。
    public static let revertedKey = "privacy_center.personalization_reverted"

    public let identity: MeIdentity
    public let deps: MeDeps
    public let page: UUID?
    /// 从强更页进入（打开时固定，03 §4.1「强更页的次要入口」）。
    public let forceUpdate: Bool
    @Published public private(set) var state = PrivacyCenterState()
    private var left = false
    private var ids = 0
    private var statusSeq = 0

    public init(deps: MeDeps, identity: MeIdentity, page: UUID?, forceUpdate: Bool) {
        self.deps = deps
        self.identity = identity
        self.page = page
        self.forceUpdate = forceUpdate
        state.personalizationOn = deps.local?.personalizationOn ?? true
    }

    public var alive: Bool {
        !left && deps.env.isCurrent(identity)
    }

    public func model() -> PrivacyCenterModel {
        PrivacyCenterView.model(
            level: identity.level, platform: MePlatform.ios, permissionEntries: deps.env.permissionEntries(),
            permissionStatus: state.permissionStatus, forceUpdate: forceUpdate
        )
    }

    /// 撤回同意进行中（应用级，控制器重建后继承）。
    public var withdrawing: Bool {
        deps.withdraw.busy
    }

    private func bound(_ version: Int) -> Bool {
        alive && state.version == version && !deps.withdraw.busy
    }

    /// 进入、回前台、从系统设置回来：重新查询系统权限状态（只查不申请、不改节流）；个性化开关按本机值。
    public func refresh() {
        guard alive else { return }
        state.personalizationOn = deps.local?.personalizationOn ?? true
        statusSeq += 1
        let mine = statusSeq
        let types = model().permissionRows.map(\.type)
        Task { @MainActor [weak self] in
            guard let self else { return }
            var status: [String: String] = [:]
            for type in types {
                status[type] = await deps.env.permissionStatus(type)
            }
            guard alive, statusSeq == mine else { return }
            state.permissionStatus = status
            state.version += 1
        }
    }

    /// 两份清单、隐私政策、用户协议（G21、H03：收集清单 → Agreement {type: privacy}，共享清单 → {type: sdk_list}）。
    public func openDocument(_ type: String, version: Int) {
        guard bound(version), ["privacy", "agreement", "sdk_list"].contains(type) else { return }
        deps.env.open(Self.agreement, params: ["type": type], from: page)
    }

    /// 系统权限一节的条目：跳系统里本 App 的设置页（不申请，不改节流）。
    public func openPermission(_ type: String, version: Int) {
        guard bound(version), model().permissionRows.contains(where: { $0.type == type }) else { return }
        deps.env.openAppSettings()
    }

    /// 基本模式【开启完整功能】：重新展示首启弹窗。
    public func enableFull(version: Int) {
        guard bound(version), model().enableFullButton else { return }
        deps.env.requestFullFunction()
    }

    /// 个性化开关（渲染时的版本）：本机先保存（按设备），再记 recordConsent（有令牌记用户级，无令牌记设备级，设备未注册只记本地）。
    /// 登录用户（member）这条请求没成功——发不出（设备未注册、缺协议版本、限流中）、本地拒绝（含身份未知）、服务端 / 传输失败——本机开关回滚到切换前
    /// 并提示一次；游客（guest）只提示不回滚（D10-1728）。同意记录在途时（应用级，全 App 一次一条）再切换不受理；不是最近一次切换不回滚；
    /// 结果回来时已离开本页也回滚本机值（不提示）；身份已变（控制器将重建）不动本机值。回滚写回切换前的值与切换时刻。
    /// 强更受限上下文、基本模式一律拒绝（执行层另查此刻 below_min，鸿蒙 R2-05）。
    public func setPersonalization(_ on: Bool, version: Int) {
        guard bound(version), model().personalizationSwitch, !deps.env.forceUpdateContext(),
              on != state.personalizationOn, !deps.personalization.pending
        else { return }
        let now = deps.env.nowMillis()
        // 切换前的值取本机此刻生效的值（不取本页状态：别的页面的失败回滚可能让本页显示过期，评审 r2 S2-A）
        let toggle = PersonalizationToggle(
            on: on, previous: deps.local.map { !$0.personalizationOffNow } ?? state.personalizationOn,
            // 已知小概率：切换时本机读不出切换时刻（nil）而随后写成功，失败回滚会把真实时刻写成 0（D10-1847 认，不改）
            serial: deps.personalization.toggled(), previousAt: deps.local?.personalizationChangedAt
        )
        deps.local?.setPersonalization(on, now: now)
        state.personalizationOn = on
        state.version += 1
        guard deps.env.deviceRegistered(), let privacyVersion = deps.env.legalPrivacyVersion(),
              let body = Personalization.consentBody(on: on, legalPrivacyVersion: privacyVersion, nowMs: now,
                                                     level: identity.level)
        else {
            personalizationFailed(toggle, notify: identity.level == MeLevel.member)
            return
        }
        let gate = deps.gates.consent
        if gate.active {
            personalizationFailed(toggle, notify: true)
            return
        }
        let probe = gate.probe()
        let identity = identity
        let deps = deps
        // 一次只一条在途：期间再切换不受理，开关显示不可用（失败回滚的「切换前」就是服务端最后收到的值）。不另设总上限（D10-1847）：
        // 写接口每段 ≤10 秒、段数有限（受限会话等刷新、校时重签、刷新后重放、重注册后重放），整体有限，等到确定结果本机与服务端才一致
        deps.personalization.begin()
        // 强持有到结果回来：离开本页后失败也要回滚本机值
        Task { @MainActor in
            let result = await deps.api.send(
                ApiCall(operationId: Self.recordConsent, body: MeJson.text(body)), isValid: { true },
                sendAllowed: probe.allowed, expected: identity.request
            )
            deps.personalization.end()
            // 身份已变（stale）：不动本机值、不提示；身份暂时未知：本地拒绝没发出，照样按失败回滚本机值（评审 S2-2）
            guard deps.env.check(identity) != .stale else { return }
            let error = MeErrors.of(result, probe: probe)
            if error.kind == .retryAfter {
                gate.start(error.disableMillis)
            }
            if case .success = result {
                return
            }
            // cancelled / forceUpdate 只回滚不提示：夹具造不出「身份仍有效时的这两类结果」，没有用例（D10-1847 认缺口，见 followups）
            personalizationFailed(toggle, notify: error.kind != .cancelled && error.kind != .forceUpdate)
        }
    }

    /// 个性化切换的请求没成功：登录用户且仍是最近一次切换（应用级序号，D10-1838）时，本机开关回滚到切换前的值与时刻
    /// （网络头随之恢复）；页面还在时同步页面状态，`notify` 时提示一次。
    private func personalizationFailed(_ toggle: PersonalizationToggle, notify: Bool) {
        let revert = identity.level == MeLevel.member && deps.personalization.isLatest(toggle.serial)
        if revert {
            // 切换前从没成功切换过（previousAt 为 nil）写回 0「没有成功的切换」：被回滚的切换不得留下最新切换时刻——BR-ID-13 登录对账按
            // 切换时刻较晚者为准，留下「现在」会压过用户在别的设备上真正做过的选择（D10-1836）
            deps.local?.setPersonalization(toggle.previous, now: toggle.previousAt ?? 0)
            if !left, state.personalizationOn != toggle.previous {
                state.personalizationOn = toggle.previous
                state.version += 1
            }
        }
        if notify, !left {
            toast(MeNotice(revert ? Self.revertedKey : Self.failedKey, id: nextId()))
        }
    }

    /// 一条个性化同意记录结束后（可能是别的页面发起的）：页面开关按本机此刻生效的值重读，免得显示过期（评审 r2 S2-A）。
    public func syncPersonalization() {
        guard !left else { return }
        let on = deps.local.map { !$0.personalizationOffNow } ?? state.personalizationOn
        guard on != state.personalizationOn else { return }
        state.personalizationOn = on
        state.version += 1
    }

    /// 【撤回同意】：出确认框（一次性编号）。
    public func askWithdraw(version: Int) {
        guard bound(version), model().withdrawButton else { return }
        ids += 1
        state.dialog = MeDialog(kind: PrivacyCenterState.withdrawDialog, id: ids)
    }

    /// 【取消】（主按钮）；同一编号才生效。点遮罩不关闭（couliDialog 遮罩不响应），系统返回在确认框显示期间被禁用。
    public func cancelWithdraw(_ dialog: MeDialog) {
        if state.dialog == dialog {
            state.dialog = nil
        }
    }

    /// 【确认撤回】（确认框生成时的编号）：核对身份、页面与编号，用过即作废（R1-02、鸿蒙 R1-07）；交给应用级协调器。
    public func confirmWithdraw(_ dialog: MeDialog) {
        guard dialog.kind == PrivacyCenterState.withdrawDialog, state.dialog == dialog else { return }
        state.dialog = nil
        guard alive, !deps.withdraw.busy, model().withdrawButton else { return }
        deps.env.withdrawConsent(identity)
    }

    private func toast(_ notice: MeNotice) {
        state.toast = notice
    }

    public func consumeToast(_ id: Int) {
        if state.toast?.id == id {
            state.toast = nil
        }
    }

    private func nextId() -> Int {
        ids += 1
        return ids
    }

    /// 出栈、换代：作废确认框与状态查询。
    public func leave() {
        guard !left else { return }
        left = true
        statusSeq += 1
        state.dialog = nil
        state.version += 1
    }

    public var hasLeft: Bool {
        left
    }
}

/// 一次个性化切换：切到的值、切换前本机生效的值（回滚写回）、应用级切换序号（判是否最近一次）与切换前本机记的切换时刻（回滚写回）。
struct PersonalizationToggle {
    let on: Bool
    let previous: Bool
    let serial: Int
    let previousAt: Int64?
}
