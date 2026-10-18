import CouliNetwork
import Foundation
import Router

extension HomeController {
    func loadSection(_ id: String) {
        guard lifetime.valid, let section = page?.sections.first(where: { $0.id == id }),
              !loadingSections.contains(id) else { return }
        guard section.source == "api" || deps.port != nil else { return }
        let render = state.render
        let pageKey = page?.key ?? "home"
        if deps.gate.active {
            pendingSections.insert(id)
            gateChanged(true)
            return
        }
        pendingSections.remove(id)
        loadingSections.insert(id)
        let cursor = feeds[id]?.ticket.cursor
        if section.type == "feed_infinite" {
            feeds[id] = HomeFeedUi(ticket: HomeFeedTicket(render: render, sectionId: id, cursor: cursor), loading: true)
        }
        rebuild()
        let probe = probe()
        let call = call(probe)
        tasks.begin()
        Task { [self] in
            let result: ApiResult = if section.source == "api" {
                await deps.articles.send(
                    ApiCall(operationId: "listArticles", query: "category=notice", forceUpdateByCaller: true),
                    isValid: { [lifetime] in lifetime.valid },
                    sendAllowed: probe.allowed,
                    expected: identity.request
                )
            } else if let port = deps.port {
                await port.listSectionItems(pageKey: pageKey, sectionId: id, cursor: cursor, call: call)
            } else {
                .localReject(reason: LocalRejectReason.invalidCall)
            }
            defer { tasks.end() }
            afterIdentity(slot: "section.\(render.generation).\(id)") { [weak self] in
                self?.settleSection(result, section: section, render: render, cursor: cursor, probe: probe)
            }
        }
    }

    func settleSection(
        _ result: ApiResult,
        section: HomeSection,
        render: HomeRenderTicket,
        cursor: String?,
        probe: SendProbe
    ) {
        let id = section.id
        guard lifetime.valid else { return }
        // 同会话旧渲染的 42901 也限制后续发送；失效控制器在上一道已拒绝。
        effects(result)
        guard accepts(render) else { return }
        loadingSections.remove(id)
        if case let .success(data?, _, _) = result,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = json["items"] as? [Any] {
            state.sectionErrors.removeValue(forKey: id)
            if section.source == "api" {
                apiNotices[id] = items.compactMap { ($0 as? [String: Any])?["notice"] }.compactMap(HomeJson.notice)
            } else {
                let mapped = items.compactMap(Self.productItem)
                sectionItems[id] = (cursor == nil ? [] : sectionItems[id, default: []]) + mapped
                if section.type == "feed_infinite" {
                    let next = HomeValue.text(json["next_cursor"])
                    feeds[id] = HomeFeedUi(ticket: HomeFeedTicket(render: render, sectionId: id, cursor: next),
                                           exhausted: next == nil || next == cursor)
                }
            }
        } else {
            let localGate = probe.gated(result)
            let error = failure(result)
            state.sectionErrors[id] = error
            if section.type == "feed_infinite" {
                feeds[id] = HomeFeedUi(ticket: HomeFeedTicket(render: render, sectionId: id, cursor: cursor),
                                       failure: localGate ? nil : error)
                if localGate {
                    pendingSections.insert(id)
                }
            } else if localGate || error.code == 42901 {
                pendingSections.insert(id)
            }
        }
        rebuild()
    }

    static func productItem(_ raw: Any) -> HomeItem? {
        guard let json = raw as? [String: Any], let key = HomeValue.text(json["product_key"]),
              let platform = HomeValue.text(json["platform"]), ["taobao", "jd", "pdd"].contains(platform),
              let title = HomeValue.text(json["title"]), let fields = JSONValue.object(from: json) else { return nil }
        var params: [String: JSONValue] = ["platform": .string(platform), "product_key": .string(key)]
        if let ref = json["item_ref"] as? String {
            params["item_ref"] = .string(ref)
        }
        // 金额保留 JSON 整数分；展示交给 DesignSystem 的 ProductCardMapper，不按返利额筛选。
        return HomeItem(title: title, image: HomeValue.https(json["image"]), adLabel: json["ad_label"] as? String,
                        action: RouteTarget(route: "ProductDetail", params: params), product: HomeProductUi(
                            productKey: key,
                            fields: fields
                        ))
    }

    public func loadMore(_ ticket: HomeFeedTicket) {
        guard accepts(ticket.render), let feed = feeds[ticket.sectionId], feed.ticket == ticket,
              !feed.loading, !feed.exhausted, feed.failure == nil else { return }
        loadSection(ticket.sectionId)
    }

    public func retryFeed(_ ticket: HomeFeedTicket) {
        guard accepts(ticket.render), let feed = feeds[ticket.sectionId], feed.ticket == ticket,
              !feed.loading, feed.failure != nil, !deps.gate.active else { return }
        loadSection(ticket.sectionId)
    }

    func gateChanged(_ blocked: Bool) {
        guard lifetime.valid else { return }
        state.refreshDisabled = blocked && deps.gate.active
        gateTimer?.cancel()
        if state.refreshDisabled {
            gateTimer = deps.timers.after(max(1, deps.gate.remainingMillis)) { [weak self] in
                guard let self else { return }
                gateChanged(deps.gate.active)
            }
        }
        let enabled = !state.refreshDisabled
        state.loadFailed?.retryEnabled = enabled
        for id in Array(feeds.keys) {
            feeds[id]?.failure?.retryEnabled = enabled
        }
        for id in Array(state.sectionErrors.keys) {
            state.sectionErrors[id]?.retryEnabled = enabled
        }
        rebuild()
        if enabled {
            let pending = pendingSections
            pendingSections = []
            for id in pending {
                loadSection(id)
            }
        }
    }
}
