import Combine
import CouliNetwork
import Foundation
import WalletCore

/// 「我的」与设置共用的 Me 快照。`identity` 是这份快照所属的身份；`version` 每次内容变化加一（按钮回调带渲染时的版本）。
public struct MeSnapshot {
    public enum Phase: Equatable, Sendable {
        case idle, loading, content, error
    }

    public var identity: MeIdentity?
    public var phase: Phase = .idle
    public var me: MeProfile?
    public var error: MeNotice?
    /// 这条错误是哪个页面发起的读取得到的（R1-05：设置页只呈现自己发起的刷新失败，「我的」Tab 只消费自己的，不互相吞掉）。
    public var errorSource: ObjectIdentifier?
    public var refreshing = false
    public var version = 0

    public init(identity: MeIdentity? = nil, version: Int = 0) {
        self.identity = identity
        self.version = version
    }
}

/// 发起 Me 读取的页面（Android R1-03，共性第 21 条）：页面执行器本身就是这次进入的实例。`reading` 为 false（离页、出栈、换代）之后，它发起的
/// 读请求不再写出（含刷新后的重放）、结果不再结算；页面的同步出口调 `MeRepository.release` 取消已交给传输层的请求。
@MainActor
public protocol MeReader: AnyObject {
    var reading: Bool { get }
}

/// Me 快照（GET /v1/me；G36、G06、G05、G07，brief §2.2）：会话级、不做断网缓存（G29）。
/// - 进入 Tab、下拉、回前台、登录成功、从子页返回各取一次（页面调 `refresh`），不轮询；游客与基本模式不请求；
/// - 同类读取按请求序号只收最新一次；每次读取绑定身份（固定的网络归属）与发起页面，换代（`reset`）同步清空已显示的快照并作废在途；
/// - 昵称保存成功推进读取世代（`nicknameSaved`）：保存前发出的 getMe 晚到不把旧昵称覆盖回来；
/// - 坏数据（必填缺失、未知 risk.state）与 5xxxx 显示加载失败与【重试】，不回落到游客态；42901 按 Retry-After 禁用（执行层 + 页面）。
@MainActor
public final class MeRepository: ObservableObject {
    public static let operation = "getMe"

    @Published public private(set) var state = MeSnapshot()
    private unowned let deps: MeDeps
    private var seq = 0
    private var generation = 0
    private var ids = 0
    private let requests = MeRequests()
    /// 每个在途读取的发起页面（release 时只取消它自己的）。
    private var owners: [Int: ObjectIdentifier] = [:]
    /// 最近一次读取的发起页面（只收最新一次）。
    private weak var latest: MeReader?

    init(deps: MeDeps) {
        self.deps = deps
    }

    /// 当前快照（只给同一身份）。
    public func me(of identity: MeIdentity) -> MeProfile? {
        state.identity == identity ? state.me : nil
    }

    /// 取一次 Me。`identity` 是发起页面固定的身份：与快照的身份不同时先同步清空（换代）；已不是当前身份时不发。`page` 是发起页面（R1-03）：
    /// 读取许可绑定身份与发起页面，从实际写出一直到结果结算都核对。返回是否发出。
    @discardableResult
    public func refresh(_ identity: MeIdentity, page: MeReader, pull: Bool = false) -> Bool {
        guard page.reading else { return false }
        if state.identity != identity {
            reset(identity)
        }
        guard identity.member, deps.env.isCurrent(identity) else { return false }
        if deps.gates.read.active {
            gated(identity, source: ObjectIdentifier(page))
            return false
        }
        seq += 1
        let request = seq
        let gen = generation
        if state.me == nil {
            state.phase = .loading
            state.error = nil
        } else {
            state.refreshing = pull
        }
        let probe = deps.gates.read.probe()
        latest = page
        let pageId = ObjectIdentifier(page)
        let id = requests.send(
            deps.api, ApiCall(operationId: Self.operation), probe: probe, expected: identity.request
        ) { [weak self, weak page] result in
            guard let self else { return }
            // 被更新的读取、昵称保存、换代、发起页面离开取代：这次结果不改任何状态（含快照与限流，共性第 19、21、34、43 条）
            guard seq == request, generation == gen, state.identity == identity, deps.env.isCurrent(identity),
                  page?.reading == true
            else { return }
            arrived(result, identity: identity, probe: probe, source: pageId)
        }
        owners[id] = pageId
        return true
    }

