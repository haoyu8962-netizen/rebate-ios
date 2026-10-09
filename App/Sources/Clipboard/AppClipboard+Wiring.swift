import Clipboard
import Combine
import Config
import Foundation
import Privacy
import Router

extension AppClipboard {
    /// 生产组装（CouliApp）：系统剪贴板、Application Support 下的记录文件、ApiClient、Router 与各状态源。
    static func make(
        network: AppNetwork, routing: AppRouting, privacy: PrivacyController, config: AppConfig, login: AppLogin,
        system: SystemClipboard = UIKitSystemClipboard(),
        records: ClipboardRecordsCleaner = .shared
    ) -> AppClipboard {
        let client = network.client
        let clipboard = AppClipboard(
            system: system, store: records.store, api: client, router: routing.router,
            deps: Deps(
                privacy: { privacy.routerPrivacy },
                privacyPrompting: { routing.showsPrivacyDialog },
                forceUpdate: { routing.mustShowForceUpdate },
                configJson: { config.snapshotJson },
                guest: { !login.loggedIn },
                sessionGeneration: { client.sessionGeneration },
                networkEpoch: { client.invalidationTicket },
                serverForced: { routing.update.onServerForced() },
                networkForced: { routing.update.on10405(minSupported: $0) }
            )
        )
        clipboard.connect(privacy: privacy, login: login, records: records)
        return clipboard
    }

    /// 作废出口的接线：隐私结论变化（撤回、基本模式、隐私弹窗的显示）、登录 / 退出 / 切换账号、切换环境、撤回清理删掉记录。
    func connect(
        privacy: PrivacyController, login: AppLogin, records: ClipboardRecordsCleaner,
        environmentRegistry: EnvironmentSwitchCleanerRegistry = .shared
    ) {
        privacy.observeState { [weak self] _ in
            MainActor.assumeIsolated { self?.privacyChanged(privacy.routerPrivacy) }
        }
        login.$sessionVersion.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionChanged() }
        }.store(in: &subscriptionsForWiring)
        records.onCleared = { [weak self] in self?.recordsCleared() }
        // 切换环境：同步作废（清理注册表依次同步执行，在任何等待之前）；记录是设备级，不清。排在末尾：网络层作废在途请求、
        // 桥调用作废仍在最前（APP-03a 共性第 35 条、APP-04 共性第 4 条）
        let cleaner = ClipboardInvalidationCleaner(clipboard: self)
        if environmentRegistry.registeredNames.contains(ClipboardInvalidationCleaner.name) {
            environmentRegistry.replace(cleaner)
        } else {
            environmentRegistry.register(cleaner)
        }
    }
}

/// 切换环境的清理项：作废剪贴板提示条与在途 parse（不抛错）。
@MainActor
final class ClipboardInvalidationCleaner: EnvironmentSwitchCleaning {
    static let name = "Clipboard.inFlight"
    let cleanerName = ClipboardInvalidationCleaner.name
    private weak var clipboard: AppClipboard?

    init(clipboard: AppClipboard) {
        self.clipboard = clipboard
    }

    func cleanForEnvironmentSwitch() throws {
        clipboard?.environmentSwitched()
    }
}

/// 读取前提（brief §2.1）：隐私、敏感浮层、配置开关、网页抑制、changeCount。
extension AppClipboard {
    // MARK: - 前提

    func consentRaw() -> String {
        switch deps.privacy() {
        case .consented: ClipboardReadPolicy.consentAgreed
        case .basicMode: ClipboardReadPolicy.consentBasic
        case .notDecided: ClipboardReadPolicy.consentOutdated
        }
    }

    func currentOverlay() -> String {
        if deps.privacyPrompting() {
            return ClipboardSensitive.overlayPrivacyFirstLaunch
        }
        if deps.forceUpdate() {
            return ClipboardSensitive.overlayForceUpdate
        }
        return overlaySource() ?? ClipboardSensitive.overlayNone
    }

    func overlayClear() -> Bool {
        !ClipboardSensitive.overlays.contains(currentOverlay())
    }

    var config: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(deps.configJson().utf8))) as? [String: Any] ?? [:]
    }

    /// 配置开关 clipboard.enabled.ios（G05：只认端键；明确 false 才关自动识别，缺键按开启；手动粘贴保留）。
    func configEnabled() -> Bool {
        let flags = (config["features"] as? [String: Any])?["flags"] as? [String: Any]
        guard let number = flags?[Self.configFlag] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return true
        }
        return number.boolValue
    }

    func shareDomains() -> [String] {
        (config["share_domains"] as? [Any] ?? []).compactMap { $0 as? String }
    }

    func rules() -> ClipboardRules {
        ClipboardRules.fromConfig(config["clipboard"])
    }

    func readState(event: String) -> ClipboardReadState {
        var state = ClipboardReadState(
            consent: consentRaw(), event: event, route: path.last?.route ?? (tab.route ?? RoutePolicy.home)
        )
        state.overlay = currentOverlay()
        state.configEnabled = configEnabled()
        state.webSuppressed = path.last.map { suppressedWeb.contains($0.id) } ?? false
        state.readThisForeground = watcher.readThisForeground
        state.iosChangeCountChanged = String(system.changeCount) != store.read(Self.lastChangeKey)
        return state
    }
}

/// 作废出口（brief §0）：隐私、会话、环境、进后台。
extension AppClipboard {
    // MARK: - 作废出口

    /// 隐私结论变化：不再是已同意（撤回、基本模式）时作废全部；hash 记录由撤回清理项删除（确认落盘），这里另尽力清一次。
    func privacyChanged(_ state: PrivacyState) {
        screenChanged()
        guard state != .consented else { return }
        invalidateAll()
        try? ledger.clear()
        try? history.clear()
        try? store.write(Self.lastChangeKey, nil)
    }

    /// 撤回清理项删掉记录之后：作废内存里的提示与请求。
    func recordsCleared() {
        invalidateAll()
    }

    /// 登录、退出、切换账号：作废提示条与在途 parse。
    func sessionChanged() {
        invalidateAll()
    }

    /// 切换环境：作废全部。
    func environmentSwitched() {
        invalidateAll()
    }

    func invalidateAll() {
        homeGen += 1
        screenGen += 1
        manualGen += 1
        lastOrigin = currentOrigin()
        prompt = nil
        result = nil
        publishOwner()
        cancelTasks()
    }

    func cancelTasks() {
        let running = tasks
        tasks = [:]
        // 系统粘贴还没交付的读取一并作废（共性第 28 条）：之后到达的文本只丢弃
        reading = nil
        loginReading = nil
        busy = false
        for task in running.values {
            task.cancel()
        }
    }
}
