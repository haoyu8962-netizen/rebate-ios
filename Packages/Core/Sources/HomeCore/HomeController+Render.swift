import CouliNetwork
import Foundation
import Generated

extension HomeController {
    func display(_ page: HomePage, source: HomeSource, cold: Bool) {
        self.page = page
        candidate = nil
        popupReady = false
        state.popup = nil
        sectionItems = [:]
        apiNotices = [:]
        feeds = [:]
        pendingSections = []
        loadingSections = []
        failedImages = []
        noticeTimer?.cancel()
        state.render = HomeRenderTicket(controller: id, generation: state.render.generation + 1)
        state.source = source
        state.pageVersion = page.version
        state.loadFailed = nil
        state.sectionErrors = [:]
        state.dropped = page.dropped
        if !preview, identity.level != .basic {
            for drop in page.dropped where deps.dedupe.shouldSend(
                pageVersion: page.version,
                sectionId: drop.id,
                reason: drop.reason
            ) {
                deps.track(TrackerEvents.sduiCardError(page: "Home", type: drop.type, version: drop.version,
                                                       pageVersion: page.version, reason: drop.reason))
            }
        }
        rebuild()
        for section in page.sections {
            if section
                .source == "api" || (["product_pool", "union_material"].contains(section.source) && deps.port != nil) {
                loadSection(section.id)
            }
        }
        if cold, !coldStartShown, identity.level != .basic,
           let popup = page.sections.first(where: { $0.type == "popup" }) {
            preparePopup(popup)
        }
    }

    func rebuild() {
        guard lifetime.valid, let page else { return }
        let closed = memoryClosed.union(preview || identity.level == .basic ? [] : deps.prefs.closedKeys())
        let now = deps.clock()
        var transitions: [Int64] = []
        var sections: [HomeSectionUi] = []
        for section in page.sections where section.type != "popup" {
            var output = HomeSectionUi(id: section.id, type: section.type, title: section.title)
            output.columns = section.columns
            output.heightRatio = section.ratio
            output.autoplayMillis = section
                .autoplay
            output.more = section.more.map { tap($0, section: section.id, slot: 0) }
            output.autoplay = section.autoplay > 0 && deps.signals.visible && !deps.signals.screenReader
            if section.type == "notice_bar" {
                let notices = section.source == "api" ? apiNotices[section.id, default: []] : section.notices
                for notice in notices {
                    if notice.start > now {
                        transitions.append(notice.start)
                    }
                    if let end = notice.end, end > now {
                        transitions.append(end)
                    }
                }
                output.items = notices.enumerated().compactMap { index, notice in
                    guard notice.visible(section: section.id, closed: closed, now: now) else { return nil }
                    return noticeUi(notice, section: section, slot: index + 1)
                }
            } else {
                let items = section.source == "static" ? section.items : sectionItems[section.id, default: []]
                output.items = items.enumerated().map { itemUi($0.element, section: section, slot: $0.offset + 1) }
            }
            output.feed = feeds[section.id]
            if !output.items.isEmpty || output.feed?.failure != nil || output.feed?
                .loading == true {
                sections.append(output)
            }
        }
        // 信息流置底；普通卡保持服务端相对顺序，商品顺序完全不改。
        state.sections = sections.filter { $0.type != "feed_infinite" } + sections.filter { $0.type == "feed_infinite" }
        noticeTimer?.cancel()
        if let next = transitions.min() {
            let render = state.render
            noticeTimer = deps.timers.after(next - now) { [weak self] in
                guard let self, accepts(render) else { return }
                rebuild()
            }
        }
    }

    func tap(_ target: RouteTarget, section: String, slot: Int) -> HomeTap {
        HomeTap(render: state.render, sectionId: section, slot: slot, target: target)
    }

    func itemUi(_ item: HomeItem, section: HomeSection, slot: Int) -> HomeItemUi {
        let imageTicket = item.image
            .map { _ in HomeImageTicket(render: state.render, sectionId: section.id, slot: slot) }
        let failed = imageTicket.map { failedImages.contains($0) } ?? false
        var output = HomeItemUi(id: String(slot), title: item.title, subtitle: item.subtitle, image: item.image,
                                spokenName: item.alt ?? item.title ?? deps.text("home.image.entry", [:]))
        output.adLabel = HomeAdLabel.of(sectionLabel: section.adLabel, itemLabel: item.adLabel)
        output.badge = item.badge
        output.product = item.product
        output.imageTicket = imageTicket
        output
            .imageFailed = failed
        if !failed || section.type != "banner" {
            output.tap = item.action.map { tap($0, section: section.id, slot: slot) }
        }
        return output
    }

    func noticeUi(_ notice: HomeNotice, section: HomeSection, slot: Int) -> HomeItemUi {
        var output = HomeItemUi(
            id: HomeRowKey.make("item", [notice.id, String(slot)]),
            title: notice.text,
            spokenName: notice.text
        )
        output.adLabel = HomeAdLabel.of(sectionLabel: section.adLabel, itemLabel: notice.adLabel)
        output.tap = notice.target.map { tap($0, section: section.id, slot: slot) }
        if notice.closable {
            output.close = HomeNoticeClose(render: state.render, sectionId: section.id, itemId: notice.id,
                                           contentVersion: notice.version,
                                           persistence: !preview && identity.level != .basic, write: prefsTicket)
        }
        return output
    }

    public func open(_ tap: HomeTap) {
        guard deps.identityCheck() == .current, accepts(tap.render) else { return }
        let image = HomeImageTicket(render: tap.render, sectionId: tap.sectionId, slot: tap.slot)
        if page?.sections.first(where: { $0.id == tap.sectionId })?.type == "banner", failedImages.contains(image) {
            return
        }
        userInteracted = true
        deps.open(tap)
    }

    public func closeNotice(_ close: HomeNoticeClose) {
        guard close.render.controller == id else { return }
        let key = NoticeFilter.closeKey(
            sectionId: close.sectionId,
            itemId: close.itemId,
            contentVersion: close.contentVersion
        )
        // 设备级关闭记录允许身份作废后的原回调；撤回清理通过票据边界拒绝落盘。
        if close.persistence {
            _ = deps.prefs.recordClosed(key, ticket: close.write, at: deps.clock())
        }
        if accepts(close.render) {
            memoryClosed.insert(key)
            rebuild()
        }
    }

    public func imageLoaded(_ ticket: HomeImageTicket, ok: Bool) {
        afterIdentity(slot: "image.\(ticket.render.generation).\(ticket.sectionId).\(ticket.slot)") { [weak self] in
            guard let self, accepts(ticket.render) else { return }
            let changed = ok ? failedImages.remove(ticket) != nil : failedImages.insert(ticket).inserted
            if changed {
                rebuild()
            }
        }
    }

    func signalsChanged() {
        guard lifetime.valid else { return }
        rebuild()
        reconsiderPopup()
    }
}
