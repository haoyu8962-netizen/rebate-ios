import BridgeHost
import ClientCore
import Config
@testable import Couli
import Foundation
import XCTest

/// N-22 评审 r1 S2-3：生产缺省的运行环境闭包（`AppConfig.init` 不传 environmentId / signKeys，与 CouliApp 的调用点相同）
/// 每次验签现取运行环境 id，不在 init 时捕获定值。改的是 `UserDefaults.standard` 的环境选择键（生产缺省读它），
/// setUp 记下原值、tearDown 写回，不影响别的用例。
@MainActor
final class N22BridgeOriginsDefaultEnvTests: MeTestCase {
    private let selectionKey = AppNamespace.environmentSelectionKey
    private var originalSelection: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalSelection = UserDefaults.standard.object(forKey: selectionKey)
    }

    override func tearDown() {
        if let originalSelection {
            UserDefaults.standard.set(originalSelection, forKey: selectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectionKey)
        }
        super.tearDown()
    }

    /// 先选 test：staging 实测文档验不过；同一个 AppConfig 改选 staging 后再拉同一份文档：用新环境验，通过。
    func testDefaultEnvironmentIdIsReadOnEveryVerification() async throws {
        UserDefaults.standard.set("test", forKey: selectionKey)
        XCTAssertEqual(EnvironmentStore.runtimeEnvironmentId(), "test", "前置：生产缺省读到的运行环境")
        let app = make()
        let config = AppConfig(
            client: app.network.client,
            file: ClientFile(name: "n22-default-env.json", baseDirectory: MeAppFixture.localDirectory(suiteName)),
            environmentRegistry: app.environmentSwitch
        )
        try await load(config, marker: "env-test", start: true)
        XCTAssertEqual(config.store.trustedOrigins, [], "运行环境 test 下接受了 staging 文档")

        UserDefaults.standard.set("staging", forKey: selectionKey)
        XCTAssertEqual(EnvironmentStore.runtimeEnvironmentId(), "staging", "前置：改选后生产缺省读到的运行环境")
        try await load(config, marker: "env-staging", start: false)
        XCTAssertEqual(config.store.trustedOrigins, [N22BridgeOriginsWiringTests.stagingOrigin],
                       "改选 staging 后仍按旧环境验（运行环境在 init 时被捕获）")
        XCTAssertEqual(config.store.trustedOriginsVersion, 0)
    }

    /// 假服务回 staging 实测 jws 的配置（dict_version = marker），经生产入口拉取并等它成为生效配置。
    private func load(_ config: AppConfig, marker: String, start: Bool) async throws {
        let data = try N22OriginsSigner.text([
            "dict_version": marker, "h5_base_url": N22BridgeOriginsWiringTests.stagingOrigin,
            "bridge_origins": ["jws": N22BridgeOriginsWiringTests.stagingLiveJws],
        ])
        script.ok("GET /v1/config", data)
        if start {
            config.startIfSettled(.settled)
        } else {
            config.store.onForeground()
        }
        await waitUntil("配置 \(marker) 没有成为生效配置") {
            (N22OriginsSigner.object(config.snapshotJson)["dict_version"] as? String) == marker
        }
    }
}
