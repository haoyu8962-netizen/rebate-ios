#if DEBUG
import Foundation

/// 订单假服务的样例数据（sample-data §12.2、§12.3；订单号、金额、时间都是样例值，没有个人信息）。
extension DebugFakeOrders {
    // MARK: - 样例

    struct Sample {
        let id: String
        var orderNo: String?
        var masked: String?
        let platform: String
        var title: String?
        var image = false
        var pay: Int?
        var quantity = 1
        let status: String
        var est: Int?
        var paidAt: String?
        var depositAt: String?
        var receivedAt: String?
        var period: String?
        var creditedAt: String?
        var endAt: String?
        var actual: Int?
        var clawback: Int?
        var reason: String?
        var actions: [String] = []
        var priceCompare: Bool? = false
        var other = false
        var productKey: String?

        private func value(_ text: String?) -> Any {
            text.map { $0 as Any } ?? NSNull()
        }

        private func value(_ fen: Int?) -> Any {
            fen.map { $0 as Any } ?? NSNull()
        }

        func summary() -> [String: Any] {
            var out: [String: Any] = [
                "order_id": id, "platform": platform, "title": value(title),
                "image_url": image ? DebugFakeSearchImages.url(for: id) : NSNull(),
                "pay_amount_fen": value(pay), "quantity": quantity, "display_status": status, "reason": value(reason),
                "est_rebate_fen": value(est), "paid_at": value(paidAt), "is_other_product": other,
            ]
            if let orderNo {
                out["order_no"] = orderNo
            } else {
                out["masked_order_no"] = masked ?? ""
            }
            return out
        }

        func detail(appeal: Bool) -> [String: Any] {
            var out = summary()
            out["product_key"] = value(productKey)
            out["reason_action"] = actions
            out["timeline"] = timeline()
            out["expected_credit_period"] = status == "WAITING" ? value(period) : NSNull()
            out["credit_overdue"] = false
            out["actual_fen"] = value(actual)
            out["clawback_fen"] = value(clawback)
            out["appeal_pending"] = appeal
            out["is_price_compare"] = priceCompare.map { $0 as Any } ?? NSNull()
            return out
        }

        private func timeline() -> [[String: Any]] {
            func node(_ name: String, _ at: String?, _ period: String? = nil) -> [String: Any] {
                ["node": name, "at": value(at), "period": value(period)]
            }
            var nodes: [[String: Any]] = []
            if let depositAt {
                nodes.append(node("deposit_paid", depositAt))
                nodes.append(node("final_paid", paidAt))
            } else {
                nodes.append(node("paid", paidAt))
            }
            nodes.append(node("received", receivedAt))
            nodes.append(node("credit_expected", nil, period))
            nodes.append(node("credited", creditedAt))
            switch status {
            case "INVALID": nodes.append(node("invalid", endAt))
            case "CLAWED_BACK": nodes.append(node("clawed_back", endAt))
            case "CREDITED_PART_CLAWED": nodes.append(node("part_clawed_back", endAt))
            default: break
            }
            return nodes
        }
    }

    static let appealSampleId = "ord-3768888888888888888"

    static func at(_ value: String) -> String {
        "2026-\(value):00+08:00"
    }

