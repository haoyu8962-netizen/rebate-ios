import Foundation
import Generated
@testable import Network
import XCTest

/// FU-IOS-WITHDRAW-REQUIRES-DEVICE-ID（编排 D10-1940 ③，三端统一口径）纯函数层：`RequestHeaderPolicy.decide` 对
/// recordConsent 的隐私撤回体（type=privacy、accepted=false）在读不出设备标识（deviceId nil / 空串）时本地拒 device_not_ready、
/// 零发送；读得出照发且带 X-Device-Id、不带签名头。其余 recordConsent 请求体与改动前一致；基本模式 / 凭据不可读 / 未决 / 环境未就绪
/// 仍是原来的拒绝原因，不被新分支抢先。
///
/// 「改动前」期望值的推导依据（Packages/Core/Sources/CouliNetwork/RequestHeaderPolicy.swift，改动前即去掉 143–148 行的新分支）：
/// - 122–125：privacy=full 且 credentialsReadable=true → privacy 仍是 full；126–137：环境就绪、full 不进 basic / undecided 分支；
///   scopeAllows(full) 只看 recordConsent.sessionScopes 含 full（Generated/ApiOperations.swift recordConsent：
///   sessionScopes ["full","deletion_only"]、signed false、auth optional、POST）→ 放行；
/// - 139：credentials=true 时 deviceId 取 state.deviceId，空串按 nil；140：recordConsent signed=false，不走 device_not_ready；
/// - 149：authorization = credentials && hasAccessToken && auth("optional") != "none"；
///   150–162：anonymous + [Authorization] + [X-Device-Id 当 deviceId 非 nil]
///   + [Idempotency-Key：POST、不在 noIdempotencyKey]；不签名不加签名头。
/// - deletion_only（170–185）：recordConsent 要请求体，restrictedBodyAllows 98–100：accepted==false 或 type 是 privacy / agreement
///   即放行；没有请求体 → session_scope_denied。
final class FuIosWithdrawRequiresDeviceIdPolicyTests: XCTestCase {
    static let privacyWithdraw =
        "{\"accepted\":false,\"channel\":\"privacy_center\",\"client_at\":\"2026-11-18T09:30:00+08:00\","
            + "\"type\":\"privacy\",\"version\":3}"
    static let privacyAccept =
        "{\"accepted\":true,\"channel\":\"privacy_center\",\"client_at\":\"2026-11-18T09:30:00+08:00\","
            + "\"type\":\"privacy\",\"version\":3}"
    static let agreementWithdraw =
        "{\"accepted\":false,\"channel\":\"privacy_center\",\"client_at\":\"2026-11-18T09:30:00+08:00\","
            + "\"type\":\"agreement\",\"version\":3}"
    static let aiWithdraw =
        "{\"accepted\":false,\"channel\":\"privacy_center\",\"client_at\":\"2026-11-18T09:30:00+08:00\","
            + "\"type\":\"ai_third_party\",\"version\":3}"

    private func operation() throws -> ApiOperation {
        try XCTUnwrap(ApiOperations.byId("recordConsent"))
    }

