#if DEBUG
import Clipboard
import DesignSystem
import Foundation
import HomeCore
import SwiftUI
import UIKit

/// 首页视觉 UI 测试场景的读数、场景推进与信号（APP-11v；只在 Debug / Staging 编译）。
extension DebugHomeVisual {
    // MARK: - 布局测量接收方

    func store(_ record: CouliLayoutProbeRecord) {
        guard probes[record.id] != record else { return }
        probes[record.id] = record
        layoutDirty = true
        layoutChangedAt = Date()
    }

    func drop(_ id: String) {
        if probes.removeValue(forKey: id) != nil {
            layoutDirty = true
            layoutChangedAt = Date()
        }
    }

    // MARK: - 读数

    func poll() {
        guard let home else { return }
        let state = home.controller.state
        let counts = port.counts
        let images = DebugHomeVisualNetworkGuard.stats
        let level = home.controller.identity.level.rawValue
        let signature = "\(clipboard?.prompt?.id ?? -1)|\(clipboard?.result?.id ?? -1)|\(level)"
        if signature != nativeSignature {
            if !nativeSignature.isEmpty {
                revision += 1
            }
            nativeSignature = signature
        }
        let imagesIdle = images.started == images.finished && images.started == lastImages
        lastImages = images.started
        let settled = counts.inflight == 0 && !state.refreshing && imagesIdle
        let object = diagnosticsObject(state: state, level: level, counts: counts, images: images, settled: settled)
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8), text != diagnostics {
            diagnostics = text
        }
        // 有记录新增 / 移除（懒加载行进出视口）时下一拍就发，免得滚动停下后读到缺卡的旧读数；只是位置变化时停稳 0.3 秒再发
        let ids = Set(probes.keys)
        if layoutDirty, ids != publishedProbeIDs || Date().timeIntervalSince(layoutChangedAt) > 0.3 {
            layoutDirty = false
            publishedProbeIDs = ids
            publishLayout()
        }
        advanceScene(settled: settled, state: state, counts: counts)
        if let longFeed {
            longFeed.poll(state: state, probes: probes)
            if ready != nil {
                longFeed.ready()
            }
        }
    }

    private func diagnosticsObject(state: HomeUiState, level: String, counts: DebugHomeVisualPort.Counts,
                                   images: DebugHomeVisualNetworkGuard.Stats, settled: Bool) -> [String: Any] {
        let source: Any = state.source.map { $0 == .bundled ? "bundled" : $0.rawValue } ?? NSNull()
        let identity: Any = promptIdentity ?? NSNull()
        return [
            "level": level,
            "scene": settings.scene,
            "pageVersion": state.pageVersion ?? 0,
            "source": source,
            "sectionCounts": Dictionary(state.sections.map { ($0.id, $0.items.count) }, uniquingKeysWith: { $1 }),
            "pageRequests": counts.pages,
            "sectionRequests": counts.sections,
            "parseRequests": clipboard?.parseCount ?? 0,
            "clipboardReads": clipboard?.readCount ?? 0,
            "promptIdentity": identity,
            "unexpectedRequests": images.unexpected,
            "pasteControlClass": pasteControlClass(),
            "nativeRevision": revision,
            "settled": settled,
        ]
    }

    private func publishLayout() {
        let list = probes.values.sorted { $0.id < $1.id }.map { record -> [String: Any] in
            ["id": record.id, "role": record.role, "card": record.card, "text": record.text,
             "rect": [record.rect.minX, record.rect.minY, record.rect.width, record.rect.height].map(Double.init),
             "naturalWidth": Double(record.naturalWidth), "fontSize": Double(record.fontSize),
             "baseFontSize": Double(record.baseFontSize)]
        }
        if let data = try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            layout = text
        }
    }

    private var promptIdentity: String? {
        if let prompt = clipboard?.prompt {
            return "prompt-\(prompt.id)"
        }
        if let result = clipboard?.result, AppClipboard.isHomeOrigin(result.origin) {
            return "result-\(result.id)"
        }
        return nil
    }

    /// 场景推进：只经真实出口（推进可控时钟、用户粘贴的交付回调），条件满足后才发 ready。
    private func advanceScene(settled: Bool, state: HomeUiState, counts: DebugHomeVisualPort.Counts) {
        guard ready == nil else { return }
        let scene = settings.scene
        if scene == "loading" {
            if counts.pages >= 1 {
                markReady()
            }
        } else if scene == "invalid" {
            advanceInvalid(settled: settled, state: state, counts: counts)
        } else if scene == "bundled" {
            advanceBundled(settled: settled, state: state, counts: counts)
        } else if scene == "invite" {
            advanceInvite(settled: settled, state: state)
        } else if Self.stableScenes.contains(scene) || scene.hasPrefix("stress_") || scene.hasPrefix("no_rebate_") {
            readyWhenStable(settled: settled, state: state)
        } else if Self.overlayScenes.contains(scene) {
            advanceOverlay(settled: settled, state: state)
        }
    }

    private static let stableScenes: Set = [
        "normal",
        "rank",
        "lkg",
        "feed_failure",
        "empty",
        "banner_notice",
        "long_feed",
    ]

    /// 最后防线：无 LKG、网络失败、包内默认不可解；推进可控时钟越过 1500ms 兜底，等真实 loadFailed。
    private func advanceInvalid(settled: Bool, state: HomeUiState, counts: DebugHomeVisualPort.Counts) {
        if sceneStep == 0, counts.pages >= 1, counts.inflight == 0 {
            sceneStep = 1
            clock.advance(1500)
        } else if sceneStep == 1, state.loadFailed != nil, settled {
            markReady()
        }
    }

    /// 包内默认：无 LKG、首页断网；推进可控时钟越过 1500ms 兜底（D5，同生产），落到包内默认后等稳定。
    private func advanceBundled(settled: Bool, state: HomeUiState, counts: DebugHomeVisualPort.Counts) {
        if sceneStep == 0, counts.pages >= 1, counts.inflight == 0 {
            sceneStep = 1
            clock.advance(1500)
        } else if sceneStep == 1 {
            readyWhenStable(settled: settled, state: state)
        }
    }

    /// 邀请：用户点了粘贴控件后系统交付的文本（既有假邀请码），经真实识别产生可关闭的邀请提示条。
    private func advanceInvite(settled: Bool, state: HomeUiState) {
        guard state.source != nil, settled, let clipboard else { return }
        if sceneStep == 0 {
            sceneStep = 1
            clipboard.pasted(entry: ManualPasteAction.entryHome, text: "好友邀请你一起省钱，邀请码 K7M3QX")
        } else if case .inviteConfirm = clipboard.result?.kind {
            markReady()
        }
    }

    func readyWhenStable(settled: Bool, state: HomeUiState) {
        guard state.source != nil, settled else {
            quietTicks = 0
            return
        }
        quietTicks += 1
        if quietTicks >= 3 {
            markReady()
        }
    }

    func markReady() {
        ready = settings.name
    }

    var clockText: String {
        String(clock.advanced)
    }

    var widthText: String {
        String(Int(width))
    }

    /// 实际 UIKit 粘贴控件的类型名（从窗口里按可访问标识找到的那个实例）。找到后记住该实例，仍在窗口里就不再每 0.2 秒遍历整棵
    /// 视图树（减轻读数轮询占用的主线程，UI 测试取快照 / 等空闲不被拖慢）。
    private func pasteControlClass() -> String {
        if let view = pasteControl, view.window != nil, view.accessibilityIdentifier == "clipboard.homeCard.paste" {
            return String(describing: type(of: view))
        }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            if let view = Self.find(window, "clipboard.homeCard.paste") {
                pasteControl = view
                return String(describing: type(of: view))
            }
        }
        pasteControl = nil
        return ""
    }

    private static func find(_ view: UIView, _ identifier: String) -> UIView? {
        if view.accessibilityIdentifier == identifier, !(view is UIWindow) {
            return view
        }
        for child in view.subviews {
            if let hit = find(child, identifier) {
                return hit
            }
        }
        return nil
    }

    // MARK: - 信号

    func listen() {
        for name in ["login-hold", "logout", "reader-on", "advance-10000", "width-840", "width-390"] {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), nil,
                { _, _, name, _, _ in
                    guard let raw = name?.rawValue as String? else { return }
                    let command = String(raw.dropFirst(DebugHomeVisual.signalPrefix.count))
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { DebugHomeVisual.shared?.handle(command) }
                    }
                },
                (Self.signalPrefix + name) as CFString, nil, .deliverImmediately
            )
        }
    }

    private func handle(_ command: String) {
        switch command {
        case "login-hold":
            // 经真实短信登录出口（本机假服务）登录；之后的会员 getPage 挂住，游客价值卡只能随真实身份变化消失
            port.hold()
            guard let login else { return }
            let consent = Int64(Date().timeIntervalSince1970 * 1000)
            Task { @MainActor in
                _ = await login.service.login(phone: "13800005678", code: "123456", consentAtMillis: consent,
                                              invite: "", restricted: false)
            }
        case "logout":
            port.release()
            guard let login else { return }
            Task { @MainActor in _ = await login.logout() }
        case "reader-on":
            home?.signals.debugReaderOverride = true
            home?.updateSignals()
        case "advance-10000":
            clock.advance(10000)
            // 时钟读数不是发布属性：推进后通知读数元素重画
            objectWillChange.send()
        case "width-840":
            width = 840
            applyWindowFrame()
        case "width-390":
            width = 390
            applyWindowFrame()
        default:
            break
        }
    }
}

