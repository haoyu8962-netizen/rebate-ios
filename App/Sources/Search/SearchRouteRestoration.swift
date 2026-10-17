import Combine
import Foundation
import Router

/// 搜索与详情页的进程回收恢复（APP-06a 共性 20）：按路由身份（RouteDestination.id）保存页面状态，连同导航栈里从栈底起
/// 连续的 Search / ProductDetail 目的地（路由名 + 字符串参数）一起编码，随时写进本机持久化（UserDefaults，与 SceneStorage
/// 等效的保存位置；SceneStorage 在模拟器上无法用自动化稳定验证，第 2 轮改用可测的同等机制）。
///
/// 只在「上一个进程是在后台结束的」时恢复（进后台时记标记，回到前台清掉）：前台正常使用时崩溃或从头启动都不恢复。
/// 恢复时机（R2-03，03 §4.4 统一入口守卫）：页面恢复是自动执行的动作，接在 App 的启动协调上（`AppRouting` 的
/// LaunchAutoAction）——环境与隐私闸门通过、本轮强更检查有结果或等满 5 秒（按 unknown）、外壳就绪之后才执行一次，
/// 不按 App 内操作跳过检查等待。执行时导航栈仍为空才恢复：按保存的顺序以自动来源（pending_action，入口类别 in_app）
/// 逐个先过 EntryGuard，放行才经 Router 打开，并把各自保存的页面状态交给新目的地（新 id）；守卫不放行（below_min 进强更页、
/// unknown 只读清单外、隐私状态变了）就停在那里，不强行恢复。below_min 时不恢复任何业务页面。
/// 等待期间不动保存的内容（再次进后台并被结束，下次启动仍可恢复）。栈里没有搜索页时删除保存内容（出栈即结束）。
/// TODO(N-27)：iOS 没有可靠办法区分「系统回收」与「用户从多任务里划掉」（后者按规则不必恢复），这里两者都恢复。
@MainActor
final class SearchRouteRestoration: ObservableObject, LaunchAutoAction {
    /// 可恢复的路由（本任务的页面；其他路由有各自的生命周期与前置，不在这里恢复）。
    static let restorableRoutes: Set<String> = [AppSearchRoutes.search, AppSearchRoutes.productDetail]

    struct Entry: Codable, Equatable {
        let route: String
        let params: [String: String]
        /// 页面自己的状态（搜索页：SearchPageState 的编码）。
        let page: Data?
    }

    struct Saved: Codable, Equatable {
        let entries: [Entry]
    }

    static let dataKey = "couli.search.restoration.v1"
    static let backgroundKey = "couli.search.restoration.in_background"

    /// 编码后的保存内容；栈里没有可恢复页面时为空 Data。
    @Published private(set) var encoded = Data()
    private let router: Router
    private let defaults: UserDefaults
    /// 本进程启动时读到的：上一个进程是否在后台结束（才恢复）。
    private let previousEndedInBackground: Bool
    private var pageStates: [UUID: Data] = [:]
    /// 各页面「立即保存最新状态」的入口（进后台前调用，不等页面的延迟保存）。
    private var flushers: [UUID: @MainActor () -> Void] = [:]
    private var replayed = false
    private var pathObservation: AnyCancellable?
    /// 守卫此刻的状态（App 的 AppRouting.guardState）；接上启动协调前为 nil（只在测试里直接调用 replay 时出现）。
    private var guardState: (@MainActor () -> GuardState)?
    /// 进后台写完之后的显式提交（FU-IOS-0712 R1-05）：UserDefaults 的 `set` 之后异步持久化，这里同步提交一次（`synchronize`），返回是否
    /// 提交成功。测试与 Debug 的「挂住提交」开关替换它。
    var commit: @MainActor (UserDefaults) -> Bool = { $0.synchronize() }

