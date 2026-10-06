import Foundation
@testable import Network
import XCTest

/// 契约快照 specs/request-sign.vectors.json（BR-ID-09 服务端与三端共用的签名向量）：
/// 有效用例比对签名串与 X-Sign；无效用例按字段原样计算的 X-Sign 也必须与向量一致（服务端据此判 10401）。
final class RequestSignVectorTests: XCTestCase {
    private typealias Object = [String: Any]

    private func vectors() throws -> Object {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw NSError(domain: "RequestSignVectors", code: 1)
            }
            directory = parent
        }
        let file = directory.appendingPathComponent("contracts/snapshot/specs/request-sign.vectors.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? Object)
    }

    private func string(_ row: Object, _ key: String) throws -> String {
        try XCTUnwrap(row[key] as? String, "missing \(key)")
    }

    func testValidCases() throws {
        let rows = try XCTUnwrap(vectors()["valid_cases"] as? [Object])
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let note = try string(row, "note")
            let text = try RequestSigner.signingString(
                method: string(row, "method"),
                pathWithQuery: string(row, "path"),
                timestamp: string(row, "timestamp"),
                nonce: string(row, "nonce"),
                body: Data(string(row, "body_utf8").utf8)
            )
            XCTAssertEqual(text, try string(row, "expected_signing_string"), note)
            let sign = try RequestSigner.sign(installSecret: string(row, "install_secret"), signingString: text)
            XCTAssertEqual(sign, try string(row, "expected_sign"), note)
            let headers = try RequestSigner.headers(
                installSecret: string(row, "install_secret"),
                signingString: text,
                timestamp: string(row, "timestamp"),
                nonce: string(row, "nonce")
            )
            XCTAssertEqual(headers[HeaderNames.sign], try string(row, "expected_sign"), note)
            XCTAssertEqual(headers[HeaderNames.timestamp], try string(row, "timestamp"), note)
            XCTAssertEqual(headers[HeaderNames.nonce], try string(row, "nonce"), note)
        }
    }

    func testInvalidCasesSignFieldsVerbatim() throws {
        let rows = try XCTUnwrap(vectors()["invalid_cases"] as? [Object])
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let note = try string(row, "note")
            let text = try RequestSigner.signingString(
                method: string(row, "method"),
                pathWithQuery: string(row, "path"),
                timestamp: string(row, "timestamp"),
                nonce: string(row, "nonce"),
                body: Data(string(row, "body_utf8").utf8)
            )
            let sign = try RequestSigner.sign(installSecret: string(row, "install_secret"), signingString: text)
            XCTAssertEqual(sign, try string(row, "expected_sign"), note)
        }
    }

    func testNonceAndTimestampFormat() {
        let nonce = RequestSigner.nonce()
        XCTAssertEqual(nonce.count, 32)
        XCTAssertTrue(nonce.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertNotEqual(nonce, RequestSigner.nonce())
        XCTAssertEqual(RequestSigner.timestamp(nowMillis: 1_790_661_600_999), "1790661600")
    }
}
