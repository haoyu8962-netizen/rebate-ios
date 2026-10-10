import CouliNetwork
import Foundation

/// JumpTip 已读（BR-ATTR-21：每个用户、每个平台首次外跳前展示一次，服务端记已读；getTips / markTipRead）。已读状态按会话缓存在内存，
/// 读取失败时按「未读」保守展示（多看一次须知不影响归属）。`sessionKey` 变了（换账号、退出）就重新读。
///
/// 固定归属（iOS RC-06，APP-09 共性第 39、65 条）：购买流程把获取方案时固定的请求归属 `expected` 交进来——
/// - 缓存只认**固定那一份**的账号：`sessionKey` 此刻与 `expected.account` 不同（换了账号）即零动作：不改缓存、不排队请求；
///   已读写进缓存只在缓存本来就属于此刻会话时进行，绝不把缓存重新绑定到执行时的当前会话；
/// - getTips / markTipRead 带着 `expected` 交网络层，在读取凭据、组请求后与实际写出前只比较，换代即零发送；
/// - 已排队、尚未发出的 markTipRead 在任务开始时再比较一次（`stillOwned`），不一致直接放弃。
@MainActor
public final class JumpTipService {
    private let calls: TradeCalls
    private let sessionKey: @MainActor () -> String?
    private var cachedFor: String?
    private var read: Set<String>?

    public init(api: TradeApi, sessionKey: @escaping @MainActor () -> String?) {
        calls = TradeCalls(api: api)
        self.sessionKey = sessionKey
    }

    /// 固定归属的账号仍是此刻会话的账号（只比较；没有固定归属时不比较）。
    private func stillOwned(_ expected: RequestOwnership?, _ key: String?) -> Bool {
        guard let expected else { return true }
        return key == expected.account
    }

    /// 这个平台要不要先显示下单须知。没有会话（游客）不显示（游客 open 拿 10001，不会走到这里）。
    public func shouldShow(_ platform: String, expected: RequestOwnership? = nil) async -> Bool {
        guard let key = sessionKey() else { return false }
        // 固定归属的账号已不是此刻会话：不查、不改缓存（调用方随后按来源比较作废方案）
        guard stillOwned(expected, key) else { return true }
        if cachedFor != key || read == nil {
            let call = ApiCall(operationId: TradeOperations.getTips)
            let result = await calls.send(call, group: "tips", expected: expected)
            // 等待期间换了账号：结果不写缓存（缓存只属于发起查询的那个会话）
            guard sessionKey() == key else { return true }
            cachedFor = key
            if case let .success(data, _, _) = result, let object = TJSON.parse(data) {
                let tips = TJSON.object(object["jump_tip"]) ?? [:]
                read = Set(tips.compactMap { TJSON.string($0.value) != nil ? $0.key : nil })
            } else {
                read = nil
            }
        }
        return read?.contains(platform) != true
    }

    /// 用户点了【知道了，去X】：先本地记已读，再告诉服务端（失败不影响外跳）。调用方须**先**核对方案、尝试与固定来源，再调本方法；
    /// 这里对固定归属再比较一次（账号不同即零动作），请求带固定归属交网络层，发送前再比较。
    public func markRead(_ platform: String, expected: RequestOwnership? = nil) {
        let key = sessionKey()
        guard stillOwned(expected, key) else { return }
        // 只在缓存属于此刻会话时写入已读；不属于（没读过或旧会话的）不改、不重新绑定，下次 shouldShow 重新读
        if key != nil, cachedFor == key {
            var current = read ?? []
            current.insert(platform)
            read = current
        }
        let body = TJSON.encode(["platform": platform])
        let call = ApiCall(operationId: TradeOperations.markTipRead, pathParams: ["tip_key": "jump_tip"], body: body)
        let calls = calls
        let sessionKey = sessionKey
        Task { @MainActor in
            // 排队到真正发出之间换了账号：放弃（网络层另按固定归属的世代比较）
            guard expected == nil || sessionKey() == expected?.account else { return }
            _ = await calls.send(call, group: "tips", expected: expected)
        }
    }

    /// 测试核对：此刻缓存属于哪个会话、记了哪些平台已读。
    var cacheSnapshot: (owner: String?, read: Set<String>?) {
        (cachedFor, read)
    }
}
