import SwiftUI

/// 共用手机号输入（`PhoneNumberField`）的对外入口（APP-13a-2）：换手机号子页在 Features/Me，Feature 之间不依赖，由 App 把这个组件
/// 注入过去，保证全 App 电话键盘输入框只写一处（BindPhoneLayoutTests 源码守卫）。只转发，不改组件本身。
public struct PhoneNumberInput<Focus: Hashable>: View {
    /// 文案与样式（同 BindPhone 页的用法：前缀「+86」、占位、读屏标签、清除按钮名、标识、错误说明与校验样式）。
    public struct Config {
        public var prefix = ""
        public var placeholder = ""
        public var label = ""
        public var clearLabel = ""
        public var identifier = ""
        public var hint = ""
        public var error = false
        public var locked = false
        public var showsClear = false

        public init() {}
    }

    let text: Binding<String>
    let focus: FocusState<Focus>.Binding
    let focusValue: Focus
    let config: Config
    let onClear: () -> Void

    public init(text: Binding<String>, focus: FocusState<Focus>.Binding, focusValue: Focus, config: Config,
                onClear: @escaping () -> Void) {
        self.text = text
        self.focus = focus
        self.focusValue = focusValue
        self.config = config
        self.onClear = onClear
    }

    public var body: some View {
        PhoneNumberField(
            text: text, prefix: config.prefix, placeholder: config.placeholder, label: config.label,
            clearLabel: config.clearLabel, identifier: config.identifier, focus: focus, focusValue: focusValue,
            hint: config.hint, error: config.error, locked: config.locked, showsClear: config.showsClear,
            onClear: onClear
        )
    }
}
