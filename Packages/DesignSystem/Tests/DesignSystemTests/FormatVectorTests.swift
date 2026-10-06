// FILE: Packages/DesignSystem/Tests/DesignSystemTests/FormatVectorTests.swift
@testable import DesignSystem
import Foundation
import XCTest

private struct FormatVectors: Decodable {
    let version: Int
    let source: String
    let gaps: [String]
    let cases: FormatCases
}

private struct FormatCases: Decodable {
    let money: [MoneyVector]
    let moneySigned: [MoneyVector]
    let rebateRange: [RangeVector]
    let timeListPast: [TimeVector]
    let timeListFuture: [TimeVector]
    let dateOnly: [DateVector]
    let timeMinute: [MinuteVector]
    let priceTag: [ModelVector<PriceInput, PriceExpected>]
    let rebateTag: [ModelVector<RebateInput, RebateExpected>]
    let estNet: [ModelVector<EstNetInput, String?>]
    let buyButton: [ModelVector<BuyInput, String>]

    var counts: [Int] {
        [
            money.count, moneySigned.count, rebateRange.count,
            timeListPast.count, timeListFuture.count, dateOnly.count,
            timeMinute.count, priceTag.count, rebateTag.count,
            estNet.count, buyButton.count,
        ]
    }
}

private struct MoneyVector: Decodable {
    let fen: Int64
    let expect: String
    let note: String
}

private struct RangeVector: Decodable {
    let minFen: Int64
    let maxFen: Int64
    let expect: String?
    let note: String
}

private struct TimeVector: Decodable {
    let epochMillis: Int64
    let nowEpochMillis: Int64
    let expect: String
    let note: String
}

private struct DateVector: Decodable {
    let isoDate: String
    let nowEpochMillis: Int64
    let expect: String
    let note: String
}

private struct MinuteVector: Decodable {
    let epochMillis: Int64
    let expect: String
    let note: String
}

private struct ModelVector<Input: Decodable, Expected: Decodable>: Decodable {
    let input: Input
    let expect: Expected
    let note: String
}

private struct PriceInput: Decodable {
    let platform: String
    let priceFen: Int64
    let couponFen: Int64
    let finalPriceFen: Int64
    let isPresale: Bool
}

private struct PriceExpected: Decodable {
    let mainLabel: String
    let mainAmount: String
    let subLine: String?
    let noCoupon: Bool
    let presaleLabel: String?
}

private struct RebateInput: Decodable {
    let basis: String
    let minFen: Int64?
    let maxFen: Int64?
    let loginRequired: Bool
}

private struct RebateExpected: Decodable {
    let kind: String
    let text: String
}

private struct EstNetInput: Decodable {
    let basis: String
    let minFen: Int64?
    let estNetPriceFen: Int64?
}

private struct BuyInput: Decodable {
    let base: String
    let rebate: RebateExpected
    let amountHidden: Bool
    let context: String
}

final class FormatVectorTests: XCTestCase {
    func testMoney() throws {
        let cases = try loadVectors().cases
        for (index, row) in cases.money.enumerated() {
            XCTAssertEqual(
                CouliFormat.money(fen: row.fen),
                row.expect,
                label("money", index, row.note)
            )
        }
        for (index, row) in cases.moneySigned.enumerated() {
            XCTAssertEqual(
                CouliFormat.moneySigned(fen: row.fen),
                row.expect,
                label("moneySigned", index, row.note)
            )
        }
    }

    func testRebateRange() throws {
        let rows = try loadVectors().cases.rebateRange
        for (index, row) in rows.enumerated() {
            XCTAssertEqual(
                CouliFormat.rebateRange(minFen: row.minFen, maxFen: row.maxFen),
                row.expect,
                label("rebateRange", index, row.note)
            )
        }
    }

