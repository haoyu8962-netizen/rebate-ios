import Foundation

/// 事件发起时固定的账号归属（APP-08 iOS r3g NEW-06）：编码 user_id 时用它，不再读当前会话。`userId` 为 nil = 发起时是游客，
/// 事件不带 user_id。调用方负责在交给队列之前比较来源仍是发起时的那一份（变了就丢弃）。
public struct TrackAttribution: Equatable, Sendable {
    public let userId: String?

    public init(userId: String?) {
        self.userId = userId
    }
}
