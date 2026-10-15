import Foundation

// APP-12「我的」、设置、隐私中心的纯规则（三端同名；向量 specs/me-vectors.json）。只做判定与数据整理，不发请求、不碰系统接口；页面与执行器
// 按这里的结论渲染与分流（昵称、封禁说明、申诉、客服、关于、10006 与本机数据的规则在同目录各文件）。规则空白一律按 NATIVE/APP-12/rule-gaps.md「现在的做法」，标 TODO(N-33)。

/// 身份档（「我的」、设置、隐私中心按它裁剪条目）。
public enum MeLevel {
    public static let basic = "basic"
    public static let guest = "guest"
    public static let member = "member"
}

/// 端。
public enum MePlatform {
    public static let ios = "ios"
    public static let android = "android"
    public static let harmony = "harmony"
}

let hourMillis: Int64 = 60 * 60 * 1000
let dayMillis: Int64 = 24 * hourMillis
