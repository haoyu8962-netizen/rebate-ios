import ClientCore
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Privacy
import SecureStore
import Session
import XCTest

/// APP-08 iOS 第八次修复 NEW-05（S0）在 App 真实组合处的接线：用户经 PrivacyController.withdraw 撤回同意时，
/// 待清理标记写入的那一刻，AppNetwork 的网络禁读屏障与 DeviceRegistry 的设备屏障都已竖起（网络清理器尚未执行）。
@MainActor
final class WithdrawalBarrierOrderR3hWiringTests: XCTestCase {
    private struct NoIdentifier: DeviceIdentifierReading {
        @MainActor
        func readIdentifier() -> String? {
            nil
        }
    }

    /// 隐私存储：写撤回记录（发布待清理标记）之后立即调 `onMarker`。
    private final class MarkerProbeStore: PrivacyStore {
        let inner = MemoryPrivacyStore()
        var onMarker: (() -> Void)?

        var decisionRaw: String {
            get { inner.decisionRaw }
            set { inner.decisionRaw = newValue }
        }

        var consentedVersion: String? {
            get { inner.consentedVersion }
            set { inner.consentedVersion = newValue }
        }

        var consentedAtMillis: Int64? {
            get { inner.consentedAtMillis }
            set { inner.consentedAtMillis = newValue }
        }

        var basicMode: Bool {
            get { inner.basicMode }
            set { inner.basicMode = newValue }
        }

        var withdrawalCleanupPending: Bool {
            inner.withdrawalCleanupPending
        }

        func commitConsent(version: String, atMillis: Int64) {
            inner.commitConsent(version: version, atMillis: atMillis)
        }

        func commitBasicMode() {
            inner.commitBasicMode()
        }

        func commitWithdrawal() {
            inner.commitWithdrawal()
            onMarker?()
        }

        func clearWithdrawalPending() {
            inner.clearWithdrawalPending()
        }

        func commitWithdrawalVerified() -> Bool {
            let written = inner.commitWithdrawalVerified()
            onMarker?()
            return written
        }
    }

    /// 标记写入那一刻的观察。
    private struct Seen {
        let network: Bool
        let device: Bool
        let tokenPresent: Bool
    }

    func testWithdrawThroughPrivacyControllerRaisesBarriersBeforeMarker() {
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let store = MarkerProbeStore()
        store.commitConsent(version: "1", atMillis: 0)
        let runner = WithdrawalCleanupRunner(store: store, registry: withdrawal)
        let network = AppNetwork(
            tokens: tokens,
            pendingBackend: MemoryPendingKeyBackend(),
            deviceStore: DeviceIdentityStore(store: MemorySecureStore()),
            identifierReader: NoIdentifier(),
            withdrawalRegistry: withdrawal,
            environmentRegistry: environmentSwitch,
            credentialsReadable: { runner.credentialsReadable },
            configuration: AppStubProtocol.configuration()
        )
        let privacy = PrivacyController(store: store, clock: { 1 }, bundledPolicyVersion: "1", withdrawalRunner: runner)
        XCTAssertFalse(network.client.withdrawalReadBarrierRaised, "前提：撤回之前网络屏障没竖")
        XCTAssertFalse(network.registry.withdrawalBarrierRaised, "前提：撤回之前设备屏障没竖")

        var atMarker: [Seen] = []
        store.onMarker = {
            atMarker.append(Seen(
                network: network.client.withdrawalReadBarrierRaised,
                device: network.registry.withdrawalBarrierRaised,
                tokenPresent: tokens.accessToken != nil
            ))
        }
        privacy.withdraw()

        XCTAssertEqual(atMarker.count, 1, "前提：撤回记录写了一次")
        XCTAssertEqual(atMarker.first?.tokenPresent, true, "前提：标记写入时清理器尚未执行（令牌还在）")
        XCTAssertEqual(atMarker.first?.network, true, "标记发布之前已竖起网络禁读屏障")
        XCTAssertEqual(atMarker.first?.device, true, "标记发布之前已竖起设备屏障")
        XCTAssertNil(tokens.accessToken, "随后清理器照常执行")
    }
}
