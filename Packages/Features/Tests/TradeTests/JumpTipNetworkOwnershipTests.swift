import CouliNetwork
import Foundation
import Session
@testable import Trade
import TradeJump
import XCTest

/// APP-08 iOS 第三次定向复核 RC-06（S0）网络层：markTipRead 带获取方案时固定的请求归属交真实 ApiClient；确认之后、首发之前换账号
/// （会话世代变了），网络层在读取凭据、组请求后与实际写出前比较拦下，零发送。服务与执行器两层的比较这里刻意都放行（会话键、来源不变），
/// 只验证网络层这一道。
@MainActor
final class JumpTipNetworkOwnershipTests: XCTestCase {
    private struct Device: DeviceCredentials {
        var deviceId: String? = "dev-1"
        var installSecret: String? = "placeholder"
    }

    private nonisolated static func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }

    private func readPosts() -> [TradeStubProtocol.Recorded] {
        TradeStubProtocol.requests.filter { $0.method == "POST" && $0.path.hasSuffix("/read") }
    }

    private struct Rig {
        let tokens: MemorySessionTokens
        let client: ApiClient
        let controller: OpenPurchaseController
        let card: TradeObject
    }

    /// 真实 ApiClient（A 已登录）+ 执行器：会话键与来源都固定不变（只让网络层这一道起作用），请求归属取 A 的。
    private func makeRig() -> Rig {
        TradeStubProtocol.install { request in
            if request.path.hasSuffix("/me/tips") {
                return .init(data: Self.json(["jump_tip": [String: String]()]))
            }
            if request.path.hasSuffix("/read") {
                return .init(data: "{}")
            }
            guard request.path.hasSuffix("/open") else { return .init() }
            return .init(data: Self.json(TradeFixtures.open()))
        }
        let tokens = MemorySessionTokens(access: "at-a", refresh: "rt-a", scope: "full", account: "user-a")
        let client = ApiClient(
            identity: ClientIdentity(platform: "ios", appVersion: "9.9.9", build: "1", channel: "appstore"),
            context: {
                NetworkContext(
                    privacy: PrivacyRaw.full, environmentSettled: true, credentialsReadable: true,
                    update: UpdateRaw.supported, apiBaseURL: URL(string: "https://api.test.invalid")
                )
            },
            device: Device(),
            tokens: tokens,
            pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 }),
            configuration: TradeStubProtocol.configuration()
        )
        let ports = FakePorts()
        ports.installedValue = TradeConstants.installedUnknown
        ports.launchResults = [true]
        let env = FakeEnv(card: TradeFixtures.card())
        let executor = TradeJumpExecutor(ports: ports, baichuan: UnavailableBaichuan(), sink: FakeSink())
        let controller = OpenPurchaseController(
            api: client, executor: executor, ports: ports, env: env, pending: MemoryPurchasePending(),
            counter: AuthSheetCounter(), tips: JumpTipService(api: client) { "user-a" }, webCode: FakeWebCode(),
            baichuan: UnavailableBaichuan(), browserNoticeMillis: 50
        )
        controller.jumpOrigin = { "origin" }
        controller.jumpSource = {
            JumpSource(origin: "origin", request: client.currentOwnership(credentialsReadable: true))
        }
        return Rig(tokens: tokens, client: client, controller: controller, card: env.card)
    }

    func testAccountSwitchAfterConfirmBeforeFirstSendIsBlockedByNetwork() async throws {
        for swap in [false, true] {
            let rig = makeRig()
            let controller = rig.controller
            controller.buy(rig.card, spm: nil)
            await eventually { controller.state.dialog == .jumpTip(platform: "taobao") }
            controller.confirm()
            if swap {
                // 已读请求已排队、尚未发出：换成 B
                rig.client.signOut()
                try rig.tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
                try await Task.sleep(nanoseconds: 300_000_000)
                XCTAssertTrue(readPosts().isEmpty, "首发前换账号：旧已读请求零发送")
            } else {
                await eventually { self.readPosts().count == 1 }
                XCTAssertEqual(readPosts().first?.headers["Authorization"], "Bearer at-a", "对照：不换账号照常带 A 的凭据发出")
            }
        }
    }
}
