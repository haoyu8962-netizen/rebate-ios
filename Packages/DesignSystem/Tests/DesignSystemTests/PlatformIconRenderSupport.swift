@testable import DesignSystem
import SwiftUI
import UIKit
import XCTest

@MainActor
enum PlatformIconRenderSupport {
    struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func error(against other: Bitmap, xOffset: Int = 0, yOffset: Int = 0) -> Double {
            guard xOffset >= 0, yOffset >= 0,
                  xOffset + other.width <= width, yOffset + other.height <= height else { return .infinity }
            var total = 0
            for row in 0..<other.height {
                for column in 0..<other.width {
                    let actual = ((row + yOffset) * width + column + xOffset) * 4
                    let expected = (row * other.width + column) * 4
                    for channel in 0..<4 {
                        total += abs(Int(bytes[actual + channel]) - Int(other.bytes[expected + channel]))
                    }
                }
            }
            return Double(total) / Double(other.width * other.height * 4)
        }

        func countPixels(closeTo color: [UInt8]) -> Int {
            stride(from: 0, to: bytes.count, by: 4).filter { index in
                (0..<4).allSatisfy { abs(Int(bytes[index + $0]) - Int(color[$0])) <= 3 }
            }.count
        }
    }

    static func render(
        _ view: some View, scheme: ColorScheme = .light, scale: CGFloat = 3,
        typeSize: DynamicTypeSize = .large
    ) throws -> UIImage {
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.displayScale, scale))
        renderer.scale = scale
        return try XCTUnwrap(renderer.uiImage, "真实组件必须能渲染，不能用空图绕过")
    }

    static func bitmap(_ image: UIImage) throws -> Bitmap {
        let source = try XCTUnwrap(image.cgImage)
        let width = source.width
        let height = source.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Bitmap(width: width, height: height, bytes: bytes)
    }

    static func assertSameImage(
        _ actual: UIImage, _ expected: UIImage,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let actualBitmap = try bitmap(actual)
        let expectedBitmap = try bitmap(expected)
        XCTAssertEqual(actual.size, expected.size, file: file, line: line)
        XCTAssertEqual(actualBitmap.width, expectedBitmap.width, file: file, line: line)
        XCTAssertEqual(actualBitmap.height, expectedBitmap.height, file: file, line: line)
        XCTAssertLessThanOrEqual(actualBitmap.error(against: expectedBitmap), 1,
                                 "每通道平均误差最多 1/255；不可反色、模板着色、换图", file: file, line: line)
    }

    /// 独立参照沿用改动前的文字徽标，不经过 PlatformBadge / PlatformIcon。
    static func textBadge(_ name: String) -> some View {
        Text(verbatim: name)
            .couliFont(.caption)
            .foregroundColor(CouliColor.token("source.text"))
            .padding(.horizontal, CouliSpacing.s2)
            .frame(minHeight: CouliComponentMetric.badgeMinHeight)
            .background(Capsule().fill(CouliColor.token("source.background")))
            .overlay(Capsule().strokeBorder(
                CouliColor.token("source.border"), lineWidth: CouliComponentMetric.controlBorderWidth
            ))
            .fixedSize()
    }
}
