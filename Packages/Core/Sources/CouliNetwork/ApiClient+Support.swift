import Foundation
import Generated

/// 校时、URL、作废结果解析与外壳解包。
extension ApiClient {
    // MARK: - 10401 校时

    /// 响应头 Date 与本机时钟相差超过 300 秒时校正偏移（BR-ID-09）。
    func correctClock(_ headers: [String: String]) -> Bool {
        guard let raw = headers.first(where: { $0.key.caseInsensitiveCompare(HeaderNames.date) == .orderedSame })?
            .value,
            let server = Self.parseHTTPDate(raw)
        else {
            return false
        }
        let offset = Int64(server.timeIntervalSince1970 * 1000) - clock()
        guard abs(offset) > Self.maxSkewMillis else {
            return false
        }
        lock.withLock { clockOffsetMillis = offset }
        return true
    }

    static func parseHTTPDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    // MARK: - URL

    /// 基址 + 路径模板（填入编码后的路径参数）+ 原样查询串。路径参数没填全返回 nil。
    static func buildURL(_ base: URL, _ template: String, _ params: [String: String], _ query: String?) -> URL? {
        var path = template
        for (name, value) in params {
            path = path.replacingOccurrences(of: "{\(name)}", with: encodePathSegment(value))
        }
        guard !path.contains("{") else {
            return nil
        }
        var root = base.absoluteString
        while root.hasSuffix("/") {
            root.removeLast()
        }
        let suffix = query.flatMap { $0.isEmpty ? nil : "?\($0)" } ?? ""
        return URL(string: root + path + suffix)
    }

    /// 签名用的路径：发出的编码路径 + 原样查询串（BR-ID-09）。
    static func signedPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: true)
        guard let query = url.query(percentEncoded: true) else {
            return path
        }
        return path + "?" + query
    }

    private static func encodePathSegment(_ value: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - 作废结果

    /// 作废接口的结果 → 未决键的 kind。没有给出可判定结果（自身报错等）按非终结，键保持待确认。
    /// 作废接口的结果 → 给调用方的结果（lessons 27）：abandoned → `.abandoned`；completed → 解包 original，按原操作给出
    /// 业务结果（code 0 为 success，3xxxx 为 failure 并按原操作映射 Effect）；其余原样（保持待确认）。
    func unpackAbandon(_ result: ApiResult, original operation: ApiOperation, key: String) async -> ApiResult {
        guard case let .success(data, traceId, _) = result, let data,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return result
        }
        switch JSONFields.string(object, "outcome") {
        case "abandoned":
            return .abandoned(idempotencyKey: key)
        case "completed":
            guard let original = object["original"] as? [String: Any],
                  let code = JSONFields.int(original, "code") else {
                return result
            }
            let payload = original["data"].flatMap { $0 is NSNull ? nil : $0 }
            if code == 0 {
                return .success(data: JSONFields.encode(payload), traceId: traceId, idempotencyKey: key)
            }
            let state = await readContext()
            let effect = ErrorActionMapper.map(ErrorActionInput(
                code: code, data: payload as? [String: Any] ?? [:], operation: operation, headers: [:], isReplay: false,
                state: ErrorActionState(
                    update: state.update, sessionScope: currentScope(state), appVersion: identity.appVersion
                )
            ))
            await hooks.onEffect(effect)
            return .failure(
                code: code, msg: JSONFields.string(original, "msg") ?? "", data: JSONFields.encode(payload),
                traceId: traceId, effect: effect, idempotencyKey: key
            )
        default:
            return result
        }
    }

    static func abandonOutcome(_ result: ApiResult) -> String {
        let unresolved = "envelope_abandon_unresolved"
        switch result {
        case .transportFailure:
            return PendingKeyStore.noEnvelope
        case let .success(data, _, _):
            guard let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return unresolved
            }
            switch JSONFields.string(object, "outcome") {
            case "abandoned":
                return PendingKeyStore.abandoned
            case "completed":
                guard let original = object["original"] as? [String: Any],
                      let code = JSONFields.int(original, "code")
                else {
                    return unresolved
                }
                return PendingKeyStore.envelopeKind(code)
            default:
                return unresolved
            }
        case .failure, .localReject, .sessionCleared, .abandoned, .sessionNotSaved:
            return unresolved
        }
    }
}

/// 统一外壳：JSON 对象，code 为整数，msg 为字符串。
struct Envelope {
    let code: Int
    let msg: String
    let data: Any?
    let traceId: String?

    static func parse(_ body: Data) -> Envelope? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let code = JSONFields.int(root, "code"),
              let msg = JSONFields.string(root, "msg")
        else {
            return nil
        }
        let data = root["data"].flatMap { $0 is NSNull ? nil : $0 }
        return Envelope(code: code, msg: msg, data: data, traceId: JSONFields.string(root, "trace_id"))
    }
}

// MARK: - 响应头（条件请求）

/// 一次逻辑调用最后收到的 HTTP 状态与响应头（`ApiClient.sendWithResponseHeaders`）。
final class ResponseHeaderSink: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int?
    private var headers: [String: String] = [:]

    func record(status: Int, headers: [String: String]) {
        lock.withLock {
            self.status = status
            self.headers = headers
        }
    }

    var last: (status: Int?, headers: [String: String]) {
        lock.withLock { (status, headers) }
    }
}

/// 条件请求的结果：调用结果 + 最后一次 HTTP 响应的状态与头（没有收到响应时为 nil / 空）。
public struct ApiResponseMeta: Sendable, Equatable {
    public let httpStatus: Int?
    public let headers: [String: String]

    public init(httpStatus: Int?, headers: [String: String]) {
        self.httpStatus = httpStatus
        self.headers = headers
    }

    /// 响应头（名字不区分大小写）。
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public extension ApiClient {
    /// 发一次调用，并带回最后一次 HTTP 响应的状态与头（ConfigStore 读 ETag、判 304 用）。管线与 `send` 完全相同。
    func sendWithResponseHeaders(_ call: ApiCall) async -> (ApiResult, ApiResponseMeta) {
        let sink = ResponseHeaderSink()
        let result = await Self.$responseSink.withValue(sink) {
            await send(call)
        }
        let last = sink.last
        return (result, ApiResponseMeta(httpStatus: last.status, headers: last.headers))
    }
}

extension ApiClient {
    /// 当前逻辑调用的响应头收集器（任务局部，只有 `sendWithResponseHeaders` 设置）。
    @TaskLocal static var responseSink: ResponseHeaderSink?
}
