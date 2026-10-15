import Combine
import Foundation

/// 关于页执行器（About 路由；brief §2.12，G22、G23；BR-ID-15、F-OBS-06、AC-S1-136）：「关于凑狸」、App 名、版本与构建号；AI 公示只显示
/// `agent.filing_text` 原文（空串、未配置整节不显示）；备案号行不显示；【复制诊断信息】只含 G23 白名单字段，走统一写入口，成功提示
/// about.copy_diagnostics.done（polite 播报一次）。
@MainActor
public final class AboutController: ObservableObject {
    public static let copiedKey = "about.copy_diagnostics.done"

    public let deps: MeDeps
    @Published public private(set) var toast: MeNotice?
    private var left = false
    private var ids = 0

    public init(deps: MeDeps) {
        self.deps = deps
    }

    public var version: String {
        deps.env.appVersion
    }

    public var build: String {
        deps.env.appBuild
    }

    /// AI 公示（agent.filing_text 原文；没有为 nil）。
    public var filing: String? {
        let agent = deps.env.configObject("agent") as? [String: Any]
        return AboutView.filing(agent?["filing_text"] as? String)
    }

    /// 诊断信息的行（只含白名单字段，固定英文字段名，每行一项）。
    public func diagnostics() -> [String] {
        Diagnostics.lines(fields: deps.env.diagnosticsFields())
    }

    public func copyDiagnostics() {
        guard !left else { return }
        let written = deps.env.copy(diagnostics().joined(separator: "\n"))
        ids += 1
        toast = MeNotice(written ? Self.copiedKey : MeTabController.copyFailed, id: ids, assertive: false)
    }

    public func consumeToast(_ id: Int) {
        if toast?.id == id {
            toast = nil
        }
    }

    public func leave() {
        left = true
        toast = nil
    }
}