    private func arrived(_ result: ApiResult, identity: MeIdentity, probe: SendProbe, source: ObjectIdentifier) {
        if case let .success(data, _, _) = result, let me = MeJson.me(MeJson.object(data)) {
            var next = MeSnapshot(identity: identity, version: state.version + 1)
            next.phase = .content
            next.me = me
            state = next
            return
        }
        if case .success = result {
            // code=0 却解析不了（坏数据）：加载失败态 +【重试】（不当成游客、不补默认值）
            let notice = MeNotice("error.50001", id: nextId(), traceId: result.traceIdValue, showTrace6: true)
            failed(notice, source: source)
            return
        }
        guard let notice = MeErrors.readFailure(result, probe: probe, gate: deps.gates.read, id: nextId) else {
            state.refreshing = false
            if state.me == nil, state.phase == .loading {
                state.phase = .idle
            }
            return
        }
        failed(notice, source: source)
    }

    private func nextId() -> Int {
        ids += 1
        return ids
    }

    private func gated(_ identity: MeIdentity, source: ObjectIdentifier) {
        if state.identity == identity {
            failed(MeNotice(MeCodes.rateKey, id: nextId()), source: source)
        }
    }

    /// 失败：没有快照 → 加载失败态（不回落游客）；已有快照 → 保留并给一次提示。
    private func failed(_ notice: MeNotice, source: ObjectIdentifier) {
        state.error = notice
        state.errorSource = source
        state.refreshing = false
        if state.me == nil {
            state.phase = .error
        }
        state.version += 1
    }

    /// 发起页面离开（出栈、切走 Tab，页面的同步出口）：撤销并取消它发起的读请求；它是最近一次读取时，快照回到可重新读取的状态
    /// （加载中 → 空闲）。共享快照本身保留。
    public func release(_ page: MeReader) {
        let pageId = ObjectIdentifier(page)
        let mine = owners.filter { $0.value == pageId }.map(\.key)
        for id in mine {
            owners[id] = nil
            requests.cancel(id)
        }
        if latest === page {
            latest = nil
            seq += 1
            if state.me == nil, state.phase == .loading {
                state.phase = .idle
            }
            state.refreshing = false
        }
    }

    /// 昵称保存成功（`identity` 是保存表单的固定身份）：推进读取世代并作废在途的 getMe（保存之前发出的不再覆盖），把快照里的昵称换成新值，再按
    /// 同一身份由 `page`（设置页）重取。
    public func nicknameSaved(_ identity: MeIdentity, nickname: String, page: MeReader?) {
        guard state.identity == identity, deps.env.isCurrent(identity) else { return }
        generation += 1
        seq += 1
        cancelAll()
        if let me = state.me {
            state.me = me.renamed(nickname)
            state.version += 1
        }
        if let page {
            refresh(identity, page: page)
        }
    }

    /// 已显示的错误提示消费掉（快照与错误态不变）。
    public func consumeError(_ id: Int) {
        if state.error?.id == id, state.me != nil {
            state.error = nil
        }
    }

    /// 换代（会话失效、登出、换账号、撤回同意、切换环境）：同步清空快照并作废在途。
    public func reset(_ identity: MeIdentity? = nil) {
        seq += 1
        generation += 1
        cancelAll()
        state = MeSnapshot(identity: identity, version: state.version + 1)
    }

    private func cancelAll() {
        owners = [:] // 已结束的请求留下的条目随之清掉（cancel 对已结束的请求是空操作）
        latest = nil
        requests.cancelAll()
    }

    /// 在途读取个数（测试用）。
    public var inFlight: Int {
        requests.count
    }
}

extension ApiResult {
    /// 响应里的 trace_id（成功或业务错误；其余 nil）。
    var traceIdValue: String? {
        switch self {
        case let .success(_, traceId, _): traceId
        case let .failure(_, _, _, traceId, _, _): traceId
        default: nil
        }
    }
}
