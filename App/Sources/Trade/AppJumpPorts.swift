import ClientCore
import Clipboard
import CouliNetwork
import Foundation
import Generated
import Trade
import TradeJump
import UIKit

/// 外跳的 iOS 系统能力（APP-06b；03 §4.5、BR-ATTR-27）。只在用户点击触发的流程里调用。
///
/// - 安装检测：apps.json 的 iOS query_schemes 只是候选（status=candidate，taobao / tbopen、openApp.jdMobile，拼多多为空），
///   LSApplicationQueriesSchemes 由 CT-05 从 apps.json 生成、本包还没有声明；没声明的 scheme 用 canOpenURL 一律得 false，
///   不能当成「未安装」。所以生产包恒为 unknown（G05，TODO(N-28) I 段），不臆造检测结果。
/// - scheme：`UIApplication.open`（没有 App 处理即失败，不落到浏览器）；universal_link：`.universalLinksOnly`（只拉起认领了该链接的
///   App，没装即失败）；h5：交系统浏览器（`UIApplication.open` 打开 http(s) 链接；该域名被别的 App 认领为通用链接时系统会优先拉起
///   那个 App，iOS 没有「只用浏览器打开」的公开接口，记 rule-gaps I 段），不进本 App 的两类容器。
/// - copy_tpwd：写系统剪贴板只经剪贴板模块的写入口（APP-07，brief §2.3）：先记 hash（之后不再识别它），记不上不写、返回失败。
/// - 本类不含任何模拟安装状态 / 模拟外跳结果的开关或分支（共性第 42 条）：截图、UI 测试用的假端口是包在它外面的
///   `DebugJumpPorts`（App/Sources/Debug，只在 Debug / Staging 编译），Release 制品扫描查它的类名、字段名与启动参数。
@MainActor
final class AppJumpPorts: JumpPorts {
    private let writer: ClipboardWriter?

    /// writer：App 写剪贴板的唯一入口（没有时不写，copy 返回失败）。
    init(writer: ClipboardWriter?) {
        self.writer = writer
    }

    func installed(_: String) -> String {
        TradeConstants.installedUnknown
    }

    func launchApp(type: String, value: String) async -> Bool {
        guard let url = URL(string: value), url.scheme != nil else { return false }
        if type == JumpTypes.universalLink {
            guard ["https"].contains(url.scheme?.lowercased() ?? "") else { return false }
            return await open(url, options: [.universalLinksOnly: true])
        }
        // scheme 步骤不能是网页链接（那是 h5 步骤的事，不能借它绕过浏览器提示）
        guard !["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return await open(url, options: [:])
    }

    func openBrowser(_ value: String) async -> Bool {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return false
        }
        return await open(url, options: [:])
    }

    func copy(_ text: String) -> Bool {
        writer?.write(text) ?? false
    }

    private func open(_ url: URL, options: [UIApplication.OpenExternalURLOptionsKey: Any]) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: options) { opened in
                continuation.resume(returning: opened)
            }
        }
    }
}

/// link_jump 上报（经 Tracker 本地队列；上报 sink 仍为 TODO(N-20)）。业务字段来自 `LinkJumpEvents.build`；公共字段 page：购买可从详情
/// 或搜索结果发起，三端统一记 ProductDetail（A14 同口径，TODO(N-28)），startup 同样记 ProductDetail。
/// 购买外跳的步骤带发起时固定的请求归属（APP-08 iOS r3g NEW-06）：交给埋点队列之前与当前归属比较，变了（换号、切环境）就丢弃；
/// 没变时 user_id 用固定归属里的账号编码，不在编码时再读当前会话。
@MainActor
final class AppLinkJumpSink: LinkJumpSink {
    static let page = "ProductDetail"
    private let track: @MainActor (TrackEvent, TrackAttribution?) -> Void
    /// 此刻的请求归属（与购买来源同一种读取，只用于比较）。
    private let ownership: @MainActor () -> RequestOwnership

    init(
        track: @escaping @MainActor (TrackEvent, TrackAttribution?) -> Void,
        ownership: @escaping @MainActor () -> RequestOwnership
    ) {
        self.track = track
        self.ownership = ownership
    }

    func report(_ fields: TradeObject) {
        report(fields, owner: nil)
    }

    func report(_ fields: TradeObject, owner: RequestOwnership?) {
        guard let event = Self.event(fields) else { return }
        guard let owner else {
            // 没有固定归属的事件（phase=startup）：照旧按当前会话编码
            track(event, nil)
            return
        }
        guard ownership() == owner else { return }
        track(event, TrackAttribution(userId: owner.account))
    }

    /// 业务字段 → 生成函数（枚举不认识的值不上报，不臆造）。
    static func event(_ fields: TradeObject) -> TrackEvent? {
        typealias Values = TrackerEvents.LinkJump
        guard let phase = (fields["phase"] as? String).flatMap(Values.PhaseValue.init(rawValue:)),
              let platform = (fields["union_platform"] as? String).flatMap(Values.UnionPlatformValue.init(rawValue:)),
              let step = (fields["step"] as? String).flatMap(Values.StepValue.init(rawValue:)),
              let result = (fields["result"] as? String).flatMap(Values.ResultValue.init(rawValue:))
        else { return nil }
        let duration = (fields["duration_ms"] as? NSNumber)?.intValue
        let installed = (fields["installed"] as? String).flatMap(Values.InstalledValue.init(rawValue:))
        return TrackerEvents.linkJump(
            page: page, phase: phase, attemptId: fields["attempt_id"] as? String, linkId: fields["link_id"] as? String,
            unionPlatform: platform, step: step, result: result, durationMs: duration, installed: installed
        )
    }
}

/// 百川（联盟 SDK）的启动初始化：只由 PrivacyGate.onConsented 的联盟步骤调用（03 §4.1、AGENTS.md 硬规则 5），每个同意周期一次。
/// 本包没有百川 SDK（不可用实现），初始化失败即 phase=startup 上报 sdk_init_failed（BR-ATTR-27 淘宝行）；埋点接上之前发生的先记下，
/// 接上后补报。
@MainActor
final class AppTradeStartup {
    static let shared = AppTradeStartup()
    let baichuan: BaichuanAdapter = UnavailableBaichuan()
    private var unreported = 0
    var reporter: (@MainActor () -> Void)? {
        didSet { flush() }
    }

    /// PrivacyGate 联盟步骤。
    func unionInitStep() {
        guard !baichuan.initialize() else { return }
        unreported += 1
        flush()
    }

    private func flush() {
        guard let reporter else { return }
        while unreported > 0 {
            unreported -= 1
            reporter()
        }
    }
}
