import Foundation

/// 一个能力的结果：成功带 data（缺省 {}），失败带桥错误码。data 是只读的 JSON 对象（创建后不再修改）。
public struct BridgeOutcome: @unchecked Sendable {
    public let code: Int
    public let data: [String: Any]?
    /// 这次调用自己引起了会话变化（auth.login 完成登录，APP-04 共性 66、68）：本次登录保存的会话对应的归属键。结算时会话核对改为
    /// 「此刻的归属键仍是它」，不再要求与调用开始时相同——本次登录造成的账号变化不把调用作废；之后又变了（登出、再换号）照样
    /// 不交回。只对 auth.login 生效；nil = 按调用开始时的归属核对。
    public let boundAccountKey: String?

    public init(code: Int, data: [String: Any]?, boundAccountKey: String? = nil) {
        self.code = code
        self.data = data
        self.boundAccountKey = boundAccountKey
    }

    public static func ok(_ data: [String: Any] = [:]) -> BridgeOutcome {
        BridgeOutcome(code: BridgeCode.ok, data: data)
    }

    /// auth.login 完成登录：结果绑定本次登录保存的会话归属键（见 `boundAccountKey`）。
    public static func ok(_ data: [String: Any], boundAccountKey: String) -> BridgeOutcome {
        BridgeOutcome(code: BridgeCode.ok, data: data, boundAccountKey: boundAccountKey)
    }

    public static func fail(_ code: Int) -> BridgeOutcome {
        BridgeOutcome(code: code, data: nil)
    }

    /// 方法远程禁用（bridge_disabled_methods，03 §5.3 试行）的 data.reason。
    public static let methodDisabledReason = "method_disabled"

    /// 被远程禁用的方法：90403，data.reason = method_disabled（处理器不执行）。
    public static var disabled: BridgeOutcome {
        BridgeOutcome(code: BridgeCode.notAllowed, data: ["reason": methodDisabledReason])
    }
}
