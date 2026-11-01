import ClientCore
import CouliNetwork
import DesignSystem
import MeCore
import SwiftUI

/// 「我的」页的按钮回调（渲染时一次取出：执行器与快照版本是不可变的普通值，APP-09 共性第 4、63 条；测试取同一份回调保留旧画面）。
@MainActor
public struct MeTabActions {
    public let refresh: () -> Void
    public let login: () -> Void
    public let bell: () -> Void
    public let copyInvite: () -> Void
    public let withdraw: () -> Void
    public let toggleMask: () -> Void
    public let openGuide: () -> Void
    public let closeGuide: () -> Void
    public let tap: (GridCell) -> Void

    public static func make(_ controller: MeTabController, _ snapshot: MeSnapshot) -> MeTabActions {
        let version = snapshot.version
        let code = snapshot.identity == controller.identity ? snapshot.me?.inviteCode : nil
        return MeTabActions(
            refresh: { [weak controller] in controller?.refresh() },
            login: { [weak controller] in controller?.openLogin() },
            bell: { [weak controller] in controller?.bell() },
            copyInvite: { [weak controller] in
                if let code {
                    controller?.copyInviteCode(version: version, code: code)
                }
            },
            withdraw: { [weak controller] in controller?.withdraw(version: version) },
            // G-M13：只有用户点眼睛才播一次；别处改偏好、进入、回前台都不走这里（所以不用 onChange）
            toggleMask: { [weak controller] in
                guard let controller, controller.alive, let mask = controller.deps.mask else { return }
                controller.toggleMask()
                MeAnnounce.post(controller.deps.texts.text(mask.hidden ? "me.amount_hidden" : "me.amount_shown"),
                                assertive: false)
            },
            openGuide: { [weak controller] in controller?.openGuide() },
            closeGuide: { [weak controller] in controller?.closeGuide() },
            tap: { [weak controller] cell in controller?.tap(cell) }
        )
    }
}

/// 「我的」Tab 根（设计稿 Me、MeGuest、MeHidden、MeMinor；AdaptBackRestore；APP-12v 视觉）：
/// - 已登录：标题「我的」+ 铃铛 → 通知引导条 → 身份卡（默认头像、昵称、我的邀请码【复制】、邀请人：已绑定 / 未绑定）→ 余额卡（可提现余额 + 眼睛 +
///   【提现】、预估收益）→ 宫格三组；资料加载失败显示错误态与【重试】（不回落游客）；下拉刷新；
/// - 游客：还没有登录 +【登录 / 注册】→ 宫格只有「帮助中心」「设置」（没有铃铛、余额卡与其他宫格）。
/// 返回本页保持滚动位置（被下一页盖住时视图不销毁）；切 Tab 往返按会话级记下的位置滚回。大屏限宽 600 居中。
public struct MeTabScreen: View {
    @ObservedObject var host: MePageHost<MeTabController>
    @ObservedObject var repo: MeRepository
    @ObservedObject var mask: AmountMaskStore
    @ObservedObject var readGate: RetryAfterGate
    let scroll: MeScrollMemory

    public init(host: MePageHost<MeTabController>, mask: AmountMaskStore, scroll: MeScrollMemory) {
        self.host = host
        repo = host.controller.deps.repo
        self.mask = mask
        readGate = host.controller.deps.gates.read
        self.scroll = scroll
    }

    public var body: some View {
        MeTabBody(controller: host.controller, host: host, repo: repo, mask: mask, readGate: readGate, scroll: scroll)
            .onAppear { host.onAppear() }
    }
}

struct MeTabBody: View {
    @ObservedObject var controller: MeTabController
    /// 执行时取「这一次进入」的执行器（onChange 闭包里的 `controller` 可能是上一次渲染的，R3-01）。
    let host: MePageHost<MeTabController>
    @ObservedObject var repo: MeRepository
    @ObservedObject var mask: AmountMaskStore
    @ObservedObject var readGate: RetryAfterGate
    let scroll: MeScrollMemory
    @StateObject private var notices = MeToastQueue()

    var texts: MeTexts {
        controller.deps.texts
    }