/// 场景画布：真实 RootView 加上请求的字号、深浅色与布局测量接收方，并挂只读调试元素。
/// 画布本身不观察读数（读数每 0.2 秒更新，只重画读数元素，不让整页 RootView 跟着重算）。
struct DebugHomeVisualCanvas<Content: View>: View {
    let visual: DebugHomeVisual
    let content: Content

    var body: some View {
        // 宽高由真实窗口给（DebugHomeVisual.applyWindowFrame 把窗口设成请求的宽高，左上对齐；840 时超出屏幕右侧），
        // 不在 SwiftUI 里另套画框、不缩放
        content
            .environment(\.couliLayoutProbe, visual.probe)
            .environment(\.dynamicTypeSize, visual.dynamicTypeSize)
            .environment(\.colorScheme, visual.settings.dark ? .dark : .light)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.visual.canvas")
            .overlay(alignment: .topLeading) {
                DebugHomeVisualReadouts(visual: visual)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
            .onAppear { visual.sceneAppeared() }
    }
}

/// 只读调试元素（1×1、透明、不可点，放在左上角状态栏区域，不盖住用户可达的节点）。
private struct DebugHomeVisualReadouts: View {
    @ObservedObject var visual: DebugHomeVisual

    var body: some View {
        VStack(spacing: 0) {
            readout("home.visual.ready", visual.ready ?? "")
            readout("home.visual.diagnostics", visual.diagnostics)
            readout("home.visual.layout", visual.layout)
            readout("home.visual.focus", visual.focus)
            readout("home.visual.clock", visual.clockText)
            readout("home.visual.width", visual.widthText)
        }
    }

    @ViewBuilder private func readout(_ id: String, _ value: String) -> some View {
        if id != "home.visual.ready" || !value.isEmpty {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: id))
                .accessibilityValue(Text(verbatim: value))
                .accessibilityIdentifier(id)
        }
    }
}

#endif
