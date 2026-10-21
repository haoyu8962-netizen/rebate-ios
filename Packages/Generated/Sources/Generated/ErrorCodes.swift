// 生成物，禁止手改；来源 contract.lock
// 快照：contracts/error-codes.json

public enum RetryKind: Swift.String, Swift.Sendable, Swift.Codable {
    case never
    case afterAction = "after_action"
    case later
    case immediate
    case notApplicable = "not_applicable"
}

public struct ErrorCodeInfo: Swift.Sendable, Swift.Equatable {
    public let code: Swift.Int
    public let http: Swift.Int
    public let retryKind: RetryKind
    public let retryKindByReason: [Swift.String: RetryKind]
    public let isDeprecated: Swift.Bool
    public let isP1: Swift.Bool
}

public enum ErrorCodes {
    /// 表里全部码（含废弃、P1）。
    public static let all: [Swift.Int: ErrorCodeInfo] = [
        10001: ErrorCodeInfo(
            code: 10001, http: 401, retryKind: .afterAction,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        10002: ErrorCodeInfo(
            code: 10002, http: 401, retryKind: .afterAction,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        10003: ErrorCodeInfo(
            code: 10003, http: 403, retryKind: .afterAction,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        10004: ErrorCodeInfo(
            code: 10004, http: 403, retryKind: .afterAction,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        10005: ErrorCodeInfo(
            code: 10005, http: 403, retryKind: .afterAction,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        10006: ErrorCodeInfo(
            code: 10006, http: 403, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        10007: ErrorCodeInfo(
            code: 10007, http: 403, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        10008: ErrorCodeInfo(
            code: 10008, http: 401, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        10009: ErrorCodeInfo(
            code: 10009, http: 403, retryKind: .later,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        10401: ErrorCodeInfo(
            code: 10401, http: 401, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        10402: ErrorCodeInfo(
            code: 10402, http: 401, retryKind: .afterAction,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        10403: ErrorCodeInfo(
            code: 10403, http: 403, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        10404: ErrorCodeInfo(
            code: 10404, http: 401, retryKind: .notApplicable,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        10405: ErrorCodeInfo(
            code: 10405, http: 403, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        20001: ErrorCodeInfo(
            code: 20001, http: 400, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        20002: ErrorCodeInfo(
            code: 20002, http: 400, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        20003: ErrorCodeInfo(
            code: 20003, http: 400, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        20004: ErrorCodeInfo(
            code: 20004, http: 400, retryKind: .afterAction,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        20901: ErrorCodeInfo(
            code: 20901, http: 409, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        20902: ErrorCodeInfo(
            code: 20902, http: 409, retryKind: .afterAction,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        20903: ErrorCodeInfo(
            code: 20903, http: 409, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30101: ErrorCodeInfo(
            code: 30101, http: 422, retryKind: .afterAction,
            retryKindByReason: ["auth_unavailable": .later],
            isDeprecated: false, isP1: false
        ),
        30102: ErrorCodeInfo(
            code: 30102, http: 422, retryKind: .afterAction,
            retryKindByReason: ["auth_unavailable": .later, "sharer_auth_invalid": .never],
            isDeprecated: false, isP1: false
        ),
        30103: ErrorCodeInfo(
            code: 30103, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30104: ErrorCodeInfo(
            code: 30104, http: 422, retryKind: .afterAction,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30111: ErrorCodeInfo(
            code: 30111, http: 422, retryKind: .afterAction,
            retryKindByReason: ["sharer_auth_invalid": .never],
            isDeprecated: false, isP1: false
        ),
        30121: ErrorCodeInfo(
            code: 30121, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30131: ErrorCodeInfo(
            code: 30131, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30132: ErrorCodeInfo(
            code: 30132, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30141: ErrorCodeInfo(
            code: 30141, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30142: ErrorCodeInfo(
            code: 30142, http: 422, retryKind: .notApplicable,
            retryKindByReason: [:],
            isDeprecated: true, isP1: false
        ),
        30143: ErrorCodeInfo(
            code: 30143, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30144: ErrorCodeInfo(
            code: 30144, http: 404, retryKind: .afterAction,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30151: ErrorCodeInfo(
            code: 30151, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30152: ErrorCodeInfo(
            code: 30152, http: 422, retryKind: .notApplicable,
            retryKindByReason: [:],
            isDeprecated: true, isP1: false
        ),
        30153: ErrorCodeInfo(
            code: 30153, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30154: ErrorCodeInfo(
            code: 30154, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30201: ErrorCodeInfo(
            code: 30201, http: 404, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30202: ErrorCodeInfo(
            code: 30202, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30203: ErrorCodeInfo(
            code: 30203, http: 422, retryKind: .later,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30204: ErrorCodeInfo(
            code: 30204, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30205: ErrorCodeInfo(
            code: 30205, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30206: ErrorCodeInfo(
            code: 30206, http: 422, retryKind: .later,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30301: ErrorCodeInfo(
            code: 30301, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30302: ErrorCodeInfo(
            code: 30302, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30303: ErrorCodeInfo(
            code: 30303, http: 422, retryKind: .never,
            retryKindByReason: ["payout_account_verify_limit": .later],
            isDeprecated: false, isP1: false
        ),
        30304: ErrorCodeInfo(
            code: 30304, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30305: ErrorCodeInfo(
            code: 30305, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30306: ErrorCodeInfo(
            code: 30306, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30307: ErrorCodeInfo(
            code: 30307, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30308: ErrorCodeInfo(
            code: 30308, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30309: ErrorCodeInfo(
            code: 30309, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30401: ErrorCodeInfo(
            code: 30401, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30402: ErrorCodeInfo(
            code: 30402, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30403: ErrorCodeInfo(
            code: 30403, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30404: ErrorCodeInfo(
            code: 30404, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30405: ErrorCodeInfo(
            code: 30405, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30406: ErrorCodeInfo(
            code: 30406, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30407: ErrorCodeInfo(
            code: 30407, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30408: ErrorCodeInfo(
            code: 30408, http: 422, retryKind: .later,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30409: ErrorCodeInfo(
            code: 30409, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30410: ErrorCodeInfo(
            code: 30410, http: 422, retryKind: .later,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30411: ErrorCodeInfo(
            code: 30411, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30412: ErrorCodeInfo(
            code: 30412, http: 422, retryKind: .later,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30413: ErrorCodeInfo(
            code: 30413, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30414: ErrorCodeInfo(
            code: 30414, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30415: ErrorCodeInfo(
            code: 30415, http: 422, retryKind: .later,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30416: ErrorCodeInfo(
            code: 30416, http: 422, retryKind: .later,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30417: ErrorCodeInfo(
            code: 30417, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30501: ErrorCodeInfo(
            code: 30501, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30502: ErrorCodeInfo(
            code: 30502, http: 422, retryKind: .later,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30503: ErrorCodeInfo(
            code: 30503, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30504: ErrorCodeInfo(
            code: 30504, http: 422, retryKind: .afterAction,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30505: ErrorCodeInfo(
            code: 30505, http: 404, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30506: ErrorCodeInfo(
            code: 30506, http: 409, retryKind: .later,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30601: ErrorCodeInfo(
            code: 30601, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30602: ErrorCodeInfo(
            code: 30602, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30603: ErrorCodeInfo(
            code: 30603, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30604: ErrorCodeInfo(
            code: 30604, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30701: ErrorCodeInfo(
            code: 30701, http: 404, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        30801: ErrorCodeInfo(
            code: 30801, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: true
        ),
        30802: ErrorCodeInfo(
            code: 30802, http: 422, retryKind: .afterAction,
            retryKindByReason: [:],
            isDeprecated: false, isP1: true
        ),
        30803: ErrorCodeInfo(
            code: 30803, http: 409, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: true
        ),
        30804: ErrorCodeInfo(
            code: 30804, http: 409, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: true
        ),
        30805: ErrorCodeInfo(
            code: 30805, http: 422, retryKind: .later,
            retryKindByReason: [:],
            isDeprecated: false, isP1: true
        ),
        30806: ErrorCodeInfo(
            code: 30806, http: 422, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: true
        ),
        40901: ErrorCodeInfo(
            code: 40901, http: 409, retryKind: .later,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        42901: ErrorCodeInfo(
            code: 42901, http: 429, retryKind: .later,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        44001: ErrorCodeInfo(
            code: 44001, http: 403, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        44002: ErrorCodeInfo(
            code: 44002, http: 403, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        44003: ErrorCodeInfo(
            code: 44003, http: 403, retryKind: .afterAction,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        44004: ErrorCodeInfo(
            code: 44004, http: 403, retryKind: .never,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        50001: ErrorCodeInfo(
            code: 50001, http: 500, retryKind: .immediate,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        50301: ErrorCodeInfo(
            code: 50301, http: 503, retryKind: .later,
            retryKindByReason: ["maintenance": .later, "not_launched": .never],
            isDeprecated: false, isP1: false
        ),
        50302: ErrorCodeInfo(
            code: 50302, http: 503, retryKind: .later,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        50303: ErrorCodeInfo(
            code: 50303, http: 503, retryKind: .later,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        50304: ErrorCodeInfo(
            code: 50304, http: 503, retryKind: .later,
            retryKindByReason: ["search_disabled": .never],
            isDeprecated: false, isP1: false
        ),
        50305: ErrorCodeInfo(
            code: 50305, http: 503, retryKind: .later,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
        50401: ErrorCodeInfo(
            code: 50401, http: 504, retryKind: .immediate,
            retryKindByReason: [:],
            isDeprecated: false, isP1: false
        ),
    ]

    public static func info(_ code: Swift.Int) -> ErrorCodeInfo? {
        all[code]
    }
}
