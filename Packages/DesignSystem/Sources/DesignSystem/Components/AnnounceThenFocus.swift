import SwiftUI
import UIKit

public extension View {
    /// 出错时「立即播报 → 播完把读屏焦点移到这里」（与 `ErrorState` 同一顺序，adaptation-a11y-spec §10；FU-IOS-A11Y-03 / 08 / 09）：
    /// 挂在错误行或【重试】上。出现时（以及 `trigger` 变化时，例如同一句错误再出现一次）默认播报 `announcement`（不排队，打断当前朗读），
    /// 读屏开着时等这一条的「播报结束」通知再移焦（通知没来按兜底时长移焦），读屏没开时直接移焦。
    ///
    /// 播报不放在「读屏开着」的判断里：读屏没开时系统自己忽略播报；只有「等不等播报结束」看读屏开关。
    /// - Parameters:
    ///   - announcement: 要播报的文字（空串不播、不移焦）。
    ///   - trigger: 「又出了一次错」的事件编号；缺省只看出现与文字变化。
    ///   - focusProbeID: 焦点转移上报编号（`couliFocusProbe`；nil 不报）。
    func couliAnnounceThenFocus(_ announcement: String, trigger: Int = 0, focusProbeID: String? = nil) -> some View {
        modifier(AnnounceThenFocusModifier(announcement: announcement, trigger: trigger, probeID: focusProbeID))
    }
}

struct AnnounceThenFocusModifier: ViewModifier {
    let announcement: String
    let trigger: Int
    let probeID: String?
    @AccessibilityFocusState private var focused: Bool
    /// 正在等「播报结束」的那一条。
    @State private var pending: String?
    /// 组件把焦点移到这里的次数（测量桥上报用）。
    @State private var requests = 0

    private struct Key: Equatable {
        let text: String
        let trigger: Int
    }

    func body(content: Content) -> some View {
        content
            .accessibilityFocused($focused)
            .modifier(AnnounceFocusProbe(id: probeID, focused: focused, requests: requests))
            .task(id: Key(text: announcement, trigger: trigger)) {
                guard !announcement.isEmpty else { return }
                UIAccessibility.post(notification: .announcement, argument: announcement)
                guard UIAccessibility.isVoiceOverRunning else {
                    focus()
                    return
                }
                pending = announcement
                try? await Task.sleep(nanoseconds: ErrorStateFocusCoordinator.fallbackDelayNanos)
                guard !Task.isCancelled, pending == announcement else { return }
                focus()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.announcementDidFinishNotification)) {
                let finished = $0.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String
                guard let pending, finished == nil || finished == pending else { return }
                focus()
            }
    }

    private func focus() {
        pending = nil
        focused = true
        requests += 1
    }
}

/// 焦点上报（编号为空时不加）。
private struct AnnounceFocusProbe: ViewModifier {
    let id: String?
    let focused: Bool
    let requests: Int

    func body(content: Content) -> some View {
        if let id {
            content.couliFocusProbe(id, focused: focused, requests: requests)
        } else {
            content
        }
    }
}