    /// 自购（sample-data §12.2 自1～自15，按付款时间倒序；预售按付定金时间）。
    static let selfSamples: [Sample] = [
        Sample(id: "ord-3741234567890123456", orderNo: "3741234567890123456", platform: "taobao",
               title: "样例商品 A：纯牛奶 250ml×12 盒", image: true, pay: 4560, quantity: 2, status: "PAID", est: 234,
               paidAt: at("10-12T09:05"), productKey: "tb:sampleA"),
        Sample(id: "ord-3798765432109876543", orderNo: "3798765432109876543", platform: "taobao",
               title: "样例商品 B：预售电饭煲 4L", pay: 3000, status: "DEPOSIT_PAID", depositAt: at("10-01T20:00"),
               productKey: "tb:sampleB"),
        Sample(id: "ord-309999999999", orderNo: "309999999999", platform: "jd", title: "样例商品 M：收纳盒 3 个装",
               pay: 1990, status: "FUTURE_STATUS", est: 88, paidAt: at("09-25T19:30"), productKey: "jd:sampleM"),
        Sample(id: "ord-305678901234", orderNo: "305678901234", platform: "jd", title: "样例商品 C：洗衣液 3kg",
               image: true, pay: 3990, status: "WAITING", est: 450, paidAt: at("09-20T14:03"),
               receivedAt: at("09-28T10:12"), period: "2026-10", productKey: "jd:sampleC"),
        Sample(id: "ord-3722222222222222222", orderNo: "3722222222222222222", platform: "taobao",
               title: "样例商品 J：蓝牙耳机", pay: 8900, status: "INVALID", est: 0, paidAt: at("09-18T21:40"),
               endAt: at("09-22T11:05"), reason: "REFUND", productKey: "tb:sampleJ"),
        Sample(id: "ord-308765432101", orderNo: "308765432101", platform: "jd", title: "样例商品 N：定制衣柜",
               status: "PAID", est: 1796, paidAt: at("09-15T20:10"), productKey: "jd:sampleN"),
        Sample(id: "ord-3766666666666666666", orderNo: "3766666666666666666", platform: "taobao",
               title: "样例商品 P：空气净化器", image: true, pay: 129_900, status: "WAITING", est: 1580,
               paidAt: at("09-14T12:30"), receivedAt: at("09-19T10:00"), period: "2026-10", productKey: "tb:sampleP"),
        Sample(id: "ord-260908-555566667777888", orderNo: "260908-555566667777888", platform: "pdd",
               title: "样例商品 Q：保鲜袋", pay: 2290, status: "WAITING", est: 340, paidAt: at("09-08T08:40"),
               receivedAt: at("09-12T10:00"), period: "2026-10", productKey: "pdd:sampleQ"),
        Sample(id: "ord-304433221100", orderNo: "304433221100", platform: "jd", title: "样例商品 D：洗洁精",
               pay: 2590, status: "WAITING", est: 500, paidAt: at("09-06T22:15"), receivedAt: at("09-10T10:00"),
               period: "2026-10", productKey: "jd:sampleD"),
        Sample(id: "ord-3755555555555555555", orderNo: "3755555555555555555", platform: "taobao",
               title: "样例商品 K：空气炸锅 4L", pay: 9900, status: "RIGHTS_PENDING", est: 456,
               paidAt: at("09-03T19:00"), receivedAt: at("09-08T16:20"), productKey: "tb:sampleK"),
        Sample(id: "ord-3744444444444444444", orderNo: "3744444444444444444", platform: "taobao",
               title: "样例商品 G2：保温饭盒", pay: 6900, status: "CREDITED", est: 600, paidAt: at("08-20T10:00"),
               receivedAt: at("08-25T10:00"), period: "2026-09", creditedAt: at("10-12T09:05"), actual: 600,
               productKey: "tb:sampleG2"),
        Sample(id: "ord-3733333333333333333", orderNo: "3733333333333333333", platform: "taobao",
               title: "样例商品 L：床上四件套", pay: 15900, status: "CREDITED_PART_CLAWED", est: 540,
               paidAt: at("08-12T21:00"), receivedAt: at("08-18T09:40"), period: "2026-09",
               creditedAt: at("09-25T10:00"), endAt: at("10-09T14:30"), actual: 140, clawback: 400,
               reason: "PART_REFUND", productKey: "tb:sampleL"),
        Sample(id: "ord-3711111111111111111", orderNo: "3711111111111111111", platform: "taobao",
               title: "样例商品 H：电动牙刷", pay: 12900, status: "CREDITED", est: 450, paidAt: at("08-03T20:15"),
               receivedAt: at("08-09T09:30"), period: "2026-09", creditedAt: at("09-25T10:00"), actual: 320,
               reason: "PRICE_COMPARE", productKey: "tb:sampleH"),
        Sample(id: "ord-260803-123456789012345", orderNo: "260803-123456789012345", platform: "pdd",
               title: "样例商品 F2：抽纸 24 包", pay: 1234, status: "CREDITED", est: 56, paidAt: at("08-03T16:20"),
               receivedAt: at("08-07T10:00"), creditedAt: at("09-05T10:00"), actual: 56, productKey: "pdd:sampleF2"),
        Sample(id: "ord-302345678901", orderNo: "302345678901", platform: "jd", title: "样例商品 E2：毛巾 3 条装",
               pay: 2990, status: "CREDITED", est: 67, paidAt: at("07-26T11:00"), receivedAt: at("07-30T10:00"),
               creditedAt: at("09-05T10:00"), actual: 67, productKey: "jd:sampleE2"),
    ]

