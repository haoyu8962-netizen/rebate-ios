import Clipboard
import Foundation
import Login

/// 首页的商品提示条（HomeClipboard；界面状态，不含剪贴板原文）。邀请提示条（HomeClipboardInvite）在用户点了系统粘贴控件、本地分类后
/// 才出现，是 `ClipboardResult.inviteConfirm`（G07）。
struct ClipboardPrompt: Equatable {
    let id: Int64
}

/// parse 或手动粘贴之后要在发起页上显示的东西（只在发起页仍是当前页时显示）。每次发布新编号（共性第 26 条），按钮回调按编号核对。
struct ClipboardResult {
    enum Kind {
        /// 轻提示（30131、30141、42901、5xxxx 带 trace6）。
        case notice(String)
        /// 30132：error.30132 加【用商品名搜索】，预填「」内或首行（G10、BR-TEXT-14）。
        case unrecognized(String, prefill: String?)
        /// 多条结果：当前页弹层按搜索卡样式列出（G09）；行内 error_code 逐条按码处理（共性第 5 条）。
        case cardList([ParseRow], traceId: String?)
        /// 网络失败（可重试的传输失败：timeout / disconnect / no_envelope）：提示 +【重试】（HomeClipboardResults-v3 ⑤），重试用本次已提取的片段。
        case networkFailed(String, retry: ParseRetry)
        /// 只有邀请内容（游客）：本地抽出的码，确认后记为待绑定码（不跳登录，APP-17c），不发请求、不持久化（G07、共性第 15 条）。
        case inviteConfirm(code: String)
    }

    let id: Int64
    let origin: String
    let kind: Kind
}

/// 一次 parse 的上传片段（本地抽出的最小候选，不是剪贴板原文）与「」标题：只随网络失败结果留在内存，供【重试】。
struct ParseRetry {
    let upload: String
    let title: String?
}

/// 主线程在每个变化出口整体替换的不可变归属快照（共性第 12 条）；网络线程的归属核对只读它，不碰界面状态与集合。
final class OwnerBox: @unchecked Sendable {
    struct Snapshot {
        var manual: Int64 = 0
        var screen: Int64 = 0
        var origin = ""
        var foreground = false
        var overlayClear = true
        var consented = false
    }

    private let lock = NSLock()
    private var value = Snapshot()

    func set(_ next: Snapshot) {
        lock.withLock { value = next }
    }

    func owns(manual: Int64, screen: Int64, origin: String) -> Bool {
        let snap = lock.withLock { value }
        return snap.manual == manual && snap.screen == screen && snap.origin == origin && snap.foreground
            && snap.overlayClear && snap.consented
    }
}

/// 进程内的商品卡种子（G09）：parse 只有 1 张卡时以这张卡打开 ProductDetail，详情与购买沿用 parse 卡的 link_id（路由参数只有 platform、
/// product_key、item_ref）。种子按路由目的地认领一次；页面出栈或进程结束即丢弃，不持久化。
@MainActor
final class ProductSeeds {
    private var waiting: [String: [String: Any]] = [:]
    private var claimed: [UUID: [String: Any]] = [:]

    func put(_ productKey: String, card: [String: Any]) {
        waiting[productKey] = card
    }

    /// 详情页（目的地 id）认领 productKey 的种子；已认领过的返回同一张。
    func claim(_ id: UUID, productKey: String) -> [String: Any]? {
        if let seed = claimed[id] {
            return seed
        }
        guard let seed = waiting.removeValue(forKey: productKey) else { return nil }
        claimed[id] = seed
        return seed
    }

    func retain(_ alive: Set<UUID>) {
        claimed = claimed.filter { alive.contains($0.key) }
    }
}