    var body: some View {
        let snapshot = repo.state
        let actions = MeTabActions.make(controller, snapshot)
        let view = controller.view(snapshot, masked: mask.hidden)
        VStack(spacing: 0) {
            titleBar(view, actions)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // 顶部锚点：没滚动时记它（滚回顶部，不把引导条滚出去）
                        Color.clear.frame(height: 0)
                            .id("me.section.top")
                            .background(MeSectionTops.reader("me.section.top"))
                        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                            if view.loginPrompt {
                                guestCard(actions)
                                    .id("me.section.guest")
                            } else {
                                memberBody(snapshot, view, actions)
                            }
                            grid(view, actions)
                        }
                        .padding(.top, CouliSpacing.s2)
                    }
                    .padding(.horizontal, CouliSpacing.s4)
                    .padding(.bottom, CouliSpacing.s4)
                    .meContentWidth()
                    .onPreferenceChange(MeSectionTops.self) { tops in
                        let top = tops.filter { $0.value > -1 }.min { $0.value < $1.value }?.key
                            ?? tops.max { $0.value < $1.value }?.key
                        scroll.remember(top, for: controller.identity)
                    }
                }
                .coordinateSpace(name: MeSectionTops.space)
                .refreshable {
                    guard controller.refresh(pull: true) else { return }
                    for _ in 0..<100 where repo.state.refreshing || repo.state.phase == .loading {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                .onAppear {
                    if let anchor = scroll.anchor(for: controller.identity) {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
            }
            .accessibilityIdentifier("me.scroll")
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(view.loginPrompt ? "me.guestPage" : "me.page")
        .couliToast($notices.current, topInset: CouliHitTarget.minimum)
        // 复制结果用发布值，不用 onChange：消费本身也改这个值，一帧里变两次时 onChange 会丢后一次（连按复制丢提示）。
        // 发布时新值还没落到属性上，所以消费放到下一拍。读取失败读执行时的 repo.state 与此刻的执行器（闭包里不读本次渲染捕获的 `snapshot`，R3-01）
        .onReceive(controller.$toast) { notice in
            guard let notice else { return }
            let current = controller
            notices.enqueueResult(notice, texts: current.deps.texts, owner: current)
            Task { @MainActor in current.consumeToast(notice.id) }
        }
        .onChange(of: snapshot.error) { _ in showReadError() }
        // 执行器换了（换身份、撤回同意、退出、新的一次进入）：`@StateObject` 不随它重建，排队与正在显示的提示在这里作废
        .onChange(of: ObjectIdentifier(controller)) { _ in notices.drop() }
    }

    /// 已有资料时的读取失败 → 轻提示（带 trace6）。只消费此刻有效的执行器（这一次进入、身份仍是当前身份）自己发起的失败；设置页发起的
    /// 刷新失败由设置页呈现（R1-05，不被盖在下面的「我的」吞掉）。
    private func showReadError() {
        let state = repo.state
        let current = host.controller
        guard let error = state.error, state.me != nil, current.alive, state.identity == current.identity,
              state.errorSource == ObjectIdentifier(current)
        else { return }
        notices.enqueueFailure(error.message(current.deps.texts), owner: current)
        repo.consumeError(error.id)
    }

    /// 标题栏：高 44，「我的」22/600 左对齐；铃铛视觉 24、命中 44。G04：没有未读数，不画红点、不读「有未读」。
    private func titleBar(_ view: MeViewModel, _ actions: MeTabActions) -> some View {
        HStack(spacing: CouliSpacing.s2) {
            MeText(texts.text("me.title"), style: .title, weight: .couliSemibold, probe: "me.title")
                .foregroundColor(CouliColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: CouliSpacing.s2)
            if view.bell {
                Button(action: actions.bell) {
                    CouliIconView(.bell)
                        .foregroundColor(CouliColor.textPrimary)
                        .meProbe("me.bell.icon", role: "icon")
                        .couliHitTarget()
                        .meProbe("me.bell.hit", role: "hit")
                }
                .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
                // 图标贴页边 16，命中区向外溢出
                .padding(.trailing, (CouliComponentMetric.iconDefault - CouliHitTarget.minimum) / 2)
                .accessibilityLabel(Text(verbatim: texts.text("me.bell")))
                .accessibilityIdentifier("me.bell")
            }
        }
        .padding(.horizontal, CouliSpacing.s4)
        .frame(minHeight: CouliHitTarget.minimum)
        .meContentWidth()
        .meProbe("me.titleBar", role: "bar")
    }

    /// 游客卡（设计稿 MeGuest）：白卡内边距 16、纵向 16，头像 56 + 右栏（17/600、14 次文字）→ 通栏【登录 / 注册】。
    private func guestCard(_ actions: MeTabActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s4) {
            HStack(spacing: CouliSpacing.s3) {
                MeAvatar()
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    MeText(texts.text("me.guest.title"), style: .body, weight: .couliSemibold, probe: "me.guest.title")
                        .foregroundColor(CouliColor.textPrimary)
                    MeText(texts.text("me.guest.desc"), style: .footnote, probe: "me.guest.desc")
                        .foregroundColor(CouliColor.textSecondary)
                }
            }
            CouliButton(texts.text("me.guest.login"), fillsWidth: true, action: actions.login)
                .meProbe("me.guest.login", role: "button")
                .accessibilityIdentifier("me.login")
        }
        .couliCard(padding: CouliSpacing.s4)
        .meProbe("me.guest", role: "card")
        .background(MeSectionTops.reader("me.section.guest"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("me.guest")
    }

    @ViewBuilder
    private func memberBody(_ snapshot: MeSnapshot, _ view: MeViewModel, _ actions: MeTabActions) -> some View {
        if controller.guideVisible {
            guideBar(actions)
        }
        if let me = snapshot.identity == controller.identity ? snapshot.me : nil {
            identityCard(me, view, actions)
                .id("me.section.identity")
            MeHeroCard(view: view, texts: texts, actions: actions)
                .background(MeSectionTops.reader("me.section.balance"))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("me.balance")
                .id("me.section.balance")
        } else if snapshot.phase == .error, snapshot.identity == controller.identity {
            ErrorState(
                title: texts.text("me.load_failed"), message: snapshot.error?.message(texts),
                retryTitle: texts.text("me.retry"), retry: actions.refresh
            )
            .disabled(readGate.blocked)
            .frame(minHeight: CouliSpacing.s16 * 4)
            .meProbe("me.error", role: "state")
            .accessibilityIdentifier("me.error")
        } else {
            MeSkeleton()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: texts.text("me.loading")))
                .accessibilityIdentifier("me.loading")
        }
    }
}

