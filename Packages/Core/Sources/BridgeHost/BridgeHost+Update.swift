import Foundation

/// BridgeHost 的强更状态绑定（APP-04 三端共性第 4、63、65 条）。
extension BridgeHost {
    /// 执行前绑定「此刻这一轮」版本检查的结论（APP-04 三端共性第 63、65 条）。收到调用时记下的状态只是起点：
    /// - 检查中：最多等 5 秒（`awaitUpdate`），到时按未知；
    /// - 每次等待之后、执行任何副作用之前再核对一次归属（第 4 条）：宿主世代、隐私状态与账号都没变才继续；
    /// - 再读一次当前状态：与绑定的一致（或仍是刚等满 5 秒的那一轮检查中）才按它执行；其间开始了新一轮检查就重新等这一轮，
    ///   已有新结论就按新结论再核对一次。状态反复变化到上限仍没稳定的，取消（90500），不排队、不补执行。
    /// 返回 nil = 不执行。
    func bindCurrentUpdate(_ state: BridgeCallerState, generation started: UInt64) async -> String? {
        var update = state.update
        var waitedOut = false
        for _ in 0..<Self.updateBindAttempts {
            if update == BridgeUpdateState.checking {
                update = await awaitUpdate()
                waitedOut = update == BridgeUpdateState.unknown
            }
            guard !Task.isCancelled, stillOwned(generation: started, state: state) else {
                return nil
            }
            let current = caller().update
            if current == update || (current == BridgeUpdateState.checking && waitedOut) {
                return update
            }
            update = current
            waitedOut = false
        }
        return nil
    }

    /// 绑定版本检查轮次的最多次数（每次至多等 5 秒；超过仍在变化就取消，三端共性第 63 条）。
    static let updateBindAttempts = 3
}
