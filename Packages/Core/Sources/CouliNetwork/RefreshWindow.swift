import Foundation
import Session

/// 一个刷新窗口：只属于一个会话世代。账号、作废世代与 refresh_token 在入队的那把锁里固定（lessons 24），
/// 执行与结算都以它为准。等待者（`callers` 各自的 continuation）只在 `ApiClient.lock` 里增删。
final class RefreshWindow: @unchecked Sendable {
    let generation: UInt64
    let epoch: UInt64
    let refreshToken: String
    let account: String?
    /// 持久化登录世代（入队时固定，刷新保存沿用；升级前的会话为 nil）。
    let loginEpoch: String?
    /// 受限会话屏障在本窗口上等待时的屏障编号（在 `ApiClient.lock` 里写入）：窗口刷新成功即结算该屏障（R3-01）。
    var barrierSerial: UInt64?
    /// 登记在本窗口上的调用方（在 `ApiClient.lock` 里增加，APP-04 三端共性第 41 条）。没有有效性约束的调用方（原生请求、
    /// 受限会话屏障、主动刷新）始终算有效。窗口每次发送、校时重发与重新注册之前都要确认仍有至少一个有效调用方；
    /// 一个都没有就停止续发。
    var callers: [RefreshCaller] = []
    /// 执行本窗口的任务（在 `ApiClient.lock` 里写入）。最后一个有效调用方结束时取消它，在途的刷新请求随之取消
    /// （APP-04 三端共性第 54 条）。
    var task: Task<Void, Never>?
    /// 已因没有有效调用方而作废（在 `ApiClient.lock` 里写入，与入队互斥）：之后并入的调用方结算后重新入队（R4-01）。
    var abandoned = false
    /// 调用方登记版本（在 `ApiClient.lock` 里每次入队加一）：作废前用它复核判空之后没有新调用方入队（R4-01）。
    var callerVersion: UInt64 = 0
    /// 开窗口的是冷启动 / 版本恢复的受限会话屏障（在 `ApiClient.lock` 里写入；APP-05a 共性 19）。并入的调用方不改它。
    var origin = SessionRefreshOrigin.other

    init(generation: UInt64, epoch: UInt64, refreshToken: String, account: String?, loginEpoch: String? = nil) {
        self.generation = generation
        self.epoch = epoch
        self.refreshToken = refreshToken
        self.account = account
        self.loginEpoch = loginEpoch
    }
}

extension RefreshWindow {
    /// 刷新成功的保存：账号与持久化登录世代沿用入队时固定的那一份（刷新不换登录世代，FU-IOS-0712）。
    func saveRefreshed(into tokens: any SessionTokens, access: String, refresh: String, scope: String) throws {
        try tokens.save(access: access, refresh: refresh, scope: scope, account: account, loginEpoch: loginEpoch)
    }
}
