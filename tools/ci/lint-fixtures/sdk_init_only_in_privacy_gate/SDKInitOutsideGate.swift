enum SentrySDK {
    static func start(configure: () -> Void) {}
}

func initSDKTooEarly() {
    SentrySDK.start {}
}
