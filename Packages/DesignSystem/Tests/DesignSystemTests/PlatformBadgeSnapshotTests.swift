@testable import DesignSystem
import SnapshotTesting
import SwiftUI
import XCTest

/// 基准须由实现后的真实组件录制、逐张复核；缺基准持续失败，普通运行不会自动生成基准。
@MainActor
final class PlatformBadgeSnapshotTests: XCTestCase {
    func testPlatformMatrixLightDarkAndLargeText() {
        for scheme in [ColorScheme.light, .dark] {
            for largeText in [false, true] {
                let host = VStack(alignment: .leading, spacing: 16) {
                    ForEach(PlatformIconTestFixtures.requiredCodes, id: \.self) { code in
                        HStack(spacing: 16) {
                            PlatformBadge(PlatformIconTestFixtures.names[code] ?? code, platformCode: code)
                            PlatformIcon(platformCode: code, size: .badge)
                            PlatformIcon(platformCode: code, size: .grid)
                        }
                    }
                    PlatformBadge("天猫", platformCode: "tmall")
                    PlatformBadge("未来平台", platformCode: "future-shop")
                }
                .padding(16)
                .frame(width: 320, alignment: .leading)
                .background(CouliColor.backgroundCanvas)
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, largeText ? .accessibility2 : .large)
                let name = "\(scheme == .dark ? "dark" : "light")-\(largeText ? "AX2" : "large")"
                withSnapshotTesting(record: Self.recording ? .missing : .never) {
                    assertSnapshot(of: host, as: .image(
                        precision: 0.995, perceptualPrecision: 0.98, layout: .sizeThatFits,
                        traits: UITraitCollection(preferredContentSizeCategory:
                            largeText ? .accessibilityExtraExtraLarge : .large)
                    ), named: name)
                }
            }
        }
    }

    private static var recording: Bool {
        ProcessInfo.processInfo.environment["COULI_RECORD_SNAPSHOTS"] == "1"
    }
}
