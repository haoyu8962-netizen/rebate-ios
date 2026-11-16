import Combine
import Foundation

/// 个性化切换的应用级同步状态（D10-1838，评审 S2-1 / S2-3）：App 建一份、各页共用（同 `MeWithdrawState`），隐私中心执行器重建后继承。
/// - `pending`：同意记录在途（全 App 一次只一条）；在途时任何页面的个性化开关都不受理、显示不可用。
/// - 切换序号：每次切换（含没发出的）在主线程上递增；失败回来只有「仍是最近一次切换」才回滚。不靠回读盘上的切换时刻——写盘失败、
///   离页重开另一个页面都成立。只在内存，换身份、退出登录不需要清（序号只比大小；`pending` 随在途请求结束复位）。
@MainActor
public final class MePersonalizationSync: ObservableObject {
    @Published public private(set) var pending = false
    /// 每结束一条在途就加一：各页面据此按本机值重读开关（失败回滚可能发生在别的页面发起的请求上，评审 r2 S2-A）。
    @Published public private(set) var settled = 0
    private var serial = 0

    public init() {}

    /// 记一次切换，返回它的序号。
    func toggled() -> Int {
        serial += 1
        return serial
    }

    /// 这次切换之后没有别的切换（防御：在途期间全 App 不受理切换、结束与失败处理之间没有挂起点，生产里恒成立）。
    func isLatest(_ toggle: Int) -> Bool {
        toggle == serial
    }

    func begin() {
        pending = true
    }

    func end() {
        pending = false
        settled += 1
    }
}