    /// 请求体按 ApiClient.prepare 同一写法解析（JSONFields.object，ApiClient+Prepare.swift:43），accepted 是真正的 JSON 布尔。
    private func body(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONFields.object(text), text)
    }

    private func state(
        privacy: String = PrivacyRaw.full, scope: String = "full", hasAccessToken: Bool = true,
        deviceId: String?, settled: Bool = true, readable: Bool = true
    ) -> NetworkRequestState {
        NetworkRequestState(
            privacy: privacy, sessionScope: scope, hasAccessToken: hasAccessToken, deviceId: deviceId,
            environmentSettled: settled, credentialsReadable: readable
        )
    }

    private func decide(_ state: NetworkRequestState, _ text: String?) throws -> HeaderDecision {
        RequestHeaderPolicy.decide(state: state, operation: try operation(), body: try text.map { try body($0) })
    }

    private func sentWithoutDevice(authorization: Bool) -> HeaderDecision {
        HeaderDecision(
            send: true, localRejectReason: nil,
            headerNames: HeaderNames.anonymous + (authorization ? [HeaderNames.authorization] : [])
                + [HeaderNames.idempotencyKey],
            includeAuthorization: authorization, includeDeviceId: false
        )
    }

    // MARK: - 1. 新分支：读不出设备标识 → device_not_ready

    /// P1. 已同意、凭据可读、会话 full、deviceId nil / 空串（有无令牌都一样）× 隐私撤回体 → send=false、device_not_ready、不带任何头。
    func testPrivacyWithdrawWithoutDeviceIdIsRejectedDeviceNotReady() throws {
        for deviceId in [nil, ""] as [String?] {
            for token in [true, false] {
                let label = "deviceId=\(deviceId.map { "\"\($0)\"" } ?? "nil") 令牌=\(token)"
                let decision = try decide(state(hasAccessToken: token, deviceId: deviceId), Self.privacyWithdraw)
                XCTAssertFalse(decision.send, label)
                XCTAssertEqual(decision.localRejectReason, LocalRejectReason.deviceNotReady, label)
                XCTAssertEqual(decision, .reject(LocalRejectReason.deviceNotReady), label)
            }
        }
    }

    /// P1'. 受限会话（deletion_only）× 隐私撤回体：scopeAllows 放行（accepted=false），读不出设备标识同样 device_not_ready
    /// （新分支在 scope 判定之后）。
    func testPrivacyWithdrawWithoutDeviceIdInDeletionOnlyIsRejectedDeviceNotReady() throws {
        XCTAssertTrue(
            RequestHeaderPolicy.scopeAllows(
                "deletion_only", operation: try operation(), body: try body(Self.privacyWithdraw)
            ),
            "前提：deletion_only 放行隐私撤回体"
        )
        for deviceId in [nil, ""] as [String?] {
            let decision = try decide(state(scope: "deletion_only", deviceId: deviceId), Self.privacyWithdraw)
            XCTAssertEqual(decision, .reject(LocalRejectReason.deviceNotReady), "deviceId=\(deviceId ?? "nil")")
        }
    }

    // MARK: - 2. 读得出设备标识 → 照发，带 X-Device-Id，不签名

    /// P2. 同上但 deviceId 有值 → send=true、includeDeviceId=true、不带签名头；Authorization 按 hasAccessToken（现状：optional 有令牌就带）。
    func testPrivacyWithdrawWithDeviceIdSendsWithDeviceIdAndNoSignature() throws {
        for token in [true, false] {
            let decision = try decide(state(hasAccessToken: token, deviceId: "dev-1"), Self.privacyWithdraw)
            XCTAssertTrue(decision.send, "令牌=\(token)")
            XCTAssertNil(decision.localRejectReason, "令牌=\(token)")
            XCTAssertTrue(decision.includeDeviceId, "令牌=\(token)")
            XCTAssertFalse(decision.includeSignature, "令牌=\(token)：x-signed=false")
            for name in HeaderNames.signature {
                XCTAssertFalse(decision.headerNames.contains(name), "令牌=\(token)：不带 \(name)")
            }
            XCTAssertEqual(decision.includeAuthorization, token, "令牌=\(token)")
            XCTAssertEqual(
                decision.headerNames,
                HeaderNames.anonymous + (token ? [HeaderNames.authorization] : [])
                    + [HeaderNames.deviceId, HeaderNames.idempotencyKey],
                "令牌=\(token)"
            )
        }
    }

    // MARK: - 3. 对照：recordConsent 其它请求体不受影响

    /// P3. deviceId nil × recordConsent 的其它体（privacy accepted=true、agreement accepted=false、
    /// ai_third_party accepted=false、没有请求体）→ 与改动前一致：照发、不带 X-Device-Id、Authorization 按令牌、带 Idempotency-Key（推导见类注释）。
    func testOtherRecordConsentBodiesWithoutDeviceIdAreUnchanged() throws {
        let others: [(String, String?)] = [
            ("privacy accepted=true", Self.privacyAccept),
            ("agreement accepted=false", Self.agreementWithdraw),
            ("ai_third_party accepted=false", Self.aiWithdraw),
            ("没有请求体", nil),
        ]
        for (label, text) in others {
            for deviceId in [nil, ""] as [String?] {
                for token in [true, false] {
                    let decision = try decide(state(hasAccessToken: token, deviceId: deviceId), text)
                    XCTAssertEqual(
                        decision, sentWithoutDevice(authorization: token),
                        "\(label) deviceId=\(deviceId ?? "nil") 令牌=\(token)"
                    )
                }
            }
        }
    }

    /// P3'. 只看 type、不看 accepted 的变异要被拦：type=privacy 但 accepted 缺省 / 不是 JSON 布尔（"false" 字符串、0）→ 不是撤回体，
    /// 与改动前一致照发（JSONFields.bool 只认真正的布尔，NetworkTypes.swift:375）。
    func testPrivacyTypeWithoutBooleanFalseAcceptedIsNotTreatedAsWithdraw() throws {
        let bodies = [
            "{\"type\":\"privacy\",\"version\":3}",
            "{\"type\":\"privacy\",\"accepted\":\"false\",\"version\":3}",
            "{\"type\":\"privacy\",\"accepted\":0,\"version\":3}",
        ]
        for text in bodies {
            XCTAssertFalse(RequestHeaderPolicy.isPrivacyWithdrawal(try body(text)), text)
            XCTAssertEqual(try decide(state(deviceId: nil), text), sentWithoutDevice(authorization: true), text)
        }
        XCTAssertTrue(RequestHeaderPolicy.isPrivacyWithdrawal(try body(Self.privacyWithdraw)))
        XCTAssertFalse(RequestHeaderPolicy.isPrivacyWithdrawal(try body(Self.agreementWithdraw)))
        XCTAssertFalse(RequestHeaderPolicy.isPrivacyWithdrawal(try body(Self.privacyAccept)))
    }

    /// P3''. 受限会话对照：deviceId nil × agreement accepted=false 照发（不带 X-Device-Id）；没有请求体仍是 session_scope_denied。
    func testDeletionOnlyOtherBodiesWithoutDeviceIdAreUnchanged() throws {
        XCTAssertEqual(
            try decide(state(scope: "deletion_only", deviceId: nil), Self.agreementWithdraw),
            sentWithoutDevice(authorization: true)
        )
        XCTAssertEqual(
            try decide(state(scope: "deletion_only", deviceId: nil), nil),
            .reject(LocalRejectReason.sessionScopeDenied)
        )
    }

    // MARK: - 4. 原来的拒绝原因不被新分支抢先

    /// P4 的一行：情形说明、判定输入、应得的拒绝原因。
    private struct EarlierReject {
        let label: String
        let state: NetworkRequestState
        let reason: String

        init(_ label: String, _ state: NetworkRequestState, _ reason: String) {
            self.label = label
            self.state = state
            self.reason = reason
        }
    }

    /// P4. 隐私撤回体在基本模式、凭据不可读（撤回清理未完成）、未决时仍是 basic_mode_denied；环境未就绪仍是 environment_unsettled——
    /// deviceId 有没有都一样（这些分支在新分支之前，且 credentials=false 时 deviceId 本就被置 nil）。
    func testEarlierRejectReasonsWinOverDeviceNotReady() throws {
        let basic = LocalRejectReason.basicModeDenied
        let cases: [EarlierReject] = [
            EarlierReject("基本模式", state(privacy: PrivacyRaw.basic, deviceId: nil), basic),
            EarlierReject("基本模式有设备", state(privacy: PrivacyRaw.basic, deviceId: "dev-1"), basic),
            EarlierReject("凭据不可读", state(deviceId: nil, readable: false), basic),
            EarlierReject("凭据不可读有设备", state(deviceId: "dev-1", readable: false), basic),
            EarlierReject("未决", state(privacy: PrivacyRaw.undecided, deviceId: nil), basic),
            EarlierReject("环境未就绪", state(deviceId: nil, settled: false), LocalRejectReason.environmentUnsettled),
        ]
        for item in cases {
            XCTAssertEqual(try decide(item.state, Self.privacyWithdraw), .reject(item.reason), item.label)
        }
    }
}
