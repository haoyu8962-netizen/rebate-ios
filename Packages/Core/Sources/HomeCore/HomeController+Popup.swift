import Foundation

public extension HomeController {
    internal func preparePopup(_ section: HomeSection) {
        guard let popup = section.popup else { return }
        candidate = section
        popupReady = false
        let render = state.render
        tasks.begin()
        Task { [self] in
            let loaded = await deps.images.load(popup.image)
            defer { tasks.end() }
            afterIdentity(slot: "popup.\(render.generation)") { [weak self] in
                guard let self, accepts(render), candidate?.id == section.id else { return }
                popupReady = loaded
                reconsiderPopup()
            }
        }
    }

    internal func reconsiderPopup() {
        guard lifetime.valid, deps.identityCheck() == .current else { state.popup = nil
            return
        }
        let blocked = !deps.signals.visible || !deps.signals.blockers().isEmpty
        if blocked {
            state.popup = nil
            return
        }
        guard state.popup == nil, !coldStartShown, popupReady, identity.level != .basic,
              let section = candidate, let popup = section.popup else { return }
        guard preview || (popup.inWindow(deps.clock()) && deps.prefs.shownToday(
            sectionId: section.id,
            nowMs: deps.clock()
        ) < popup.dailyMax) else { return }
        state.popup = HomePopupUi(
            ticket: HomePopupTicket(render: state.render, instance: UUID()),
            sectionId: section.id,
            image: popup.image,
            clickable: popup.action != nil,
            adLabel: popup.adLabel
        )
    }

    func popupShown(_ ticket: HomePopupTicket) {
        guard accepts(ticket.render), state.popup?.ticket == ticket, !coldStartShown,
              deps.signals.visible, deps.signals.blockers().isEmpty, let section = candidate else { return }
        guard deps.identityCheck() == .current else { return }
        coldStartShown = true
        if !preview, identity.level != .basic {
            _ = deps.prefs.recordShown(sectionId: section.id, nowMs: deps.clock(), ticket: prefsTicket)
        }
    }

    func closePopup(_ ticket: HomePopupTicket) {
        guard accepts(ticket.render), state.popup?.ticket == ticket else { return }
        state.popup = nil
        candidate = nil
        popupReady = false
    }

    func tapPopup(_ ticket: HomePopupTicket) {
        guard accepts(ticket.render), state.popup?.ticket == ticket, let section = candidate,
              let action = section.popup?.action else { return }
        let tap = tap(action, section: section.id, slot: 1)
        closePopup(ticket)
        open(tap)
    }
}
