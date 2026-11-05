import Foundation
import Generated
import XCTest
@testable import Router

/// CT-LOCK-02（契约升版到 rebate-platform a7c9f1f）：routes.json 的 Agreement 参数改形状——type 枚举加 labor_agreement、新增可选
/// version（integer，minimum 1）。生成器转写 minimum，统一入口守卫按它校验；原有三种 type 照常通过，越界、类型不符仍拒绝。
final class CtLock02AgreementRouteParamsTests: XCTestCase {
    private func spec() throws -> RouteSpec {
        try XCTUnwrap(Routes.spec("Agreement"))
    }

    private func valid(_ params: [String: JSONValue]) throws -> Bool {
        RouteParamValidator.isValid(params, spec: try spec())
    }

    func testGeneratedSpecCarriesTheNewShape() throws {
        let spec = try spec()
        // #24 test-change（升锁 00deded0ef6f）：routes.json 的 Agreement.type 枚举追加 collect_list（安卓 T4 同口径）
        XCTAssertEqual(
            spec.param("type")?.enumValues, ["agreement", "privacy", "sdk_list", "labor_agreement", "collect_list"]
        )
        let version = try XCTUnwrap(spec.param("version"))
        XCTAssertEqual(version.type, .integer)
        XCTAssertEqual(version.minimum, 1)
        XCTAssertFalse(spec.additionalParams)
        XCTAssertEqual(spec.requiredParams, [])
    }

    /// 本端现有调用（设置页、隐私中心只传 type）照常通过。
    func testExistingCallsStillPass() throws {
        for type in ["agreement", "privacy", "sdk_list"] {
            XCTAssertTrue(try valid(["type": .string(type)]), type)
        }
        XCTAssertTrue(try valid([:]))
    }

    func testNewOptionalVersionAndLaborType() throws {
        XCTAssertTrue(try valid(["type": .string("labor_agreement")]))
        XCTAssertTrue(try valid(["type": .string("privacy"), "version": .integer(1)]))
        XCTAssertTrue(try valid(["type": .string("privacy"), "version": .integer(3)]))
        XCTAssertTrue(try valid(["version": .number(2)]), "整数值的 number 按 integer")
    }

    func testVersionBelowMinimumOrWrongTypeIsRejected() throws {
        XCTAssertFalse(try valid(["version": .integer(0)]))
        XCTAssertFalse(try valid(["version": .integer(-1)]))
        XCTAssertFalse(try valid(["version": .number(0.0)]))
        XCTAssertFalse(try valid(["version": .number(1.5)]), "非整数")
        XCTAssertFalse(try valid(["version": .string("3")]), "字符串不是 integer")
        XCTAssertFalse(try valid(["type": .string("unknown")]))
        XCTAssertFalse(try valid(["type": .string("privacy"), "extra": .string("x")]), "additionalProperties false")
    }

    /// minimum 只约束数值：别的路由参数（没有 minimum）不受影响。
    func testMinimumIsOnlyOnAgreementVersion() {
        let withMinimum = Routes.all
            .flatMap { name, spec in spec.params.filter { $0.minimum != nil }.map { "\(name).\($0.name)" } }
        XCTAssertEqual(withMinimum, ["Agreement.version"])
    }
}
