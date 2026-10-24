import Foundation
import Web
import WebKit
import XCTest

/// 仅替换系统清理端口：五类分别记完成，绝不替另一类顺手清数据。
/// 默认调用真实清理实现；失败、未确认和挂起都在指定类的端口上注入。
@MainActor
final class FX25CleanupProbe {
    enum Fault: CaseIterable {
        case throwing, unconfirmed, timeout
    }

    struct InjectedFailure: Error {}
    static let kinds: [TrustedWebDataKind] = [.cookies, .localStorage, .sessionStorage, .indexedDB, .httpCache]
    var fault: (kind: TrustedWebDataKind, mode: Fault)?
    var held: TrustedWebDataKind?
    var entered: [TrustedWebDataKind] = []
    var completed: [TrustedWebDataKind] = []
    var stores: [WKWebsiteDataStore] = []
    var trace: [String] = []
    var pendingFile: URL?
    var beforeClear: (() -> Void)?
    /// 每项清理开始的时刻（同步记录，不 await、不往返 WebContent，不改变清理时序；评审 r2 S2-R2-06）。
    var begins: [(kind: TrustedWebDataKind, at: Date)] = []
    /// 某类真实清理确认之后同步回调（不 await）：只能做「放出被扣住的响应」这类不阻塞的动作。
    var onConfirmed: ((TrustedWebDataKind) -> Void)?
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func clear(_ kind: TrustedWebDataKind, store: WKWebsiteDataStore, documents: [WKWebView]) async throws -> Bool {
        entered.append(kind)
        stores.append(store)
        trace.append("begin:\(kind)")
        begins.append((kind, Date()))
        if let pendingFile {
            XCTAssertTrue(FileManager.default.fileExists(atPath: pendingFile.path), "持久标记必须先于每项清理")
        }
        beforeClear?()
        if held == kind {
            await withCheckedContinuation { continuations.append($0) }
        }
        if let fault, fault.kind == kind {
            switch fault.mode {
            case .throwing: throw InjectedFailure()
            case .unconfirmed: return false
            case .timeout:
                // 故意不响应取消：操作系统回调迟到不能让超时后的旧事务恢复页面。
                await withCheckedContinuation { continuations.append($0) }
            }
        }
        let result = try await TrustedWebDataCleaner.clear(kind: kind, in: store, documents: documents)
        if result {
            onConfirmed?(kind)
            completed.append(kind)
            trace.append("done:\(kind)")
        }
        return result
    }

    func release() {
        held = nil
        let waiting = continuations
        continuations = []
        waiting.forEach { $0.resume() }
    }

    func resetCounts() {
        entered = []
        completed = []
        stores = []
        trace = []
        begins = []
    }
}
