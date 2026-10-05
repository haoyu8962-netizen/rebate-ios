// 生成物，禁止手改；来源 contract.lock
// 快照：contracts/bridge.schema.json

public struct BridgeMethodSpec: Swift.Sendable, Swift.Equatable {
    public let name: Swift.String
    public let level: Swift.String
    /// 缺省或 null 为 nil。
    public let timeoutMs: Swift.Int?
    public let sinceIOS: Swift.String?
    /// 只取契约显式字段，缺省为 false。
    public let gestureRequired: Swift.Bool
}

public enum BridgeMethods {
    public static let all: [Swift.String: BridgeMethodSpec] = [
        "app.getConfig": BridgeMethodSpec(
            name: "app.getConfig", level: "L0", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "app.getEnv": BridgeMethodSpec(
            name: "app.getEnv", level: "L0", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "auth.getH5Token": BridgeMethodSpec(
            name: "auth.getH5Token", level: "L1", timeoutMs: 10000,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "auth.getUser": BridgeMethodSpec(
            name: "auth.getUser", level: "L1", timeoutMs: 10000,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "auth.login": BridgeMethodSpec(
            name: "auth.login", level: "L0", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "clipboard.read": BridgeMethodSpec(
            name: "clipboard.read", level: "L2", timeoutMs: 5000,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "clipboard.setAutoDetect": BridgeMethodSpec(
            name: "clipboard.setAutoDetect", level: "L0", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "clipboard.write": BridgeMethodSpec(
            name: "clipboard.write", level: "L0", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: true
        ),
        "cs.open": BridgeMethodSpec(
            name: "cs.open", level: "L0", timeoutMs: 10000,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "ext.openApp": BridgeMethodSpec(
            name: "ext.openApp", level: "L1", timeoutMs: 10000,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "ext.openBrowser": BridgeMethodSpec(
            name: "ext.openBrowser", level: "L0", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "ext.openMiniProgram": BridgeMethodSpec(
            name: "ext.openMiniProgram", level: "L1", timeoutMs: 10000,
            sinceIOS: nil, gestureRequired: false
        ),
        "media.previewImage": BridgeMethodSpec(
            name: "media.previewImage", level: "L0", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "media.saveImage": BridgeMethodSpec(
            name: "media.saveImage", level: "L1", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "media.scan": BridgeMethodSpec(
            name: "media.scan", level: "L1", timeoutMs: nil,
            sinceIOS: nil, gestureRequired: false
        ),
        "media.uploadImage": BridgeMethodSpec(
            name: "media.uploadImage", level: "L1", timeoutMs: nil,
            sinceIOS: nil, gestureRequired: false
        ),
        "nav.close": BridgeMethodSpec(
            name: "nav.close", level: "L0", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "nav.open": BridgeMethodSpec(
            name: "nav.open", level: "L0", timeoutMs: 10000,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "net.signedRequest": BridgeMethodSpec(
            name: "net.signedRequest", level: "L2", timeoutMs: 15000,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "perm.getPushStatus": BridgeMethodSpec(
            name: "perm.getPushStatus", level: "L0", timeoutMs: 5000,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "perm.request": BridgeMethodSpec(
            name: "perm.request", level: "L1", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "share.open": BridgeMethodSpec(
            name: "share.open", level: "L1", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "track.event": BridgeMethodSpec(
            name: "track.event", level: "L0", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "trade.authorize": BridgeMethodSpec(
            name: "trade.authorize", level: "L2", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "trade.convertAndOpen": BridgeMethodSpec(
            name: "trade.convertAndOpen", level: "L2", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "trade.openProduct": BridgeMethodSpec(
            name: "trade.openProduct", level: "L0", timeoutMs: 10000,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "trade.openUnionActivity": BridgeMethodSpec(
            name: "trade.openUnionActivity", level: "L2", timeoutMs: nil,
            sinceIOS: nil, gestureRequired: false
        ),
        "ui.hideLoading": BridgeMethodSpec(
            name: "ui.hideLoading", level: "L0", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "ui.setNavBar": BridgeMethodSpec(
            name: "ui.setNavBar", level: "L0", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "ui.showLoading": BridgeMethodSpec(
            name: "ui.showLoading", level: "L0", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
        "ui.toast": BridgeMethodSpec(
            name: "ui.toast", level: "L0", timeoutMs: nil,
            sinceIOS: "1.0.0", gestureRequired: false
        ),
    ]

    public static func spec(_ name: Swift.String) -> BridgeMethodSpec? {
        all[name]
    }
}

public enum BridgeErrors {
    /// 桥错误码 → 契约里的含义原文。
    public static let all: [Swift.Int: Swift.String] = [
        90001: "Method does not exist or is not supported",
        90002: "Invalid params",
        90003: "Timeout",
        90004: "Cancelled by the user",
        90401: "Not logged in",
        90403: "Origin or frame not allowed, method + path outside signed_paths, or the method's own whitelist rejection (methods with whitelist_90403: ext.openApp trade_only targets, ext.openBrowser addresses matching link_patterns, share.open links outside the allowed range; 03 §5.3)",
        90404: "User gesture missing",
        90500: "Native internal error; also for calls not executed under the force-update guard (03 §4.4)",
    ]
}
