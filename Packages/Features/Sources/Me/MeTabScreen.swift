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
            toggleMask: { [weak controller] in controller?.toggleMask() },
            openGuide: { [weak controller] in controller?.openGuide() },
            closeGuide: { [weak controller] in controller?.closeGuide() },
            tap: { [weak controller] cell in controller?.tap(cell) }
        )
    }
}

/// 「我的」Tab 根（设计稿 Me、MeGuest、MeHidden、MeMinor；AdaptBackRestore）：
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
    @State private var toast: CouliToastMessage?

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
                    VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                        // 顶部锚点：没滚动时记它（滚回顶部，不把引导条滚出去）
                        Color.clear.frame(height: 0)
                            .id("me.section.top")
                            .background(MeSectionTops.reader("me.section.top"))
                        if view.loginPrompt {
                            guestCard(actions)
                                .id("me.section.guest")
                        } else {
                            memberBody(snapshot, view, actions)
                        }
                        grid(view, actions)
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
        .couliToast($toast)
        // 闭包里不读本次渲染捕获的 `snapshot` / `controller`（iOS 16 上是上一帧的值，首次提示会丢、之后会显示上一条，R3-01）：
        // 复制提示用回调给的新值；读取失败读执行时的 repo.state 与此刻的执行器
        .onChange(of: controller.toast) { notice in
            let current = host.controller
            guard let notice, current.toast?.id == notice.id else { return }
            showToast(notice) { current.consumeToast($0) }
        }
        .onChange(of: snapshot.error) { _ in showReadError() }
    }

    /// 已有资料时的读取失败 → 轻提示（带 trace6）。只消费此刻有效的执行器（这一次进入、身份仍是当前身份）自己发起的失败；设置页发起的
    /// 刷新失败由设置页呈现（R1-05，不被盖在下面的「我的」吞掉）。
    private func showReadError() {
        let state = repo.state
        let current = host.controller
        guard let error = state.error, state.me != nil, current.alive, state.identity == current.identity,
              state.errorSource == ObjectIdentifier(current)
        else { return }
        showToast(error) { repo.consumeError($0) }
    }

    private func showToast(_ notice: MeNotice, consume: (Int) -> Void) {
        toast = MeToastMessage.make(notice, texts: texts)
        consume(notice.id)
    }

    private func titleBar(_ view: MeViewModel, _ actions: MeTabActions) -> some View {
        HStack(spacing: CouliSpacing.s2) {
            Text(verbatim: texts.text("me.title"))
                .couliFont(.title, weight: .couliSemibold)
                .foregroundColor(CouliColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: CouliSpacing.s2)
            if view.bell {
                // G04：没有未读数，不画红点、不读「有未读」
                Button(action: actions.bell) {
                    CouliIconView(.bell)
                        .foregroundColor(CouliColor.textPrimary)
                        .couliHitTarget()
                }
                .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
                .accessibilityLabel(Text(verbatim: texts.text("me.bell")))
                .accessibilityIdentifier("me.bell")
            }
        }
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.vertical, CouliSpacing.s2)
        .frame(minHeight: CouliHitTarget.minimum)
        .meContentWidth()
    }

    private func guestCard(_ actions: MeTabActions) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            HStack(spacing: CouliSpacing.s3) {
                avatar
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    Text(verbatim: texts.text("me.guest.title"))
                        .couliFont(.title, weight: .couliSemibold)
                        .foregroundColor(CouliColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: texts.text("me.guest.desc"))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            CouliButton(texts.text("me.guest.login"), fillsWidth: true, action: actions.login)
                .accessibilityIdentifier("me.login")
        }
        .couliCard(padding: CouliSpacing.s5)
        .background(MeSectionTops.reader("me.section.guest"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("me.guest")
    }

    var avatar: some View {
        ZStack {
            Circle().fill(CouliColor.backgroundMuted)
            CouliIconView(.user, size: CouliGuideMetric.iconMedium + CouliSpacing.s3)
                .foregroundColor(CouliColor.textSecondary)
        }
        .frame(width: CouliSpacing.s16, height: CouliSpacing.s16)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func memberBody(_ snapshot: MeSnapshot, _ view: MeViewModel, _ actions: MeTabActions) -> some View {
        if controller.guideVisible {
            guideBar(actions)
        }
        if let me = snapshot.identity == controller.identity ? snapshot.me : nil {
            identityCard(me, view, actions)
                .id("me.section.identity")
            balanceCard(view, actions)
                .id("me.section.balance")
        } else if snapshot.phase == .error, snapshot.identity == controller.identity {
            ErrorState(
                title: texts.text("me.load_failed"), message: snapshot.error?.message(texts),
                retryTitle: texts.text("me.retry"), retry: actions.refresh
            )
            .disabled(readGate.blocked)
            .frame(minHeight: CouliSpacing.s16 * 4)
            .accessibilityIdentifier("me.error")
        } else {
            VStack(spacing: CouliSpacing.s3) {
                SkeletonBlock(height: CouliSpacing.s16 + CouliSpacing.s8)
                SkeletonBlock(height: CouliSpacing.s16 * 2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: texts.text("me.loading")))
            .accessibilityIdentifier("me.loading")
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
