import Foundation

/// 回跳的进程内一次性收件箱（同安卓甲 `WebCodeInbox`；只在内存，不落盘）：入站方 `deliver`，等待方按 sha256(state)（UTF-8 字节的
/// 小写十六进制，`webCodeStateSha256`）`claim`。iOS 用途：onOpenURL 兜底与会话并存时的认领、孤儿交接（iOS 乙接入；甲只给接口与行为）。
/// - 回跳先到、等待后到，或等待先到、回跳后到，都能交付；只交给 state 哈希相同的等待；交付一次后，同一 state 在 `slotTtlMillis`
///   内再来的回跳丢弃。
/// - 单槽：没有等待认领的回跳放进槽位，新的覆盖旧的；state 不符的等待不吞掉它（伪造的回跳也不打断真实等待）。槽位最多保留
///   `slotTtlMillis`。
/// - 等待所在的任务被取消时当场注销，`claim` 返回 nil；回跳已交到它手里、它却没来得及拿时放回槽位。
/// 只在主线程使用。
@MainActor
public final class WebCodeInbox: WebCodeCallbackSink {
    /// 槽位与「已交付」记录的保留时长：10 分钟。
    public static let slotTtlMillis: Int64 = 10 * 60 * 1000

    private let clock: () -> Int64

    /// clock：毫秒墙钟（测试注入）。
    public init(clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.clock = clock
    }

    /// 交付一条回跳：有 state 哈希相同的等待就交给它，否则放进槽位；同一 state 已交付过（`slotTtlMillis` 内）就丢弃。
    /// TODO(FU-IOS-TB-WEBCODE-A 实现)：单槽、等待表、已交付记录。
    public func deliver(_: WebCodeCallback) {}

    /// 按 sha256(state) 认领：槽位里已有匹配的回跳就立即取走；否则挂起，直到匹配的回跳到达。所在任务被取消 → nil（并注销等待）。
    /// TODO(FU-IOS-TB-WEBCODE-A 实现)：挂起等待与取消注销。
    public func claim(stateSha256 _: String) async -> WebCodeCallback? {
        nil
    }

    /// 退出登录、切换账号、切换环境时清空槽位与已交付记录（iOS 乙接入清理链）。
    /// TODO(FU-IOS-TB-WEBCODE-A 实现)。
    public func clear() {}
}
