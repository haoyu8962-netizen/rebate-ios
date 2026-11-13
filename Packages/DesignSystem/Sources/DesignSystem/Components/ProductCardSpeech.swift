import SwiftUI

/// 列表卡整卡读屏名（FU-IOS-A11Y-04）：按卡上画出来的顺序读看得见的文字（D10-1248 ⑦：视觉上没画的不读）。
public enum ProductCardSpeech {
    public static func list(_ data: ProductCardData) -> String {
        var parts = [BadgedTitle.accessibilityText(platform: data.platformName, title: data.title)]
        parts += data.allTags.map(\.text)
        if !data.hidesPrice {
            parts.append(data.price.mainAccessibilityText)
        }
        if data.showsRebate {
            parts.append(data.rebate.hidingAmount(data.amountHidden).accessibilityText)
        }
        parts += data.subLines.map(\.spoken)
        if !data.amountHidden, data.showsRebate, let note = data.settlementNote {
            parts.append(note)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: PriceTerms.spokenPause)
    }
}

extension View {
    /// 有绑定时挂读屏焦点，没有时原样。
    @ViewBuilder
    func couliOptionalFocus(_ binding: AccessibilityFocusState<Bool>.Binding?) -> some View {
        if let binding {
            accessibilityFocused(binding)
        } else {
            self
        }
    }
}
