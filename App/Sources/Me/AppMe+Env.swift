import Clipboard
import CouliNetwork
import Foundation
import Generated
import MeCore
import Push
import Router
import UIKit
import WalletCore

/// 「我的」类页面要的环境（MeEnv）、统一客服出口的系统能力与推送上报读的状态。
extension AppMe: MeEnv, CustomerServicePorts, PushReportState {
    func identity() -> MeIdentity {
        computeIdentity()
    }

    func isCurrent(_ identity: MeIdentity) -> Bool {
        check(identity) == .current
    }

    func check(_ identity: MeIdentity) -> IdentityCheck {
        let snapshot = client.identitySnapshot(credentialsReadable: credentialsReadable())
        guard snapshot.readable, privacy.routerPrivacy == .consented else {
            return self.identity(from: snapshot) == identity ? .current : .stale
        }
        guard snapshot.request.generation == identity.request?.generation,
              snapshot.request.epoch == identity.request?.epoch,
              identity.key.hasSuffix("|\(clearedCount)") else { return .stale }
        guard snapshot.known else { return .unknown }
        return self.identity(from: snapshot) == identity ? .current : .stale
    }

    func recheckIdentity() {
        syncIdentity()
    }

    /// 经 Router 以 App 内来源打开。`page` 是发起页：只在它仍在栈顶时打开（出栈、被覆盖之后的旧回调不导航）。强更受限上下文里的协议、
    /// 清单按「从强更页进入」打开（03 §4.1）。
    func open(_ route: String, params: [String: String], from page: UUID?) {
        if let page {
            guard router.path.last?.id == page else { return }
        }
        let request = RouteRequest(route: route, values: params.mapValues { .string($0) }, from: .inApp)
        let fromForceUpdate = page.flatMap { id in router.path.first { $0.id == id }?.fromForceUpdatePage } ?? false
        if route == Self.agreement, fromForceUpdate || routing.mustShowForceUpdate {
            router.openFromForceUpdatePage(request)
        } else {
            router.open(request)
        }
    }

    func copy(_ text: String) -> Bool {
        (writer ?? clipboard?.writer)?.write(text) ?? false
    }

    /// 设置页剪贴板开关（FU-X-CLIP-DEFAULT-ON）：与首页自动识别是同一个开关实例（`clipboard.autoSwitch`）。没接剪贴板时按默认开启显示、切换不做事。
    func clipboardAutoOn() -> Bool {
        clipboard?.autoSwitch.isOn ?? true
    }

    func setClipboardAuto(_ on: Bool) {
        clipboard?.autoSwitch.set(on)
    }

    func configObject(_ key: String) -> Any? {
        guard let text = config.store.value(key: key), let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// 本端路由表里有、since.ios 不晚于本端版本的路由（G31：路由表没有的、since 不满足的格不显示）。
    func availableRoutes() -> Set<String> {
        let version = AppRouting.appVersion.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        return Set(Routes.all.compactMap { name, spec in
            spec.sinceIOS.map { Self.versionAtLeast(version, $0) } == true ? name : nil
        })
    }

    static func versionAtLeast(_ version: String, _ minimum: String) -> Bool {
        let lhs = version.split(separator: ".").map { Int($0) ?? -1 }
        let rhs = minimum.split(separator: ".").map { Int($0) ?? -1 }
        guard !lhs.contains(-1), !rhs.contains(-1), !lhs.isEmpty, !rhs.isEmpty else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left > right
            }
        }
        return true
    }

    func earningsFlag() -> Bool? {
        let flags = (configObject("features") as? [String: Any])?["flags"] as? [String: Any]
        guard let number = flags?[EarningsEntry.flagKey] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    func customerService(from route: String) {
        cs.open(from: route)
    }

    func permissionStatus(_ type: String) async -> String {
        await system.permissionStatus(type)
    }

    func permissionDeniedAt(_ type: String) -> Int64? {
        system.permissionDeniedAt(type)
    }

    func openNotificationSettings() {
        system.openNotificationSettings()
    }

    func openAppSettings() {
        system.openAppSettings()
    }

    /// G26：锁定契约 system-permissions.json 的 permissions（生成物，不手写清单）。
    func permissionEntries() -> [[String: Any]] {
        SystemPermissions.entries
            .map { ["type": $0.type, "platform": $0.platform, "purpose_key": $0.purposeKey as Any] }
    }

    func requestFullFunction() {
        privacy.requestFullFunction()
    }

    func forceUpdateContext() -> Bool {
        routing.mustShowForceUpdate
    }

    func deviceRegistered() -> Bool {
        deviceId() != nil
    }

    func consentedPrivacyVersion() -> Int? {
        privacy.consentedVersion
    }

    func legalPrivacyVersion() -> Int? {
        let legal = configObject("legal") as? [String: Any]
        let version = (legal?["privacy"] as? [String: Any])?["version"] as? NSNumber
        return version.map(\.intValue) ?? consentedPrivacyVersion()
    }

    func cacheBytes() async -> Int64? {
        await system.cacheBytes()
    }

    func clearCache() async -> Bool {
        await system.clearCache()
    }

    var appVersion: String {
        AppRouting.appVersion.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
    }

    var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /// 复制诊断信息（G23；只取白名单内的项，Diagnostics 再过滤一次）：配置版本取 /v1/config.dict_version、首页版本取 h5_release.version（H06 同一
    /// 代拟映射）；推送是否已上报取 Reporter 的本次运行状态（同一会话）；最近 trace_id 网络层没有记录，整行省略。
    func diagnosticsFields() -> [String: Any] {
        var fields: [String: Any] = [
            "version": appVersion, "build": appBuild, "channel": InstallChannel.appstore.rawValue,
            "push_reported": push.reportedThisRun,
        ]
        fields["system_version"] = system.osVersion()
        fields["model"] = system.model()
        fields["device_id"] = deviceId()
        let traces = recentTraceIds()
        if !traces.isEmpty {
            fields["trace_ids"] = traces
        }
        if let dict = configObject("dict_version") {
            fields["config_version"] = (dict as? String) ?? (dict as? NSNumber)?.stringValue
        }
        if let version = homeVersion() {
            fields["home_version"] = version
        }
        return fields
    }

    func close(page: UUID) -> Bool {
        guard router.path.last?.id == page else { return false }
        router.path.removeLast()
        return true
    }

    func tipsReset() {
        onTipsReset()
    }

    func nowMillis() -> Int64 {
        clock()
    }

    func displayNowMillis() -> Int64 {
        client.calibratedNowMillis
    }

    // MARK: - CustomerServicePorts

    func kfUrl() -> String? {
        (configObject("kf") as? [String: Any])?["url"] as? String
    }

    func wechatInstalled() -> String {
        system.wechatInstalled()
    }

    func openExternal(_ url: String) async -> Bool {
        await system.openExternal(url)
    }

    func openHelp() {
        router.open(RouteRequest(route: Self.help, from: .inApp))
    }

    // MARK: - PushReportState

    func level() -> String {
        computeIdentity().level
    }

    func sessionScope() -> String {
        client.isolatedSessionScope ?? ""
    }

    func forceUpdate() -> String {
        updateRaw()
    }

    func ownership() -> RequestOwnership? {
        let identity = computeIdentity()
        return identity.member ? identity.request : nil
    }

    /// 10405：网络层对确需强更的 10405 已调 onForceUpdate 进已有分流（APP-13a 共性第 12 条：只消费网络层已确定的 Effect）；这里不另弹提示、
    /// 不再按错误码重判。
    func onForceUpdate() {}
}
