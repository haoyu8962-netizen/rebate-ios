import CouliNetwork
import Foundation

public extension ConfigReply {
    /// `/v1/config` 的 operationId（openapi getConfig；基本模式与隐私未决时也在白名单内）。
    static let operationId = "getConfig"

    /// ApiClient 的结果 → ConfigStore 的回复：code=0 → ok（data 与响应头 ETag）；HTTP 304 → not_modified；其余 → failure。
    static func from(_ result: ApiResult, meta: ApiResponseMeta) -> ConfigReply {
        switch result {
        case let .success(data, _, _):
            let body = data.flatMap { String(data: $0, encoding: .utf8) }
            return ConfigReply(kindRaw: ok, bodyJson: body, etag: meta.header(HeaderNames.etag))
        case let .transportFailure(_, status, _, _) where status == 304:
            return ConfigReply(kindRaw: notModified, bodyJson: nil, etag: meta.header(HeaderNames.etag))
        default:
            return ConfigReply(kindRaw: failure, bodyJson: nil, etag: nil)
        }
    }
}

/// 生产 fetcher：经 ApiClient 拉 `/v1/config`（带 If-None-Match），结果回到主线程交给 ConfigStore。
public enum ConfigFetcher {
    public static func make(client: ApiClient) -> (String?, @escaping (ConfigReply) -> Void) -> Void {
        { etag, completion in
            let callback = MainThreadCallback(completion)
            Task { @MainActor in
                let (result, meta) = await client.sendWithResponseHeaders(
                    ApiCall(operationId: ConfigReply.operationId, ifNoneMatch: etag)
                )
                callback.call(ConfigReply.from(result, meta: meta))
            }
        }
    }
}

/// 只在主线程调用的回调包装（跨 Task 的 Sendable 边界；ConfigStore 只在主线程使用）。
final class MainThreadCallback<Value>: @unchecked Sendable {
    private let action: (Value) -> Void

    init(_ action: @escaping (Value) -> Void) {
        self.action = action
    }

    @MainActor
    func call(_ value: Value) {
        action(value)
    }
}
