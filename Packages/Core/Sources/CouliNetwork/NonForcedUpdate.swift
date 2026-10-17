import Foundation

/// 非强更的 10405（FU-IOS-0712 第 4 项，F-X-09；Android FU-AND-0715 / 鸿蒙 FU-HM-0718 同口径）：只按网络层 Effect 判断——
/// Effect 是 force_update 才进强更、用「版本过低」文案；其余在页面上一律按统一错误文案（error.50001）+ trace6 + 可重试，不进强更。
/// 到达形态（第 1 轮修复 R1-04）：refresh_only（升级前留下的受限令牌刷新成功、原请求不重放）；之后的刷新暂时失败（Effect 为
/// generic_error，不清会话）；之后的刷新被拒（Effect 为清会话，清会话与登录引导已由刷新窗口照旧执行）——三种都带原 10405 的码与 trace。
///
/// 各页面把结果交给按码分流的纯函数表（三端共用向量，不改）之前，用 `pageCode` 把非强更的 10405 换成 50001。
public enum NonForcedUpdate {
    public static let code = 10405
    /// 页面上用的码：统一错误（error.50001，5xxxx 一律带 trace6、可重试）。
    public static let unifiedCode = 50001
    public static let unifiedKey = "error.50001"

    /// 这一次失败是不是「非强更的 10405」。
    public static func applies(code: Int, effect: ErrorEffect) -> Bool {
        code == Self.code && effect.kind != .forceUpdate
    }

    /// 交给按码分流的表之前用的码。
    public static func pageCode(code: Int, effect: ErrorEffect) -> Int {
        applies(code: code, effect: effect) ? unifiedCode : code
    }
}

extension ApiClient {
    /// 非强更 10405 之后刷新失败（暂时失败 / 被拒）交给页面的结果（R1-04）：原 10405 的码、消息、data 与 trace 原样带上，Effect 不是强更。
    static func refreshFailed10405(_ envelope: Envelope, effect: ErrorEffect, idempotencyKey: String?) -> ApiResult {
        .failure(
            code: envelope.code, msg: envelope.msg, data: JSONFields.encode(envelope.data), traceId: envelope.traceId,
            effect: effect, idempotencyKey: idempotencyKey
        )
    }
}
