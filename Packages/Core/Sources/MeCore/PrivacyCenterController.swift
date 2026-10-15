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
/// - 个性化开关：本机先保存（用户意愿优先，按设备），切换后记 recordConsent（channel=privacy_center）；失败不回滚、提示一次（G03）；
/// - 【撤回同意】先出确认框（【取消】主按钮、【确认撤回】次按钮）；确认交给应用级协调器（`MeEnv.withdrawConsent`，F-HM-24），撤回进行中页面其余
///   操作禁用。确认框编号一次性（R1-02），身份变了 App 重建本执行器、旧确认框随旧执行器消失（鸿蒙 R3-02）。
@MainActor
public final class PrivacyCenterController: ObservableObject {
    public static let recordConsent = "recordConsent"
    public static let agreement = "Agreement"
    public static let failedKey = "privacy_center.personalization_failed"

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

    /// 个性化开关（渲染时的版本）：本机先保存（按设备），再记 recordConsent（有令牌记用户级，无令牌记设备级，设备未注册只记本地）；失败提示一次，
    /// 不回滚（G03）。强更受限上下文、基本模式一律拒绝（执行层另查此刻 below_min，鸿蒙 R2-05）。
    public func setPersonalization(_ on: Bool, version: Int) {
        guard bound(version), model().personalizationSwitch, !deps.env.forceUpdateContext(),
              on != state.personalizationOn
        else { return }
        let now = deps.env.nowMillis()
        deps.local?.setPersonalization(on, now: now)
        state.personalizationOn = on
        state.version += 1
        guard deps.env.deviceRegistered(), let privacyVersion = deps.env.legalPrivacyVersion(),
              let body = Personalization.consentBody(on: on, legalPrivacyVersion: privacyVersion, nowMs: now,
                                                     level: identity.level)
        else { return }
        let gate = deps.gates.consent
        if gate.active {
            toast(MeNotice(Self.failedKey, id: nextId()))
            return
        }
        let probe = gate.probe()
        let identity = identity
        let deps = deps
        Task { @MainActor [weak self] in
            let result = await deps.api.send(
                ApiCall(operationId: Self.recordConsent, body: MeJson.text(body)), isValid: { true },
                sendAllowed: probe.allowed, expected: identity.request
            )
            guard deps.env.isCurrent(identity) else { return }
            let error = MeErrors.of(result, probe: probe)
            if error.kind == .retryAfter {
                gate.start(error.disableMillis)
            }
            guard let self, alive else { return }
            if case .success = result {
                return
            }
            if error.kind != .cancelled, error.kind != .forceUpdate {
                toast(MeNotice(Self.failedKey, id: nextId()))
            }
        }
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
