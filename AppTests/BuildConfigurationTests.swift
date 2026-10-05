import Config
@testable import Couli
import Foundation
import Security
import XCTest

/// App 单测（测试动作用 Debug 配置）。
@MainActor
final class BuildConfigurationTests: XCTestCase {
    func testDebugDefaultsToTestEnvironment() {
        XCTAssertEqual(BuildInfo.configurationName, "Debug")
        XCTAssertEqual(BuildInfo.defaultEnvironment, .test)
    }

    func testInfoPlistLocksPortraitAndLightAppearance() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.couli.app")
        XCTAssertEqual(info["UISupportedInterfaceOrientations"] as? [String], ["UIInterfaceOrientationPortrait"])
        XCTAssertEqual(info["UIUserInterfaceStyle"] as? String, "Light")
    }

    func testPrivacyManifestIsBundled() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
    }

    /// 包测试的宿主没有 Keychain 授权，在 App 宿主里再测一次 Keychain 清理。
    func testKeychainCleanerDeletesItemsUnderService() throws {
        let service = "com.couli.app.tests.\(UUID().uuidString)"
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "account",
            kSecValueData as String: Data("secret".utf8),
        ]
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)

        try KeychainServiceCleaner(service: service).cleanForEnvironmentSwitch()

        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        XCTAssertEqual(SecItemCopyMatching(lookup as CFDictionary, nil), errSecItemNotFound)
    }
}
