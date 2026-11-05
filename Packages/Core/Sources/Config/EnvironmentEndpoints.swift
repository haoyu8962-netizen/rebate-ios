import Foundation

/// 一个环境的服务基址。具体取值集中在 App/Sources/Environment/AppEnvironment+Endpoints.swift。
public struct EnvironmentEndpoints: Sendable, Hashable {
    public let apiBaseURL: URL
    public let h5BaseURL: URL
    /// Agent 流式入口基址（D10-598 ①）：非 nil 时 `/v1/agent/*` 发往这里，其余仍走 apiBaseURL；正式环境不设。
    public let streamBaseURL: URL?

    public init(api: String, h5: String, stream: String? = nil) {
        guard let apiURL = URL(string: api), let h5URL = URL(string: h5) else {
            preconditionFailure("invalid endpoint literal")
        }
        apiBaseURL = apiURL
        h5BaseURL = h5URL
        if let stream {
            guard let streamURL = URL(string: stream) else {
                preconditionFailure("invalid endpoint literal")
            }
            streamBaseURL = streamURL
        } else {
            streamBaseURL = nil
        }
    }
}
