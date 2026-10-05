import Foundation

/// 一个环境的服务基址。具体取值集中在 App/Sources/Environment/AppEnvironment+Endpoints.swift。
public struct EnvironmentEndpoints: Sendable, Hashable {
    public let apiBaseURL: URL
    public let h5BaseURL: URL

    public init(api: String, h5: String) {
        guard let apiURL = URL(string: api), let h5URL = URL(string: h5) else {
            preconditionFailure("invalid endpoint literal")
        }
        apiBaseURL = apiURL
        h5BaseURL = h5URL
    }
}