    /// 分享（sample-data §12.2 分1～分5；单号只有服务端脱敏的 masked_order_no）。
    static let shareSamples: [Sample] = [
        Sample(id: "ord-s1", masked: "3712****67", platform: "taobao", title: "样例商品 E：保温杯 500ml", image: true,
               pay: 5900, status: "PAID", est: 180, paidAt: at("10-12T10:21"), productKey: "tb:sampleE"),
        Sample(id: "ord-s2", masked: "3756****21", platform: "taobao", pay: 2680, status: "WAITING", est: 60,
               paidAt: at("10-02T18:30"), receivedAt: at("10-08T15:12"), period: "2026-11", other: true),
        Sample(id: "ord-s3", masked: "3056****34", platform: "jd", title: "样例商品 F：数据线 2 条装", image: true,
               pay: 1990, status: "CREDITED", est: 35, paidAt: at("09-18T09:40"), receivedAt: at("09-22T10:00"),
               creditedAt: at("10-08T10:00"), actual: 35, productKey: "jd:sampleF"),
        Sample(id: "ord-s4", masked: "2510****45", platform: "pdd", title: "样例商品 G：衣架 20 个装", pay: 1580,
               status: "CREDITED", est: 28, paidAt: at("09-12T21:05"), receivedAt: at("09-16T10:00"),
               creditedAt: at("10-08T10:00"), actual: 28, productKey: "pdd:sampleG"),
        Sample(id: "ord-s5", masked: "3790****88", platform: "taobao", title: "样例商品 S2：蓝牙音响", pay: 15900,
               status: "CREDITED", est: 187, paidAt: at("09-05T13:20"), receivedAt: at("09-10T10:00"),
               creditedAt: at("10-08T10:00"), actual: 187, productKey: "tb:sampleS2"),
    ]

    /// 补稿订单（sample-data §12.3）：不进列表，按完整单号能搜到。
    static let extraSamples: [Sample] = [
        Sample(id: "ord-3767777777777777777", orderNo: "3767777777777777777", platform: "taobao",
               title: "样例商品 S：电热水壶 1.7L", pay: 8900, status: "REVIEWING", est: 310, paidAt: at("09-10T20:30"),
               receivedAt: at("09-15T11:02"), productKey: "tb:sampleS"),
        Sample(id: "ord-306666666666", orderNo: "306666666666", platform: "jd", title: "样例商品 T：蓝牙音箱",
               pay: 19900, status: "CLAWED_BACK", est: 800, paidAt: at("08-20T13:10"), receivedAt: at("08-24T10:05"),
               period: "2026-09", creditedAt: at("09-25T10:00"), endAt: at("10-10T14:00"), clawback: 800,
               reason: "REFUND", productKey: "jd:sampleT"),
        Sample(id: "ord-260920-111122223333444", orderNo: "260920-111122223333444", platform: "pdd",
               title: "样例商品 U：手机支架", pay: 3990, status: "NO_REBATE", est: 0, paidAt: at("09-20T21:15"),
               receivedAt: at("09-24T10:30"), priceCompare: true, productKey: "pdd:sampleU"),
        Sample(id: appealSampleId, orderNo: "3768888888888888888", platform: "taobao", title: "样例商品 R：电动剃须刀",
               pay: 12900, status: "INVALID", est: 0, paidAt: at("10-02T20:30"), endAt: at("10-06T09:30"),
               reason: "BLACKLIST", actions: ["APPEAL"], productKey: "tb:sampleR"),
    ]
}
#endif