    func testTimesIgnoreDeviceTimeZone() throws {
        let cases = try loadVectors().cases
        // 修改仅限测试进程，并在失败或抛错时恢复。
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        for zone in ["UTC", "America/Los_Angeles", "Asia/Tokyo", "Asia/Shanghai"] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: zone))

            for (index, row) in cases.timeListPast.enumerated() {
                XCTAssertEqual(
                    CouliFormat.timeListPast(
                        epochMillis: row.epochMillis,
                        nowEpochMillis: row.nowEpochMillis
                    ),
                    row.expect,
                    label("timeListPast@\(zone)", index, row.note)
                )
            }
            for (index, row) in cases.timeListFuture.enumerated() {
                XCTAssertEqual(
                    CouliFormat.timeListFuture(
                        epochMillis: row.epochMillis,
                        nowEpochMillis: row.nowEpochMillis
                    ),
                    row.expect,
                    label("timeListFuture@\(zone)", index, row.note)
                )
            }
            for (index, row) in cases.dateOnly.enumerated() {
                XCTAssertEqual(
                    CouliFormat.dateOnly(
                        isoDate: row.isoDate,
                        nowEpochMillis: row.nowEpochMillis
                    ),
                    row.expect,
                    label("dateOnly@\(zone)", index, row.note)
                )
            }
            for (index, row) in cases.timeMinute.enumerated() {
                XCTAssertEqual(
                    CouliFormat.timeMinute(epochMillis: row.epochMillis),
                    row.expect,
                    label("timeMinute@\(zone)", index, row.note)
                )
            }
        }
    }

    func testPriceTag() throws {
        let rows = try loadVectors().cases.priceTag
        for (index, row) in rows.enumerated() {
            let input = row.input
            let message = label("priceTag", index, row.note)
            let actual = PriceTagModel.make(
                platform: input.platform,
                priceFen: input.priceFen,
                couponFen: input.couponFen,
                finalPriceFen: input.finalPriceFen,
                isPresale: input.isPresale
            )
            XCTAssertEqual(actual.mainLabel, row.expect.mainLabel, "\(message): mainLabel")
            XCTAssertEqual(actual.mainAmount, row.expect.mainAmount, "\(message): mainAmount")
            XCTAssertEqual(actual.subLine, row.expect.subLine, "\(message): subLine")
            XCTAssertEqual(actual.noCoupon, row.expect.noCoupon, "\(message): noCoupon")
            XCTAssertEqual(actual.presaleLabel, row.expect.presaleLabel, "\(message): presaleLabel")
        }
    }

    func testRebateTag() throws {
        let rows = try loadVectors().cases.rebateTag
        for (index, row) in rows.enumerated() {
            assertRebate(
                makeRebate(row.input),
                equals: row.expect,
                message: label("rebateTag", index, row.note)
            )
        }
    }

    func testEstNet() throws {
        let rows = try loadVectors().cases.estNet
        for (index, row) in rows.enumerated() {
            XCTAssertEqual(
                EstNetModel.make(
                    basis: row.input.basis,
                    minFen: row.input.minFen,
                    estNetPriceFen: row.input.estNetPriceFen
                ),
                row.expect,
                label("estNet", index, row.note)
            )
        }
    }

    func testBuyButton() throws {
        let cases = try loadVectors().cases
        for (index, row) in cases.buyButton.enumerated() {
            let message = label("buyButton", index, row.note)
            let rebate = try rebateFixture(
                row.input.rebate,
                rows: cases.rebateTag,
                message: message
            )
            XCTAssertEqual(
                BuyButtonModel.text(
                    base: row.input.base,
                    rebate: rebate,
                    amountHidden: row.input.amountHidden,
                    context: row.input.context
                ),
                row.expect,
                message
            )
        }
    }

    private func makeRebate(_ input: RebateInput) -> RebateTagContent {
        RebateTagModel.make(
            basis: input.basis,
            minFen: input.minFen,
            maxFen: input.maxFen,
            loginRequired: input.loginRequired
        )
    }

    private func assertRebate(
        _ actual: RebateTagContent,
        equals expected: RebateExpected,
        message: String
    ) {
        // kind 可为 String 或枚举；稳定的字符串契约为 kindRaw。
        _ = actual.kind
        XCTAssertEqual(actual.kindRaw, expected.kind, "\(message): kindRaw")
        XCTAssertEqual(actual.text, expected.text, "\(message): text")
    }

    private func rebateFixture(
        _ expected: RebateExpected,
        rows: [ModelVector<RebateInput, RebateExpected>],
        message: String
    ) throws -> RebateTagContent {
        // §3 未规定 RebateTagContent 构造器；从同一文件的独立向量创建并核对。
        let row = try XCTUnwrap(
            rows.first {
                $0.expect.kind == expected.kind && $0.expect.text == expected.text
            },
            "\(message): 缺少匹配的 rebateTag 夹具"
        )
        let actual = makeRebate(row.input)
        assertRebate(actual, equals: expected, message: "\(message): rebate fixture")
        return actual
    }

    private func label(_ group: String, _ index: Int, _ note: String) -> String {
        XCTAssertFalse(note.isEmpty, "\(group)[\(index)]: note 不能为空")
        return "\(group)[\(index)]: \(note)"
    }

    private func loadVectors() throws -> FormatVectors {
        let root = try repositoryRoot()
        let url = root.appendingPathComponent("specs/format-vectors.json")
        // 金额直接解码为 Int64，禁止通过 Double/NSNumber.doubleValue 中转。
        let vectors = try JSONDecoder().decode(
            FormatVectors.self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(vectors.version, 1, url.path)
        XCTAssertFalse(vectors.source.isEmpty, "\(url.path): source")
        XCTAssertTrue(
            vectors.cases.counts.allSatisfy { $0 > 0 },
            "\(url.path): 每类向量必须非空"
        )
        return vectors
    }

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .standardizedFileURL
        while true {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("contract.lock").path
            ) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                throw NSError(
                    domain: "FormatVectorTests",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "从 \(#filePath) 向上找不到含 contract.lock 的仓库根目录",
                    ]
                )
            }
            directory = parent
        }
    }
}
