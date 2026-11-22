import BridgeHost
import ClientCore
import Config
@testable import Couli
import CouliNetwork
import Privacy
import XCTest

/// APP-04 的 App 接线：撤回同意、切换环境时作废全部容器里的在途桥调用（三端共性第 4 条），排在网络层作废之后、清令牌之前。
@MainActor
final class WebWiringTests: XCTestCase {
    /// 生产组合（宿主 App 启动时已创建 AppNetwork 与 AppWeb）：网络层作废仍在第一位，桥的作废紧随其后。
    func testBridgeCleanerFollowsNetworkInvalidationInProductionRegistries() {
        for names in [
            PrivacyWithdrawalCleanup.registry.registeredNames,
            EnvironmentSwitchCleanerRegistry.shared.registeredNames,
        ] {
            XCTAssertEqual(
                Array(names.prefix(2)),
                [NetworkInvalidationCleaner.name, BridgeHostsCleaner.name],
                "\(names)"
            )
        }
    }

    /// 只有调试构建的一致性页才有本机源；生产协议判定只认验签通过的 bridge_origins（三端共性第 2、3 条；N-22）。
    func testProductionProtocolHasNoLoopbackOrigin() {
        let configless = BridgeProtocol(trustedOrigins: [], linkPatterns: [:], shareDomains: [])
        XCTAssertFalse(configless.isTrustedOrigin("http://127.0.0.1:8789"))
        XCTAssertNil(BridgeProtocol.normalizeOrigin("http://127.0.0.1:8789"))
        // h5_base_url 不当白名单用：只有 h5_base_url、没有签名白名单的配置经生产验签闭包生效后，可信源仍为空。
        let body = #"{"h5_base_url":"https://h5.example.test/app"}"#
        let store = ConfigStore(
            readFile: { nil }, writeFile: { _ in },
            fetcher: { _, done in done(ConfigReply(kindRaw: ConfigReply.ok, bodyJson: body, etag: nil)) },
            clock: { 1 }, bundled: "{}",
            verifyBridgeOrigins: AppConfig.bridgeOriginsVerifier(
                appId: AppNetwork.identity.appId, signKeys: AppConfig.bundledSignKeys, environmentId: { "test" }
            )
        )
        store.onColdStart()
        XCTAssertEqual(store.sourceRaw, ConfigStore.sourceCurrent, "只有 h5_base_url 的配置应已生效")
        XCTAssertEqual(store.trustedOrigins, [], "h5_base_url 不当白名单用")
        let production = BridgeProtocol(trustedOrigins: store.trustedOrigins, linkPatterns: [:], shareDomains: [])
        XCTAssertFalse(production.isTrustedOrigin("https://h5.example.test"), "h5_base_url 的源被当成可信源")
    }
}
