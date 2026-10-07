import BridgeHost
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

    /// 只有调试构建的一致性页才有本机源；生产协议判定只认 bridge_origins 里的 https origin（三端共性第 2、3 条）。
    func testProductionProtocolHasNoLoopbackOrigin() {
        let configless = BridgeProtocol(trustedOrigins: [], linkPatterns: [:], shareDomains: [])
        XCTAssertFalse(configless.isTrustedOrigin("http://127.0.0.1:8789"))
        XCTAssertNil(BridgeProtocol.normalizeOrigin("http://127.0.0.1:8789"))
        XCTAssertEqual(
            WebConfigReader.trustedOrigins(configJson: #"{"h5_base_url":"https://h5.example.test/app"}"#), [],
            "h5_base_url 不当白名单用"
        )
    }
}