    init(router: Router, defaults: UserDefaults = .standard) {
        self.router = router
        self.defaults = defaults
        previousEndedInBackground = defaults.bool(forKey: Self.backgroundKey)
        defaults.removeObject(forKey: Self.backgroundKey)
        pathObservation = router.$path
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.pathChanged() }
            }
    }

    /// 页面保存的状态（新建页面时取；恢复时已改挂到新目的地上）。
    func pageState(for id: UUID) -> Data? {
        pageStates[id]
    }

    /// 页面状态变化时由页面配置调用。
    func save(_ data: Data?, for id: UUID) {
        pageStates[id] = data
        recompute()
    }

    /// 页面登记「立即保存最新状态」的入口（出栈时随页面状态一起丢掉）。
    func registerFlush(for id: UUID, _ flush: @escaping @MainActor () -> Void) {
        flushers[id] = flush
    }

    func hasFlush(for id: UUID) -> Bool {
        flushers[id] != nil
    }

    /// 进后台：先让各页面取消延迟保存、同步交出最新状态（R3F-03），再记下标记（进程若在后台被结束，下次启动恢复），
    /// 并确保当前内容已写入。返回恢复内容与后台标记是否**已提交并核对**（R1-05：显式提交成功、读回与刚写的一致）；false = 提交失败
    /// 或没完成（Debug 的进后台保存完成信号据此不发）。
    @discardableResult
    func sceneEnteredBackground() -> Bool {
        for flush in flushers.values {
            flush()
        }
        guard replayed else {
            // 还在等启动协调（R2-03 等待期间保留页面状态）：保存的内容仍是上一个进程留下、还没恢复的那一份，原样保留；
            // 它本来就该恢复（上一个进程在后台结束）时把标记带下去，这次再在后台被结束，下次启动仍按它恢复。
            if previousEndedInBackground {
                defaults.set(true, forKey: Self.backgroundKey)
            }
            return committed(background: previousEndedInBackground, data: nil)
        }
        defaults.set(true, forKey: Self.backgroundKey)
        store()
        return committed(background: true, data: encoded)
    }

    /// 显式提交并核对：提交成功，且读回的后台标记（`background` 为 true 时）与恢复内容（`data` 非 nil 时；空 = 已删除）与刚写的一致。
    private func committed(background: Bool, data: Data?) -> Bool {
        guard commit(defaults) else { return false }
        if background, !defaults.bool(forKey: Self.backgroundKey) {
            return false
        }
        if let data {
            let stored = defaults.data(forKey: Self.dataKey)
            guard data.isEmpty ? stored == nil : stored == data else { return false }
        }
        return true
    }

    /// 回到前台：清掉标记。
    func sceneBecameActive() {
        defaults.removeObject(forKey: Self.backgroundKey)
    }

    /// 接上 App 的启动协调（R2-03）：登记为等启动协调的自动动作；条件早已满足时立即执行。
    func attach(to routing: AppRouting) {
        guardState = { [unowned routing] in routing.guardState }
        routing.addLaunchAutoAction(self)
    }

    // MARK: - LaunchAutoAction

    var launchActionFinished: Bool {
        replayed
    }

    /// 启动协调的条件都满足（本轮强更检查有结果，或等满 5 秒按 unknown）：只执行一次。below_min 时不恢复任何业务页面
    /// （此时外壳已进强更页）；其余按保存的内容恢复，每一页仍过守卫。
    func launchSettled(update: UpdateState) {
        guard !replayed else { return }
        if update == .belowMin {
            replay(Data())
            return
        }
        replay(previousEndedInBackground ? defaults.data(forKey: Self.dataKey) ?? Data() : Data())
    }

    /// 导航栈为空时按保存的条目依次重开：每一页以自动来源先过守卫，放行才经 Router 打开，守卫不放行就停。只做一次。
    func replay(_ data: Data) {
        guard !replayed else { return }
        replayed = true
        defer {
            // 不论恢复与否都发布一次当前内容：没恢复（栈不空、解不出、守卫不放行）时用它覆盖旧的场景状态。
            recompute(force: true)
        }
        guard router.path.isEmpty, !data.isEmpty, let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
            return
        }
        for entry in saved.entries where Self.restorableRoutes.contains(entry.route) {
            // 自动恢复不是用户在 App 内的操作：按 pending_action 来源过守卫（检查中等待、unknown 只开只读清单、
            // below_min 进强更页），不按 in_app 跳过检查等待（R2-03）。先只判定，不放行就停，不让守卫把它排进启动队列。
            let request = RouteRequest(
                route: entry.route, values: entry.params.mapValues(JSONValue.string), from: .pendingAction
            )
            if let guardState {
                let decision = EntryGuard.decide(request: request, state: guardState(), routes: router.routes)
                guard decision.opensPage, decision.route == entry.route else { break }
            }
            let before = router.path.count
            router.open(request)
            guard router.path.count == before + 1, let destination = router.path.last,
                  destination.route == entry.route
            else { break }
            if let page = entry.page {
                pageStates[destination.id] = page
            }
        }
    }

    /// 栈变化：已出栈的页面状态丢掉（出栈即结束，不再恢复），再重算保存内容。
    private func pathChanged() {
        let alive = Set(router.path.map(\.id))
        pageStates = pageStates.filter { alive.contains($0.key) }
        flushers = flushers.filter { alive.contains($0.key) }
        recompute()
    }

    private func recompute(force: Bool = false) {
        var entries: [Entry] = []
        for destination in router.path {
            guard let route = destination.route, Self.restorableRoutes.contains(route) else { break }
            var params: [String: String] = [:]
            for (key, value) in destination.params {
                if let text = value.stringValue {
                    params[key] = text
                }
            }
            entries.append(Entry(route: route, params: params, page: pageStates[destination.id]))
        }
        let data = entries.isEmpty ? Data() : (try? JSONEncoder().encode(Saved(entries: entries))) ?? Data()
        if force || data != encoded {
            encoded = data
            store()
        }
    }

    private func store() {
        guard replayed else { return }
        if encoded.isEmpty {
            defaults.removeObject(forKey: Self.dataKey)
        } else {
            defaults.set(encoded, forKey: Self.dataKey)
        }
    }
}
