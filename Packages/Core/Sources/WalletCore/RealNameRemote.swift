import CouliNetwork
import Foundation

/// 实名提交与实名单独同意的契约实现（D10-856 ②，去掉 N-32 空实现）：经 `WalletApi`（生产为 ApiClient：签名、登录态、版本门槛、
/// 42901 闸门都在网络层）发
/// - 单独同意 recordConsent：POST /v1/consents {type: id_verification, version, accepted: true, channel: realname_sheet,
/// client_at}
///   （BR-ID-25、BR-ID-12；version 取 /v1/config.legal.privacy.version，D10-887 ①）；
/// - 实名提交 submitRealname：POST /v1/me/realname {name, id_no}，带调用方给的幂等键。
/// 姓名、身份证号只进实名提交的请求体：不进同意记录、查询串、请求头、未决记录（submitRealname 不是 step-up 操作，网络层不落未决记录）、
/// 日志与埋点。本文件不打印任何内容。
public final class ApiRealNameBackend: RealNameBackend {
    static let submitOperation = "submitRealname"
    static let consentOperation = "recordConsent"
    static let consentType = "id_verification"
    static let consentChannel = "realname_sheet"

    private let api: WalletApi
    private let gate: RetryAfterGate
    private let consentVersion: @MainActor @Sendable () -> Int
    private let clock: @Sendable () -> Int64

    /// `gate`：实名的共享禁用期（WalletGates.realname，发送前闸门）。`consentVersion`：单独同意记录的 version（正整数）。
    public init(
        api: WalletApi, gate: RetryAfterGate, consentVersion: @escaping @MainActor @Sendable () -> Int,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.api = api
        self.gate = gate
        self.consentVersion = consentVersion
        self.clock = clock
    }

    public func recordConsent(owner: RequestOwnership?) async -> ApiResult {
        let version = await max(1, consentVersion())
        let body: [String: Any] = [
            "type": Self.consentType, "version": version, "accepted": true, "channel": Self.consentChannel,
            "client_at": Self.clientAt(clock()),
        ]
        let call = ApiCall(operationId: Self.consentOperation, body: Self.json(body))
        return await api.send(call, isValid: { true }, sendAllowed: gate.probe().allowed, expected: owner)
    }

    public func submit(name: String, idNo: String, idempotencyKey: String,
                       owner: RequestOwnership?) async -> ApiResult {
        let call = ApiCall(
            operationId: Self.submitOperation, body: Self.json(["name": name, "id_no": idNo]),
            idempotencyKey: idempotencyKey
        )
        return await api.send(call, isValid: { true }, sendAllowed: gate.probe().allowed, expected: owner)
    }

    /// 请求体文本（键排序，签名与重放用同一份字节；同一输入恒得同一份文本）。
    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ))
            ?? Data("{}".utf8)
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    /// client_at：点击时刻，上海时区 ISO 8601（与隐私中心的同意记录同一写法）。
    static func clientAt(_ epochMillis: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000))
    }
}
