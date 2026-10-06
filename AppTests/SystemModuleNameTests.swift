import CouliNetwork
import Network
import XCTest

/// R2-02：业务网络模块不能与系统框架同名。旧的业务模块叫 Network 时，它的 swiftmodule 放在共享产物目录里，
/// 同一构建里 `import Network` 会解析到业务模块（SnapshotTesting 按 iOS 15 编译时因此失败）。
/// 这里同时导入系统 Network 与业务 CouliNetwork：系统框架的类型可用，业务类型也可用，两者不冲突。
final class SystemModuleNameTests: XCTestCase {
    func testSystemNetworkFrameworkResolvesAlongsideBusinessModule() {
        let monitor = NWPathMonitor()
        monitor.cancel()
        XCTAssertEqual(String(describing: NWPathMonitor.self), "NWPathMonitor")
        XCTAssertEqual(LocalRejectReason.callCancelled, "call_cancelled")
    }
}
