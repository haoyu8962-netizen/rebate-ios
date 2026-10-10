import CouliNetwork
import Foundation
import ProductSearch
import Session
import XCTest

/// APP-08 iOS 第六次修复 NEW-03（S0）：购买触发的商品补齐（价格补齐、30144 重新加载）经详情页 / 搜索页执行器、SearchApi 发出时，
/// 带那次购买尝试固定的请求归属交真实 ApiClient。补齐已排队、网络首次绑定之前换成 B：零发送（不带 B 的凭据发出 A 流程留下的
/// product_key、item_ref）。对照：不换号时照常发出一次。
@MainActor
final class PurchaseRefetchOwnershipR3fTests: XCTestCase {
    /// 跨线程可变的换号开关：ApiClient 下一次读状态时把会话从 A 换成 B（退出 + 保存 B），只换一次。
    private final class Swap: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var swaps = 0
        weak var client: ApiClient?
        let tokens: MemorySessionTokens

        init(tokens: MemorySessionTokens) {
            self.tokens = tokens
        }

        func arm() {
            lock.withLock { armed = true }
        }

        var count: Int {
            lock.withLock { swaps }
        }

        func fireIfArmed() {
            let fire = lock.withLock { () -> Bool in
                guard armed else { return false }
                armed = false
                swaps += 1
                return true
            }
            guard fire else { return }
            client?.signOut()
            try? tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
        }
    }

    private func makeClient() -> (ApiClient, Swap) {
        let tokens = MemorySessionTokens(access: "at-a", refresh: "rt-a", scope: "full", account: "user-a")
        let swap = Swap(tokens: tokens)
        let client = ApiClient(
            identity: ClientIdentity(platform: "ios", appVersion: "9.9.9", build: "1", channel: "appstore"),
            context: {
                swap.fireIfArmed()
                return NetworkContext(
                    privacy: PrivacyRaw.full, environmentSettled: true, credentialsReadable: true,
                    update: UpdateRaw.supported, apiBaseURL: URL(string: "https://api.test.invalid")
                )
            },
            device: SearchStubDevice(),
            tokens: tokens,
            pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 }),
            configuration: SearchStubProtocol.configuration()
        )
        swap.client = client
        return (client, swap)
    }

    private func productRequests() -> Int {
        SearchStubProtocol.requests.filter { $0.path == "/v1/products/p1" }.count
    }

    /// 详情页补齐：排队后、网络首次绑定之前换号 → 零发送、页面卡片不变。
    func testDetailRefetchQueuedThenSwapSendsNothing() async {
        for swap in [false, true] {
            SearchStubProtocol.install { _ in SearchFixtures.ok(SearchFixtures.card("p1")) }
            let (client, switcher) = makeClient()
            let fixed = client.currentOwnership(credentialsReadable: true)
            XCTAssertEqual(fixed.account, "user-a", "前提：固定的是 A")
            let controller = ProductDetailController(
                api: client, platform: "taobao", productKey: "p1", itemRef: "ref-p1", context: { [:] }
            )
            if swap {
                switcher.arm()
            }
            controller.refetch(expected: fixed) { _, fresh in fresh }
            await settle()
            await settle()
            if swap {
                XCTAssertEqual(switcher.count, 1, "前提：换号发生在补齐排队之后、网络首次绑定之前")
                XCTAssertEqual(productRequests(), 0, "详情补齐：换号后零发送")
            } else {
                await eventually { self.productRequests() == 1 }
            }
        }
    }

    /// 搜索页列表卡补齐：排队后、网络首次绑定之前换号 → 零发送。
    func testSearchRefetchQueuedThenSwapSendsNothing() async {
        for swap in [false, true] {
            SearchStubProtocol.install { _ in SearchFixtures.ok(SearchFixtures.card("p1")) }
            let (client, switcher) = makeClient()
            let fixed = client.currentOwnership(credentialsReadable: true)
            let controller = SearchController(api: client, config: FakeSearchConfig())
            if swap {
                switcher.arm()
            }
            controller.refetchItem(productKey: "p1", itemRef: "ref-p1", expected: fixed) { _, fresh in fresh }
            await settle()
            await settle()
            if swap {
                XCTAssertEqual(switcher.count, 1, "前提：换号发生在补齐排队之后、网络首次绑定之前")
                XCTAssertEqual(productRequests(), 0, "搜索补齐：换号后零发送")
            } else {
                await eventually { self.productRequests() == 1 }
            }
        }
    }
}
