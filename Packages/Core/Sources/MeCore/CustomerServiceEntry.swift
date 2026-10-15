import Combine
import Foundation

/// 统一客服出口要的系统能力（App 给；都在主线程调用）。
@MainActor
public protocol CustomerServicePorts: AnyObject {
    /// /v1/config.kf.url（生效配置：当前 → LKG → 包内）；没有为 nil。
    func kfUrl() -> String?
    /// 微信是否已装：yes / no / unknown（只查生成物登记的查询项；iOS 生成的 Info.plist 没有 LSApplicationQueriesSchemes，现为 unknown）。
    func wechatInstalled() -> String
    /// 经系统打开外部链接（UIApplication.open，不在 App 内 WebView 加载）；拉不起返回 false。
    func openExternal(_ url: String) async -> Bool
    /// 经 APP-07 统一写入口写剪贴板（先记自写 hash 并确认落盘）；返回是否写入。
    func copy(_ text: String) -> Bool
    /// 经 Router 打开帮助中心（Help，h5）。
    func openHelp()
}

/// 正在显示的客服半屏（`serial` 每次打开或换版式都加一；按钮回调捕获它，过期的点击不生效）。
public struct CsSheet: Equatable, Sendable, Identifiable {
    public let serial: Int
    public let decision: CsDecision
    public let fromRoute: String

    public var id: Int {
        serial
    }
}

/// 统一客服出口（brief §2.9，G20，BR-ID-04 细则「未安装微信时」、BR-ID-33 细则、AC-S1-88 ④ / AC-S1-134 ④）。三端 Core 一个入口 `open`，
/// App 层给界面（CsHandoff / CsWechatMissing / CsOpenFailed 三张半屏）：
/// - 决策只看 kf.url 与微信是否已装（`CsEntryDecision`）；链接原样 kf.url（`CsLink`），不拼任何账号标识与发起页路由名；
/// - 已装或未知 → CsHandoff，【打开微信】经系统打开链接，拉不起 → CsOpenFailed（【重试】【复制客服链接】【去帮助中心】）；
/// - 未装 → CsWechatMissing（不直接打开链接）；kf 缺失或不是 https → 只有【去帮助中心】的降级半屏；
/// - 复制客服链接只走统一写入口，成功提示 cs.copy_link.done（半屏里 polite 播报一次，A17）；
/// - 桥 cs.open（APP-14）复用 `openForBridge`（返回 opened）。
@MainActor
public final class CustomerServiceEntry: ObservableObject {
    public static let copied = "cs.copy_link.done"
    public static let copyFailed = "me.copy_failed"
    static let failed = "failed"

    @Published public private(set) var sheet: CsSheet?
    @Published public private(set) var toast: MeNotice?
    private weak var ports: CustomerServicePorts?
    private var serials = 0
    private var opening = false

    public init(ports: CustomerServicePorts) {
        self.ports = ports
    }

    private func nextSerial() -> Int {
        serials += 1
        return serials
    }

    /// 原样 kf.url（G20：不拼账号标识，也不拼发起页路由名）。
    private func link(_ fromRoute: String) -> String? {
        ports?.kfUrl().map { CsLink.build(kfUrl: $0, fromRoute: fromRoute, account: [:]) }
    }

    /// 打开客服出口（「我的」宫格、RiskNotice、申诉页、登录页、授权管理、订单、钱包等），显示对应半屏。
    public func open(from route: String) {
        guard let ports else { return }
        let decision = CsEntryDecision.model(kfUrl: link(route), wechat: ports.wechatInstalled(), openResult: nil)
        toast = nil
        sheet = CsSheet(serial: nextSerial(), decision: decision, fromRoute: route)
    }

    /// 桥 cs.open 的入口（APP-14 复用）：能直接打开就打开并返回 true；不能（未装、拉不起、没有链接）返回 false，并显示对应半屏。
    public func openForBridge(from route: String) async -> Bool {
        guard let ports else { return false }
        let url = link(route)
        let decision = CsEntryDecision.model(kfUrl: url, wechat: ports.wechatInstalled(), openResult: nil)
        if decision.sheetRaw == CsEntryDecision.handoff, let target = decision.openUrl,
           await ports.openExternal(target) {
            return true
        }
        let shown = decision.sheetRaw == CsEntryDecision.handoff
            ? CsEntryDecision.model(kfUrl: url, wechat: ports.wechatInstalled(), openResult: Self.failed) : decision
        sheet = CsSheet(serial: nextSerial(), decision: shown, fromRoute: route)
        return false
    }

    private func current(_ serial: Int) -> CsSheet? {
        sheet?.serial == serial ? sheet : nil
    }

    /// 【打开微信】/【重试】：拉起成功关闭半屏，拉不起换成 CsOpenFailed。
    public func openWechat(_ serial: Int) {
        guard let sheet = current(serial), let url = sheet.decision.openUrl, !opening, let ports else { return }
        opening = true
        Task { @MainActor [weak self, weak ports] in
            guard let ports else { return }
            let opened = await ports.openExternal(url)
            guard let self else { return }
            opening = false
            guard current(serial) != nil else { return }
            if opened {
                self.sheet = nil
            } else {
                self.sheet = CsSheet(
                    serial: nextSerial(),
                    decision: CsEntryDecision.model(
                        kfUrl: url,
                        wechat: ports.wechatInstalled(),
                        openResult: Self.failed
                    ),
                    fromRoute: sheet.fromRoute
                )
            }
        }
    }

    /// 【复制客服链接】：复制的是 kf.url 原串（同一入口），成功提示 cs.copy_link.done，写不进提示复制失败。
    public func copyLink(_ serial: Int) {
        guard let text = current(serial)?.decision.copyText, let ports else { return }
        let written = ports.copy(text)
        toast = MeNotice(written ? Self.copied : Self.copyFailed, id: nextSerial(), assertive: false)
    }

    /// 【去帮助中心】：关闭半屏后经 Router 打开 Help。
    public func goHelp(_ serial: Int) {
        guard current(serial) != nil else { return }
        sheet = nil
        ports?.openHelp()
    }

    public func dismiss(_ serial: Int) {
        if current(serial) != nil {
            sheet = nil
        }
    }

    public func consumeToast(_ id: Int) {
        if toast?.id == id {
            toast = nil
        }
    }

    /// 撤回同意、切换环境、会话换代：收起半屏与提示。
    public func invalidate() {
        sheet = nil
        toast = nil
    }
}
