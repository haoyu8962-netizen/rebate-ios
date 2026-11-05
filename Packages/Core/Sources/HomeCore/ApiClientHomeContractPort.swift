import CouliNetwork
import Foundation

/// 首页的生产端口（FU-X-HOME-PAGE-API-ios，D10-604 ①、D10-643）：经 ApiClient 发契约接口 getPage（`GET /v1/pages/{page_key}`）
/// 与 listPageSectionItems（`GET /v1/pages/{page_key}/sections/{section_id}/items`，03 §6.2 卡片自取数）。
/// - 只带路径参数；续页时游标是唯一的查询参数（按 RFC 3986 非保留字符百分号编码）。不拼 kind、pool_id、limit、频道参数
///   （契约每页固定 20 条，没有 limit）。
/// - 发送闸门用 `call.sendAllowed`（发送前现读）；归属按 `call.owner` 核对。是否带凭据由 ApiClient 按隐私结论决定
///   （基本模式只带匿名头，`call.anonymous` 不需要另外处理）。
/// - 不重试、不扇出，结果原样交回控制器（30701 / 42901 / 断网等的处理都在 HomeController 与 HomeSourcePolicy）。
public final class ApiClientHomeContractPort: HomeContractPort {
    static let getPageOperation = "getPage"
    static let sectionItemsOperation = "listPageSectionItems"
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private let api: HomeArticlesApi

    public init(api: HomeArticlesApi) {
        self.api = api
    }

    public func getPage(pageKey: String, call: HomeCall) async -> ApiResult {
        await api.send(
            ApiCall(operationId: Self.getPageOperation, pathParams: ["page_key": pageKey]),
            isValid: { true },
            sendAllowed: call.sendAllowed,
            expected: call.owner
        )
    }

    public func listSectionItems(
        pageKey: String,
        sectionId: String,
        cursor: String?,
        call: HomeCall
    ) async -> ApiResult {
        let query = cursor.map { "cursor=" + ($0.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? $0) }
        return await api.send(
            ApiCall(
                operationId: Self.sectionItemsOperation,
                pathParams: ["page_key": pageKey, "section_id": sectionId],
                query: query
            ),
            isValid: { true },
            sendAllowed: call.sendAllowed,
            expected: call.owner
        )
    }
}
