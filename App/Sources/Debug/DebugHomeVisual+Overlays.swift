#if DEBUG
import Clipboard
import Foundation
import HomeCore

/// 首页视觉 UI 测试的 b 组浮层场景（APP-11v-b；只在 Debug / Staging 编译）：弹窗、剪贴板识别结果（首次用途说明场景随
/// FU-X-CLIP-DEFAULT-ON 删除）。只经真实出口推进：弹窗由真实弹窗状态机弹出；
/// 30132 与网络失败经用户粘贴的交付回调走真实识别 / parse；识别卡（单张）经剪贴板结果出口 `show(.cardList)`（iOS 单卡平时直接进详情，
/// 打不开详情时才落到这张卡；版式两者同一组件）。
extension DebugHomeVisual {
    static let overlayScenes: Set = [
        "popup", "clipboard_card", "clipboard_no_price", "clipboard_material", "clipboard_30132",
        "clipboard_network",
    ]

    func advanceOverlay(settled: Bool, state: HomeUiState) {
        guard state.source != nil, settled, let clipboard else {
            quietTicks = 0
            return
        }
        let scene = settings.scene
        if sceneStep == 0 {
            sceneStep = 1
            start(scene, clipboard: clipboard)
            quietTicks = 0
            return
        }
        guard shown(scene, clipboard: clipboard, state: state) else {
            quietTicks = 0
            return
        }
        readyWhenStable(settled: settled, state: state)
    }

    private func start(_ scene: String, clipboard: AppClipboard) {
        let origin = clipboard.currentOrigin()
        switch scene {
        case "clipboard_card", "clipboard_material":
            clipboard.show(
                origin,
                .cardList([ParseRow(card: clipboardCard, errorCode: nil, hitRaw: nil)], traceId: nil)
            )
        case "clipboard_no_price":
            var card = clipboardCard
            // 查不到价格（availability=price_unavailable）：三个价格字段保持未知（与搜索「状态」样例同一形状）
            for field in ["price_fen", "coupon_fen", "final_price_fen", "est_net_price_fen", "rebate_min_fen",
                          "rebate_max_fen"] {
                card[field] = NSNull()
            }
            card["availability"] = "price_unavailable"
            clipboard.show(origin, .cardList([ParseRow(card: card, errorCode: nil, hitRaw: nil)], traceId: nil))
        case "clipboard_30132":
            clipboard.pasted(entry: ManualPasteAction.entryHome, text: "「全脂纯牛奶 250ml」 好喝又便宜")
        case "clipboard_network":
            clipboard.pasted(entry: ManualPasteAction.entryHome, text: "https://e.tb.cn/h.Visual05?tk=Network")
        default:
            break
        }
    }

    private func shown(_ scene: String, clipboard: AppClipboard, state: HomeUiState) -> Bool {
        switch scene {
        case "popup":
            return state.popup != nil
        case "clipboard_30132":
            if case .unrecognized = clipboard.result?.kind {
                return true
            }
            return false
        case "clipboard_network":
            if case .networkFailed = clipboard.result?.kind {
                return true
            }
            return false
        default:
            if case .cardList = clipboard.result?.kind {
                return true
            }
            return false
        }
    }
}
#endif

#if DEBUG
extension DebugHomeVisual {
    /// 网络失败场景的剪贴板 parse 回答断网；其余请求照原来的订单假服务（DebugFakeOrders）。
    nonisolated static func parseReply(method: String, path: String, query: [String: String])
        -> DebugFakeOrders.Reply? {
        if path == "/v1/inputs/parse", parseOfflineNow {
            return .offline
        }
        return DebugFakeOrders.answer(method: method, path: path, query: query)
    }

    /// 网络失败场景的 parse 一律按断网结束（DebugFakeLoginServer 在网络线程先问这里；与 `bootstrap` 读同一启动请求，
    /// 场景在启动时定下、之后不变）。
    nonisolated static var parseOfflineNow: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-CouliHomeVisual"), arguments.indices.contains(index + 1),
              arguments[index + 1] == "1",
              let raw = ProcessInfo.processInfo.environment["COULI_HOME_VISUAL_REQUEST"],
              let data = Data(base64Encoded: raw),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let settings = root["settings"] as? [String: Any]
        else { return false }
        return settings["scene"] as? String == "clipboard_network"
    }
}
#endif
