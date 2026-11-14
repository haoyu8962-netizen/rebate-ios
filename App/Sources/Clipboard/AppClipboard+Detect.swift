import Clipboard
import Foundation

/// 自动识别的判定与探测回调（从 AppClipboard 主体原样移出以满足 type_body_length，FU-IOS-CLIP-DIAG-REASON；判定逻辑不变）。
/// `#if DEBUG` 里只记 Debug 调试计数的最近一次判定落点（`debugLastEvaluation`，见 Debug/DebugClipboard.swift），不参与判定。
extension AppClipboard {
    func evaluate(event: String, round: Int64) {
        #if DEBUG
        // 首页视觉 UI 测试场景（-CouliHomeVisual）一律关掉自动识别：模拟器剪贴板里前一个用例留下的链接不能变成提示条、
        // 卡住截图矩阵（主线裁定，APP-11v-b）。本轮照常算读过；Release 不编译这段
        if DebugHomeVisual.shared != nil {
            watcher.consume(round)
            debugRecord(event: event, round: round, DebugClipboardEvaluation.homeVisual)
            return
        }
        #endif
        let state = readState(event: event)
        let decision = ClipboardReadPolicy.decide(platform: Self.platform, state: state)
        // 一次前台最多判定一次（共性第 1 条）：不论结果，本轮都算读过
        watcher.consume(round)
        let unchanged = decision.reasonRaw == ClipboardReadPolicy.reasonUnchanged
        guard decision.actionRaw == ClipboardReadPolicy.actionDetect || unchanged else {
            #if DEBUG
            debugRecord(event: event, round: round, DebugClipboardEvaluation.policySkip(decision))
            #endif
            return
        }
        let count = system.changeCount
        try? store.write(Self.lastChangeKey, String(count))
        // TODO(N-30) rule-gaps A01 / I01：提示条只在首页根页显示，别的页面上回前台不探测（探测了也不会提示），回到首页不补做
        guard !unchanged, homeRoot(), !ledger.containsChangeCount(count) else {
            #if DEBUG
            debugRecord(event: event, round: round, debugNotDetectedOutcome(decision, unchanged: unchanged))
            #endif
            return
        }
        let gen = homeGen
        detectCount += 1
        #if DEBUG
        debugRecord(event: event, round: round, DebugClipboardEvaluation.detecting)
        #endif
        system.detectLink { [weak self] hit in
            self?.detected(hit, event: event, round: round, homeGen: gen, changeCount: count)
        }
    }

    func detected(_ hit: Bool, event: String, round: Int64, homeGen gen: Int64, changeCount: Int) {
        // 等待之后复核：仍是这一轮前台、仍在首页根页、隐私仍已同意、没有敏感浮层、剪贴板没再变
        guard round == watcher.round, watcher.inForeground, gen == homeGen, homeRoot(), overlayClear(),
              system.changeCount == changeCount
        else {
            #if DEBUG
            debugRecordDetected(round: round, debugStaleOutcome(round: round, homeGen: gen))
            #endif
            return
        }
        var state = readState(event: event)
        state.readThisForeground = false
        state.iosChangeCountChanged = true
        state.iosDetectHit = hit
        guard ClipboardReadPolicy.decide(platform: Self.platform, state: state).actionRaw
            == ClipboardReadPolicy.actionShowPrompt
        else {
            #if DEBUG
            debugRecordDetected(round: round, DebugClipboardEvaluation.lateOutcome(
                ClipboardReadPolicy.decide(platform: Self.platform, state: state)
            ))
            #endif
            return
        }
        counter += 1
        prompt = ClipboardPrompt(id: counter)
        #if DEBUG
        debugRecordDetected(round: round, DebugClipboardEvaluation.hit)
        #endif
    }
}
