import Combine
import Config
import CouliNetwork
import Foundation
import Generated
import HomeCore
import Privacy
import UIKit

@MainActor final class AppHomeSignals: HomeSignals {
    private(set) var visible = false
    private(set) var screenReader = false
    private var blocking: Set<String> = []
    private let subject = PassthroughSubject<Void, Never>()
    var changed: AnyPublisher<Void, Never> {
        subject.eraseToAnyPublisher()
    }

    func blockers() -> Set<String> {
        blocking
    }

    #if DEBUG
    /// UI 测试（APP-11v `reader-on`）：经这个真实 HomeSignals 出口把读屏状态当作已开启。
    var debugReaderOverride: Bool?
    #endif

    func set(visible: Bool, reader: Bool, blockers: Set<String>) {
        self.visible = visible
        screenReader = reader
        #if DEBUG
        screenReader = debugReaderOverride ?? reader
        #endif
        blocking = blockers
        subject.send()
    }
}

struct AppHomeImages: HomeImageLoader {
    func load(_ raw: String) async -> Bool {
        guard let url = URL(string: raw), url.scheme == "https", url.host != nil else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            return UIImage(data: data) != nil && (response as? HTTPURLResponse)
                .map { (200..<300).contains($0.statusCode) } == true
        } catch { return false }
    }
}

@MainActor final class HomeDataCleaner: EnvironmentSwitchCleaning {
    static let name = "Home.localData"
    let cleanerName = HomeDataCleaner.name
    let storage: HomeStorage
    init(storage: HomeStorage = .shared) {
        self.storage = storage
    }

    func cleanForEnvironmentSwitch() throws {
        var failure: Error?
        do { try storage.lkg.clearAll() } catch { failure = error }
        do { try storage.prefs.clearAll() } catch { failure = failure ?? error }
        if let failure {
            throw failure
        }
    }

    static func register(_ cleaner: HomeDataCleaner = HomeDataCleaner(),
                         withdrawal: EnvironmentSwitchCleanerRegistry = PrivacyWithdrawalCleanup.registry,
                         environmentSwitch: EnvironmentSwitchCleanerRegistry = .shared) {
        for registry in [withdrawal, environmentSwitch] where !registry.registeredNames.contains(name) {
            registry.register(cleaner)
        }
    }
}

enum HomeBuildVariant {
    case debug, release
    static var current: HomeBuildVariant {
        #if DEBUG
        .debug
        #else
        .release
        #endif
    }
}

extension AppHome {
    // 测试交回约定的注入接口保留显式参数。
    // swiftlint:disable:next function_parameter_count
    static func make(
        network: AppNetwork,
        routing: AppRouting,
        config: AppConfig,
        login: AppLogin,
        update: AppUpdate,
        privacy: PrivacyController,
        environment: EnvironmentStore,
        variant: HomeBuildVariant,
        debugPort: () -> HomeContractPort?,
        storage: HomeStorage = .shared,
        timers: HomeTimers = HomeSystemTimers(),
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        images: HomeImageLoader = AppHomeImages(),
        bundled: @escaping @MainActor () -> Data? = HomeBundled.data,
        appVersion: String = AppRouting.appVersion,
        credentialsReadable: @escaping @MainActor () -> Bool = { PrivacyWithdrawalCleanup.runner.credentialsReadable }
    ) -> AppHome {
        // 生产端口（FU-X-HOME-PAGE-API-ios，D10-643）：Release 一律用它；Debug / Staging 每次装配现判，带
        // -CouliHomeVisual / -CouliFakeLoginServer 时 debugPort() 给出对应的假端口，否则同样走生产端口（不带参数的 Staging 包连 staging）。
        let live = ApiClientHomeContractPort(api: network.client)
        let port: HomeContractPort = variant == .debug ? (debugPort() ?? live) : live
        return AppHome(
            network: network,
            routing: routing,
            config: config,
            login: login,
            update: update,
            privacy: privacy,
            environment: environment,
            storage: storage,
            port: port,
            timers: timers,
            clock: clock,
            images: images,
            bundled: bundled,
            appVersion: appVersion,
            credentialsReadable: credentialsReadable
        )
    }
}

// TODO(N-35): 文案草稿（代拟）；正式键进入契约后转用 DefaultTexts。
// 商品卡与页底口径说明（price_basis*、rebate_*）、平台名与搜索页同一张草稿表（SearchDraftTexts，BR-PRICE-17 默认文案，
// 三端同一句；APP-11 P2），不在首页另抄一份。
enum HomeDraftTexts {
    static func text(_ key: String, _ vars: [String: String]) -> String {
        var body = DefaultTexts.text(key) ?? HomeTextDrafts.values[key] ?? SearchDraftTexts.drafts[key] ?? key
        for (name, value) in vars {
            body = body.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return body
    }
}

extension AppHome {
    /// 首页弹窗是否在显示（跟随当前控制器；控制器换实例时接到新的那个）。APP-11v-b：弹窗关闭后读屏焦点回到搜索入口。
    var popupShowing: AnyPublisher<Bool, Never> {
        $controller
            .compactMap(\.self)
            .map { controller in controller.$state.map { $0.popup != nil } }
            .switchToLatest()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
