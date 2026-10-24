import BridgeHost
import Foundation
import XCTest

/// 三端 vectors.md 原样 JSON；不在夹具里实现判定，也不以缺接口为跳过条件。
final class FX25AuthChangeDecisionTests: XCTestCase {
    private struct Identity: Decodable {
        let known: Bool
        let account: String?
        let loginEpoch: String?

        var input: WebSessionIdentity {
            WebSessionIdentity(known: known, account: account, loginEpoch: loginEpoch)
        }
    }

    private struct Vector: Decodable {
        let id: String
        let prev: Identity
        let next: Identity
        let expected: String
        let loggedIn: Bool?
    }

    private struct Vectors: Decodable {
        let cases: [Vector]
    }

    func testD01ThroughD10UseVerbatimSharedVectors() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            root.deleteLastPathComponent()
        }
        let data = try Data(contentsOf: root.appendingPathComponent("specs/fx25-auth-change-vectors.json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let vectors = try decoder.decode(Vectors.self, from: data)
        XCTAssertEqual(vectors.cases.count, 10)
        for vector in vectors.cases {
            let decision = AuthChangeDecision.decide(previous: vector.prev.input, next: vector.next.input)
            XCTAssertEqual(decision.rawValue, vector.expected, vector.id)
            XCTAssertEqual(decision.loggedIn, vector.loggedIn, vector.id)
        }
    }

    func testD11ScopeIsNotAnIdentityField() {
        // scope 在生产入口的真实刷新用例再验证；纯函数输入刻意不接收 scope / access / refresh。
        let identity = WebSessionIdentity(known: true, account: "user-a", loginEpoch: "epoch-a")
        XCTAssertEqual(AuthChangeDecision.decide(previous: identity, next: identity).rawValue, "none")
    }

    func testContractPayloadIsExactlyOneBoolean() throws {
        for loggedIn in [true, false] {
            let text = try XCTUnwrap(BridgeProtocol.event(name: "auth.changed", data: ["logged_in": loggedIn]))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let payload = try XCTUnwrap(object["data"] as? [String: Any])
            XCTAssertEqual(Set(payload.keys), ["logged_in"])
            XCTAssertEqual(payload["logged_in"] as? Bool, loggedIn)
        }
    }
}
