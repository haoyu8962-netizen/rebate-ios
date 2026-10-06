import Router
import enum Update.UpdateStatus

// Router 的 update 状态源（替换 APP-02a 的占位）。单独成文件：Router 与 Update 两个模块都有名为 UpdateState 的类型，
// 这里只从 Update 引入 UpdateStatus。
extension AppUpdate {
    /// 交给 Router（启动队列与入口守卫）的强更进度（03 §4.4）：
    /// - 已知 below_min（本机记着的、本次检查的、10405 带来的）一律 below_min；
    /// - 基本模式不发检查：其余按 unknown，不等待（BR-ID-11 细则「基本模式与强更检查」）；
    /// - 冷启动检查还没能发出（隐私未决、环境未就绪）：按检查中，从进程启动算起；
    /// - 检查中（冷启动检查，或回前台复查——本次运行之前成功过也一样，不拿旧的 ok 放行外部入口与待办恢复）：
    ///   从检查发出算起，启动队列等满 5 秒按 unknown；
    /// - 最近一次检查失败：按 unknown（不沿用旧 ok / below_recommended），直到下一次成功检查（R2-01）；
    /// - 其余按 Gate 的结论。
    var routerStatus: UpdateCheckStatus {
        let now = clock()
        let status = gate.state(now: now).status
        if status == .belowMin {
            return .finished(.belowMin)
        }
        if basicMode {
            return .finished(.unknown)
        }
        guard coldStartIssued else {
            return .checking(startedAt: launchedAt)
        }
        // 生命周期检查在途（含回前台复查）：Gate 的界面投影可以保留已知结论（rule-gaps G12），路由一律按检查中。
        if gate.isChecking, let started = checkStartedAt {
            return .checking(startedAt: started)
        }
        // 最近一次检查失败（本次运行曾成功、之后复查失败也一样）：Gate 的界面投影可保留旧结论，交给 Router 的一律按
        // unknown——外部入口只读、待办恢复受未知限制，直到下一次成功检查（编排者裁定，R2-01；rule-gaps G14）。
        // 已知 below_min 在上面已先返回。
        if gate.lastCheckFailed {
            return .finished(.unknown)
        }
        switch status {
        case .checking: return .checking(startedAt: checkStartedAt ?? now)
        case .ok: return .finished(.ok)
        case .belowRecommended: return .finished(.belowRecommended)
        case .belowMin: return .finished(.belowMin)
        case .unknown: return .finished(.unknown)
        }
    }
}
