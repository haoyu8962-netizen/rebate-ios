// 生成物，禁止手改；来源 contract.lock
// 快照：specs/app-stores.yaml

/// 商店对照表的一行（specs/app-stores.yaml）。key、openMethod、target 为 nil 的商店一律视为「本机打不开」
/// （APP-02c；needs N-17）。installSourcePackages 只有 Android 会填。
public struct AppStoreSpec: Swift.Sendable, Swift.Equatable {
    public let key: Swift.String?
    public let name: Swift.String
    public let platform: Swift.String
    public let channels: [Swift.String]
    public let installSourcePackages: [Swift.String]
    public let openMethod: Swift.String?
    public let target: Swift.String?
}

/// 商店对照表（规划/03 §4.1、BR-ID-01）。代码里不写死商店键与打开方式，一律查这张表。
public enum AppStores {
    public static let version = "0"

    public static let all: [AppStoreSpec] = [
        AppStoreSpec(
            key: nil,
            name: "App Store",
            platform: "ios",
            channels: ["appstore"],
            installSourcePackages: [],
            openMethod: nil,
            target: nil
        ),
        AppStoreSpec(
            key: nil,
            name: "华为应用市场",
            platform: "android",
            channels: ["huawei"],
            installSourcePackages: [],
            openMethod: nil,
            target: nil
        ),
        AppStoreSpec(
            key: nil,
            name: "鸿蒙系统应用市场",
            platform: "harmony",
            channels: ["agc"],
            installSourcePackages: [],
            openMethod: nil,
            target: nil
        ),
    ]

    /// 某一端（client_platform：ios / android / harmony）的商店。
    public static func forPlatform(_ platform: Swift.String) -> [AppStoreSpec] {
        all.filter { $0.platform == platform }
    }
}