/// 加载骨架（无稿，brief §2-10）：身份卡块（56 圆 + 两条横块）→ 余额卡块 → 一组宫格块，块都用 `background.muted`；读屏由调用方整块读「加载中」。
private struct MeSkeleton: View {
    private let card = RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)

    var body: some View {
        VStack(spacing: CouliSpacing.s3) {
            HStack(spacing: CouliSpacing.s3) {
                Circle().fill(CouliColor.backgroundMuted)
                    .frame(width: CouliSpacing.s12 + CouliSpacing.s2, height: CouliSpacing.s12 + CouliSpacing.s2)
                    .meProbe("me.skeleton.avatar", role: "skeleton")
                VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                    SkeletonBlock(width: CouliSpacing.s12 * 2, height: CouliSpacing.s4)
                        .meProbe("me.skeleton.name", role: "skeleton")
                    SkeletonBlock(width: CouliSpacing.s12 * 3, height: CouliSpacing.s3)
                        .meProbe("me.skeleton.invite", role: "skeleton")
                }
            }
            .couliCard(padding: CouliSpacing.s4)
            card.fill(CouliColor.backgroundMuted)
                .frame(height: CouliSpacing.s12 * 3 + CouliSpacing.s8)
                .meProbe("me.skeleton.balance", role: "skeleton")
            card.fill(CouliColor.backgroundMuted)
                .frame(height: CouliSpacing.s12 * 2 + CouliSpacing.s6)
                .meProbe("me.skeleton.grid", role: "skeleton")
        }
    }
}

/// 各块在滚动区里的顶部位置（记「最上面那一块」，切 Tab 往返时滚回，共性第 27 条）。
struct MeSectionTops: PreferenceKey {
    static let space = "me.scroll.space"
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }

    static func reader(_ id: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: MeSectionTops.self, value: [id: proxy.frame(in: .named(space)).maxY]
            )
        }
    }
}
