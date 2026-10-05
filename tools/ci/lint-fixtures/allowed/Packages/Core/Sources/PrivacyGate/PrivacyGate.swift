enum SentrySDK {
    static func start(configure: () -> Void) {}
}

enum PrivacyGateFixture {
    static func onConsented() {
        SentrySDK.start {}
    }
}
