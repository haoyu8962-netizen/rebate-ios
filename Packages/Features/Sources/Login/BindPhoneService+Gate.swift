import CouliNetwork
import Foundation

/// phoneGate（会话级写闸门，APP-13a 共性第 8 条）：提交、确认、放弃共用一份 42901 截止时间；按记下它的固定归属隔离（第 1 轮 R1-09），
/// 归属变更时在同步出口清掉（从 BindPhoneService.swift 拆出）。
extension BindPhoneService {
    /// `owner` 此刻在 phoneGate 禁用期（只认同一固定归属记下的禁用期；纯读取，页面渲染可调）。提交、确认、放弃三个入口共用。
    public func writeGated(_ owner: BindPhoneOwner) -> Bool {
        gateOwner == owner.request && gate.active
    }

    /// 请求归属变更的同步出口（App：会话状态同步时调；R1-09）：上一个归属记下的禁用期不带给新会话。
    public func ownershipChanged() {
        if let gateOwner, gateOwner != identity().request {
            clearGate()
        }
    }

    /// 发送入口：当前归属不是记下禁用期的归属时先清掉（旧会话留下的禁用期不拦新会话）。
    func isolateGate(_ owner: BindPhoneOwner) {
        if let gateOwner, gateOwner != owner.request {
            clearGate()
        }
    }

    private func clearGate() {
        gateOwner = nil
        gate.reset()
    }

    /// 42901 结算：按固定归属记下禁用期（旧响应已在 `settle` 核对归属，不会限制新会话）。
    func startGate(_ owner: BindPhoneOwner, millis: Int64) {
        isolateGate(owner)
        gateOwner = owner.request
        gate.start(millis)
    }
}
