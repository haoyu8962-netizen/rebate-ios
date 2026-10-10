import Foundation

/// 待跟单卡的票据、显示位置与卡片有效期（PendingTrackService 的一部分；APP-08 共性第 42、46 条，iOS R3-03 / RC-05；APP-09 第 63、65 条）。
public extension PendingTrackService {
    /// 固定身份仍是当前会话（只比较）。
    internal var ownerCurrent: Bool {
        guard let env else { return false }
        return env.isCurrent(owner)
    }

    /// 显示位置仍在显示（视图挂着）。
    var displayed: Bool {
        !everDisplayed || displayCount > 0
    }

    /// 显示位置进入（卡片区视图 onAppear）：重新发布一次，视图按此刻的显示世代重新取票据。
    func enterDisplay() {
        everDisplayed = true
        displayCount += 1
        guard !left else { return }
        publish()
    }

    /// 显示位置离开（卡片区视图 onDisappear：切子 Tab、切主 Tab、被盖住、滚出懒加载区）——同步出口：推进显示世代（之前渲染的票据全部
    /// 失效）、取消等待中的通知申请。仍有别的挂载（新视图先出现、旧视图后消失）时稍后重新发布，让在显示的那一份换上新票据。
    func leaveDisplay() {
        everDisplayed = true
        displayCount = max(0, displayCount - 1)
        generation += 1
        pushTask?.cancel()
        pushTask = nil
        if displayCount > 0 {
            republishSoon()
        }
    }

    /// 渲染卡片时取出票据（PendingTrackCardsView 在 body 里调用，回调只捕获它）。
    /// 票据里的身份是执行器的固定身份（不在渲染时读当前会话）；卡片不在显示中时期号为 0（必然失效）。
    func ticket(for card: PendingTrackCardView) -> PendingTrackTicket {
        PendingTrackTicket(
            service: ObjectIdentifier(self), generation: generation, epoch: boundEpoch,
            owner: owner, life: cardLives[card.key] ?? 0, card: card
        )
    }

    /// 票据仍对得上：同一执行器、未作废、显示位置仍在显示、显示世代与会话世代没变、这张卡仍在同一期、票据身份就是执行器的固定身份且
    /// 仍是当前会话（只比较）。
    internal func ticketValid(_ ticket: PendingTrackTicket) -> Bool {
        ticket.service == ObjectIdentifier(self) && !left && displayed && ticket.generation == generation
            && ticket.epoch == boundEpoch && boundEpoch == hub.sessionEpoch && ticket
            .life != 0 && cardLives[ticket.card.key] == ticket.life
            && ticket.owner == owner && ownerCurrent
    }

    /// 卡片有效期：不在显示中的卡结束这一期，新出现（或消失后再出现）的卡开新一期。
    internal func updateLives(_ cards: [PendingTrackCardView]) {
        let keys = Set(cards.map(\.key))
        cardLives = cardLives.filter { keys.contains($0.key) }
        for card in cards where cardLives[card.key] == nil {
            lifeSeq += 1
            cardLives[card.key] = lifeSeq
        }
    }
}
