import BridgeHost
import Foundation
import XCTest

/// N-22 评审 r1 S2-1 / S2-2（D10-2573 三端口径）：origin 规范形与「整数」的拒绝面逐条钉住。
/// 每条都以测试钥（env test）现签、签名有效，只改一处；每个测试先跑一组应通过的对照，证明拒绝只因那一处。
/// origin 每条都跑两种形式：单项，和「好项 + 坏项」（整份应拒，不得只留好项）。
final class BridgeOriginsCanonicalFormTests: XCTestCase {
    private let signer = FreshSigner()
    private let good = "https://h5-test.couliapp.cn"

    // MARK: - S2-1 前导 0 端口、值等于整数的小数

    func testOriginPortWithLeadingZeroRejected() throws {
        try assertOriginsAccepted(["https://a.example:8443", "https://a.example:1", "https://a.example:65535"])
        try assertOriginsRejected([
            ("端口 08443（前导 0）", "https://a.example:08443"),
            ("端口 00443（前导 0）", "https://a.example:00443"),
            ("端口 0443（前导 0，值为 443）", "https://a.example:0443"),
            ("端口 01（前导 0）", "https://a.example:01"),
            ("端口 00（全 0）", "https://a.example:00"),
        ])
    }

    /// 整数值的小数也不算整数（`1.0`、`3.0`、`3e0`、`-0.0` 等），布尔已在 FreshSign 里测过。
    func testIntegralFloatSchemaAndVersionRejected() throws {
        let controls = [FreshSigner.payload(), FreshSigner.payload(version: "0")]
        for payload in controls {
            XCTAssertTrue(isAccepted(verify(try signer.jws(payload: payload))), "对照应通过：\(payload)")
        }
        let cases: [(String, String)] = [
            ("v 为 1.0", FreshSigner.payload(schema: "1.0")),
            ("v 为 1e0", FreshSigner.payload(schema: "1e0")),
            ("v 为 1.00", FreshSigner.payload(schema: "1.00")),
            ("version 为 3.0", FreshSigner.payload(version: "3.0")),
            ("version 为 3e0", FreshSigner.payload(version: "3e0")),
            ("version 为 3E0", FreshSigner.payload(version: "3E0")),
            ("version 为 30e-1", FreshSigner.payload(version: "30e-1")),
            ("version 为 0.0", FreshSigner.payload(version: "0.0")),
            ("version 为 -0.0", FreshSigner.payload(version: "-0.0")),
            ("version 超出 Int 范围", FreshSigner.payload(version: "92233720368547758070")),
        ]
        for (label, payload) in cases {
            let verdict = verify(try signer.jws(payload: payload))
            XCTAssertFalse(isAccepted(verdict), "\(label)：应拒，实得 \(verdict)")
        }
    }

    // MARK: - S2-2 主机与端口的规范形

    func testOriginHostLabelFormRejected() throws {
        try assertOriginsAccepted([
            "https://a.example", "https://a-b.example", "https://xn--fsqu00a.cn", "https://a1.b2",
        ])
        try assertOriginsRejected([
            ("尾点", "https://a.example."),
            ("尾点带端口", "https://a.example.:8443"),
            ("空标签", "https://a..example"),
            ("首标签为空", "https://.a.example"),
            ("标签以 - 开头", "https://-a.example"),
            ("标签以 - 结尾", "https://a-.example"),
            ("中间标签以 - 开头", "https://a.-b.example"),
            ("中间标签以 - 结尾", "https://a.b-.example"),
            ("标签只有 -", "https://a.-.example"),
            ("IDN 原文主机", "https://例子.cn"),
            ("IDN 原文标签", "https://h5.例子.cn"),
            ("全角点", "https://a。example"),
            ("组合附加符", "https://e\u{301}.example"),
            ("下划线", "https://a_b.example"),
        ])
    }

    func testOriginSpecialCharactersRejected() throws {
        try assertOriginsRejected([
            ("IPv6 方括号", "https://[::1]"),
            ("IPv6 方括号带端口", "https://[::1]:8443"),
            ("百分号编码的 /", "https://a.example%2F"),
            ("百分号编码的点", "https://a%2Eexample"),
            ("反斜杠", "https://a.example\\@b"),
            ("反斜杠路径", "https://a.example\\"),
            ("userinfo 带端口", "https://u@a.example:8443"),
            ("userinfo 带口令", "https://u:p@a.example"),
            ("末尾换行", good + "\n"),
            ("末尾回车换行", good + "\r\n"),
            ("末尾 tab", good + "\t"),
            ("开头 tab", "\t" + good),
            ("中间空格", "https://a .example"),
        ])
    }

    func testOriginPortRangeAndFormRejected() throws {
        try assertOriginsRejected([
            ("端口 0", "https://a.example:0"),
            ("端口 65536", "https://a.example:65536"),
            ("端口 99999", "https://a.example:99999"),
            ("端口 6 位", "https://a.example:100000"),
            ("端口带 +", "https://a.example:+8443"),
            ("端口为负", "https://a.example:-1"),
            ("两个端口", "https://a.example:8443:1"),
            ("端口带空格", "https://a.example: 8443"),
            ("端口全角数字", "https://a.example:８４４３"),
        ])
    }

    // MARK: - 工具

    private func assertOriginsAccepted(
        _ origins: [String], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for origin in origins {
            let jws = try signer.jws(payload: FreshSigner.payload(origins: json([good, origin])))
            XCTAssertEqual(verify(jws), .accepted(BridgeOriginsAllowlist(version: 3, origins: [good, origin])),
                           "对照应通过：\(origin.debugDescription)", file: file, line: line)
        }
    }

    private func assertOriginsRejected(
        _ cases: [(String, String)], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for (label, origin) in cases {
            let single = verify(try signer.jws(payload: FreshSigner.payload(origins: json([origin]))))
            XCTAssertFalse(isAccepted(single), "\(label) \(origin.debugDescription)：单项应拒，实得 \(single)",
                           file: file, line: line)
            let mixed = verify(try signer.jws(payload: FreshSigner.payload(origins: json([good, origin]))))
            XCTAssertFalse(isAccepted(mixed), "\(label) \(origin.debugDescription)：好项 + 坏项整份应拒，实得 \(mixed)",
                           file: file, line: line)
        }
    }

    private func verify(_ jws: String) -> BridgeOriginsVerdict {
        BridgeOriginsVerifier.verify(jws: jws, appId: "couli", env: "test", lastGoodVersion: nil, keys: signer.keys)
    }

    private func json(_ origins: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: origins, options: [.withoutEscapingSlashes])) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? "[]"
    }

    private func isAccepted(_ verdict: BridgeOriginsVerdict) -> Bool {
        if case .accepted = verdict {
            return true
        }
        return false
    }
}
