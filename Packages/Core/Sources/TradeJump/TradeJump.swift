import Foundation

/// TradeJump 模块（APP-06b）：联盟 SDK 的适配层。本任务不引入任何联盟 SDK（任务书 §2.3：百川、京东、拼多多 SDK 均不引入），
/// 只有接口与「不可用」实现；跳转方案执行器在 Core 的 Trade 模块。
public enum TradeJumpModule {}

/// 百川拉起结果（BR-ATTR-27 淘宝行）。
public enum BaichuanOpenResult: Sendable, Equatable {
    case launched
    /// SDK 没有初始化成功（重试后仍失败）：记 sdk_init_failed，执行下一步。
    case initFailed
    case failed
}

/// 百川授权换令牌的结果（BR-ID-17 细则「授权方式」sdk_token）。
public enum BaichuanAuthResult: Sendable, Equatable {
    case token(accessToken: String, expiresIn: Int64)
    case cancelled
    case failed
}

/// 百川（阿里百川 / 淘宝联盟 SDK）适配层（03 §3.5、BR-ATTR-27）。初始化只能由 PrivacyGate.onConsented 的联盟步骤调用
/// （03 §4.1、AGENTS.md 硬规则 5）；初始化失败后，下一次执行 sdk 步骤前重试 1 次（BR-ATTR-27 淘宝行）。
@MainActor
public protocol BaichuanAdapter: AnyObject {
    /// 初始化成功、可用。
    var ready: Bool { get }
    /// 能用 SDK 授权换 access_token（sdk_token 方式）。
    var supportsSdkToken: Bool { get }
    /// 同意隐私后的初始化（PrivacyGate 联盟步骤）。返回是否成功。
    func initialize() -> Bool
    /// 之前初始化失败过：重试 1 次（每次 sdk 步骤前最多 1 次）。返回此刻是否可用。
    func retryInitIfFailed() -> Bool
    /// 用 SDK 打开推广链接（sdk 步骤的 value 原样交给 SDK）。
    func open(_ value: String) -> BaichuanOpenResult
    /// SDK 授权（sdk_token）。
    func authorize() async -> BaichuanAuthResult
}

/// 生产实现：没有百川 SDK、没有 AppKey（负责人未给，TODO(N-28)：AppKey 用占位，记 rule-gaps I-段），初始化一律失败。
/// sdk 步骤因此记 sdk_init_failed 并降级到下一步；sdk_token 授权不可用。
@MainActor
public final class UnavailableBaichuan: BaichuanAdapter {
    /// TODO(N-28)：负责人提供百川 AppKey 后替换（不臆造）。
    public static let appKeyPlaceholder = "BAICHUAN_APP_KEY_PLACEHOLDER"

    public private(set) var initAttempts = 0
    public private(set) var initialized = false
    private var failedBefore = false

    public init() {}

    public var ready: Bool {
        false
    }

    public var supportsSdkToken: Bool {
        false
    }

    public func initialize() -> Bool {
        initAttempts += 1
        initialized = true
        failedBefore = true
        return false
    }

    public func retryInitIfFailed() -> Bool {
        guard failedBefore || !initialized else { return false }
        initAttempts += 1
        initialized = true
        failedBefore = true
        return false
    }

    public func open(_: String) -> BaichuanOpenResult {
        .initFailed
    }

    public func authorize() async -> BaichuanAuthResult {
        .failed
    }
}
