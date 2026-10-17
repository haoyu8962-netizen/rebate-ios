import CouliNetwork
import Foundation
import MeCore
import Privacy
import Router

/// 撤回同意的应用级协调器与退出登录。
extension AppMe {
    /// 撤回同意（G24、G25，brief §0 第 1 条；F-HM-24：进行中状态在应用级，页面执行器重建后继承、完成前拒绝重复启动）。`identity` 是确认框生成时
    /// 的身份；启动前核对，已合法启动的撤回一定完成本地清理（不随页面出栈取消）。
    /// 1. 确认生效的同步入口立即停报推送（共性第 2、19 条；撤回停报闸门与会话无关，完成前登录新会话也不恢复上报）；
    /// 2. 设备已注册 → 设备级 recordConsent {type: privacy, version: 本机已同意版本, accepted: false, channel: privacy_center,
    /// client_at}（有令牌
    ///    也是设备级，服务端处理）；设备未注册或撤回记录禁用期内跳过；
    /// 3. 无论成功、失败还是超时，调已有的本地撤回（PrivacyController.withdraw → 撤回清理名单含本任务新增项 → 基本模式，Router 回基本模式首页）；
    /// 4. 本地落盘失败（清理名单有项没清掉或撤回记录没落盘）：在当前可见界面提示「撤回没有生效」并可重试（鸿蒙 R2-04）。
    func withdrawConsent(_ identity: MeIdentity) {
        let state = deps.withdraw
        guard !state.busy, isCurrent(identity), identity.level != MeLevel.basic else { return }
        state.busy = true
        push.beginWithdraw()
        pushTracker.cancelColdStart()
        let version = privacy.consentedVersion
        let body = PrivacyWithdrawFlow.request(
            deviceRegistered: deviceRegistered() && version != nil, consentedVersion: version ?? 0, nowMs: clock()
        )
        let gate = gates.consent
        let call = body.map { ApiCall(operationId: Self.recordConsent, body: MeJson.text($0)) }
        let client = client
        // R1-03（共性第 30 条）：撤回记录绑定**确认时**固定的请求归属（账号、会话世代、作废世代），发送与续发只比较、不按执行时的状态重新绑定；
        // 外层 Task / 限时子任务开始前会话或环境已换代 → 网络层零发送（旧确认的版本与撤回记录不发给新会话、新环境），本地撤回照常完成
        let owner = identity.request
        Task { @MainActor [weak self] in
            if let call, !gate.active {
                // 有令牌也是设备级（服务端处理）；结果不影响本地撤回（G24）。写接口 10 秒超时、不重试；另设上限，防止卡住撤回
                _ = await Self.withLimit(seconds: 15) {
                    await client.send(call, isValid: { true }, sendAllowed: gate.sendAllowed, expected: owner)
                }
            }
            guard let self else { return }
            privacy.withdraw()
            clearForConsentRevoked()
            syncIdentity()
            state.busy = false
            push.endWithdraw()
            if !credentialsReadable() {
                failWithdraw()
            }
        }
    }

    private func failWithdraw() {
        withdrawFailureSerial += 1
        deps.withdraw.failed = withdrawFailureSerial
    }

    /// 「撤回没有生效」的【重试】（提示框的一次性编号）：再试一次本地清理（撤回清理执行器补写记录并重跑清理）。
    func retryWithdrawCleanup(_ id: Int) {
        guard deps.withdraw.failed == id else { return }
        deps.withdraw.failed = nil
        if !retryWithdrawal() {
            failWithdraw()
        }
        syncIdentity()
    }

    /// 【关闭】（同一编号才生效）。关闭后 PrivacyGate 仍在冷启动与读取凭据前重试写入。
    func dismissWithdrawFailed(_ id: Int) {
        if deps.withdraw.failed == id {
            deps.withdraw.failed = nil
        }
    }

    /// 在 `seconds` 内等 `work`；超时返回 nil（work 随任务组取消）。
    static func withLimit<T: Sendable>(seconds: UInt64, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return nil
            }
            let first = await (group.next()).flatMap(\.self)
            group.cancelAll()
            return first
        }
    }

    /// 退出登录（设置页、RiskNotice、申诉页的确认之后）：同步停报推送 → 已有 logout()（失败也完成本地退出，已有行为）→ 原会话确实结束、现在
    /// 不是已登录、发起页面仍是栈顶（或是被这次会话清理带走的只能登录访问的页面）、发起之后用户没有再导航 → 经 Router 回「我的」游客态（R1-09，
    /// flow-map §23.1.9）。
    /// R1-04（共性第 30 条）：确认时固定的请求归属（账号 + 会话世代 + 作废世代）一路传进 AppLogin / LoginService：logout 请求只按它发送，本地
    /// signOut 只清这一世代的会话；异步任务开始后不再取「此刻的会话」——确认之后、任务执行之前已保存了 B 会话时不退出 B。
    func logout(_ identity: MeIdentity, from page: UUID?) {
        guard let login, !loggingOutNow, check(identity) != .stale, identity.member, let owner = identity.request else {
            return
        }
        loggingOutNow = true
        let origin = page.flatMap { id in router.path.first { $0.id == id }?.route }
        let navigations = userNavigations
        push.halt()
        Task { @MainActor [weak self] in
            let done = await login.logout(owner: owner)
            guard let self else { return }
            loggingOutNow = false
            syncIdentity()
            let stillHere = page.map { id in router.path.last?.id == id } ?? true
            let closedByCleanup = origin.map { Self.loginOnly.contains($0) } ?? false
            guard done, computeIdentity().level != MeLevel.member, stillHere || closedByCleanup,
                  userNavigations == navigations
            else { return }
            router.open(RouteRequest(route: Self.me, from: .inApp))
        }
    }
}
