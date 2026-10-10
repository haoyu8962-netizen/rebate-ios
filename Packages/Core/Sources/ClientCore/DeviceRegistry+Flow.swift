import CouliNetwork
import Foundation

/// 设备注册的请求流程与 10402 重新注册（`DeviceRegistry` 的一部分）。
extension DeviceRegistry {
    /// 10402（X-Device-Id 无效）：重新注册 1 次。被拒的 device_id 已被换掉（别的调用已重新注册过）时直接返回 true；
    /// 同一个被拒 device_id 的窗口正在进行时并入。返回 true 表示本机此刻有新凭据，ApiClient 沿用原键重放 1 次。
    ///
    /// - 被拒的 device_id 立即隔离（`credentials` 不再交出），registerDevice 请求因此不带旧设备头（共性 21）。
    /// - 注册请求自身遇到 10402（`registering`）直接返回 false：不递归进入它正在执行的注册窗口（共性 21）。
    /// - 世代校验、结果复用、入队或开窗在同一把锁里；窗口结束时先存结果、再移除窗口、再唤醒等待者，退避通知只发
    ///   一次（共性 4、18、22）。
    /// - `isValid`：调用方的有效性约束（桥调用触发的恢复带上，APP-04 三端共性第 22、46 条；nil = 独立的原生调用方）。
    ///   内部等待结束后先查自己的；窗口与单飞注册在读标识前、实际发送前查全部等待者，一个有效的都没有就停止这次恢复。
    public func reRegister(rejectedDeviceId: String?, isValid: (@Sendable () -> Bool)? = nil) async -> Bool {
        if Self.registering {
            return false
        }
        let key = rejectedDeviceId ?? ""
        let early: (result: Bool?, epoch: UInt64) = lock.withLock {
            // 先隔离这次被拒的凭据，与复用结果、开窗分开：任何分支都不会再交出它（共性 25）。
            if let rejectedDeviceId {
                rejectedDeviceIds.insert(rejectedDeviceId)
            }
            if let reused = reRegisterResults[key] {
                return (reused, epoch)
            }
            switch readLocked() {
            case let .identity(identity) where !rejectedDeviceIds.contains(identity.deviceId):
                return (true, epoch)
            case .unreadable, .blocked:
                return (false, epoch)
            default:
                return (nil, epoch)
            }
        }
        if let result = early.result {
            return result
        }
        guard await allowed() else {
            return false
        }
        guard isValid?() ?? true else {
            // 入口等待期间调用失效（页面关闭、到期）：不开窗、不重放这次调用，但设备恢复不能丢（R4-02）。
            requestRecoveryAfterAbandonedEntry(key: key, startEpoch: early.epoch)
            return false
        }
        return await joinWindow(key: key, rejectedDeviceId: rejectedDeviceId, startEpoch: early.epoch, caller: isValid)
    }

    /// 重放（或刷新重放）再次收到 10402，重注册与重放的预算已用完（`NetworkHooks.deviceRejected`，共性 25）：
    /// 隔离这次所用的凭据（`credentials` 不再交出、`registerIfNeeded` 不再当作已注册），原调用由 ApiClient 结束；
    /// 后续恢复交给唯一一条退避链（`onNeedsRegistration` → PrivacyGate 重启设备注册退避，旧链作废）。同一个被拒
    /// device_id 在本清理世代只通知一次；它的重新注册窗口还在进行时由窗口负责。注册请求自身不走这里。
    public func deviceRejected(rejectedDeviceId: String?) {
        if Self.registering {
            return
        }
        let key = rejectedDeviceId ?? ""
        let notify: (@Sendable () -> Void)? = lock.withLock {
            if let rejectedDeviceId {
                rejectedDeviceIds.insert(rejectedDeviceId)
            }
            guard reRegisterWindows[key] == nil, recoveryRequested.insert(key).inserted else {
                return nil
            }
            return needsRegistration
        }
        notify?()
    }

    /// 重新注册入口因调用失效结束（还没开窗）：仍在原清理世代、被拒凭据还没被替换（没有复用结果、也没有可用凭据）、
    /// 且没有其他恢复窗口时，按被拒 device_id 去重通知唯一的设备退避链（与窗口失败、预算用尽共用去重，共性 25）。
    func requestRecoveryAfterAbandonedEntry(key: String, startEpoch: UInt64) {
        let notify: (@Sendable () -> Void)? = lock.withLock {
            guard epoch == startEpoch, reRegisterResults[key] == nil, usableLocked() == nil,
                  reRegisterWindows[key] == nil, recoveryRequested.insert(key).inserted
            else {
                return nil
            }
            return needsRegistration
        }
        notify?()
    }

    /// 在同一把锁里：世代不符按失败（不复用、不开窗）；已有结果直接复用；有进行中的窗口就入队；否则开窗。
    func joinWindow(
        key: String, rejectedDeviceId: String?, startEpoch: UInt64, caller: (@Sendable () -> Bool)? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            var opened: ReRegisterWindow?
            let immediate: Bool? = lock.withLock {
                guard epoch == startEpoch else {
                    return false
                }
                if let reused = reRegisterResults[key] {
                    return reused
                }
                // 被拒的凭据已被替换为可用凭据（如退避注册已成功）：直接重放，不开窗、不再注册（R3-01）。
                if usableLocked() != nil {
                    return true
                }
                if let running = reRegisterWindows[key] {
                    running.waiters.append(continuation)
                    running.callers.append(caller)
                    return nil
                }
                let window = ReRegisterWindow()
                window.waiters.append(continuation)
                window.callers.append(caller)
                reRegisterWindows[key] = window
                opened = window
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            } else if let opened {
                Task {
                    await self.runWindow(opened, key: key, rejectedDeviceId: rejectedDeviceId, startEpoch: startEpoch)
                }
            }
        }
    }

    /// 窗口：并入（或发起）单飞注册；结束时先保存不可变结果、再移除窗口、再唤醒等待者；失败只通知一次退避。
    func runWindow(_ window: ReRegisterWindow, key: String, rejectedDeviceId: String?, startEpoch: UInt64) async {
        let outcome = await joinOrStart(epoch: startEpoch) { [weak self] in
            self?.hasLiveCaller(window) ?? false
        }
        // 窗口里已没有有效等待者（桥调用都已失效）而停下：这次恢复没有结论，不记结果（之后原生调用方的 10402 重新开窗）。
        let abandoned = !outcome.hasCredentials && !hasLiveCaller(window)
        let settled: WindowSettlement = lock.withLock {
            let current = epoch == startEpoch
            var ok = false
            if current, outcome.hasCredentials, case let .identity(identity) = readLocked() {
                ok = identity.deviceId != rejectedDeviceId && !rejectedDeviceIds.contains(identity.deviceId)
            }
            if current, !abandoned {
                reRegisterResults[key] = ok
            }
            if reRegisterWindows[key] === window {
                reRegisterWindows[key] = nil
            }
            let waiters = window.waiters
            window.waiters.removeAll()
            // 失败只交给退避链一次（与预算用尽的通知共用去重，共性 25）。
            let notify = current && !ok && recoveryRequested.insert(key).inserted
            return WindowSettlement(ok: ok, waiters: waiters, notify: notify ? needsRegistration : nil)
        }
        settled.notify?()
        for waiter in settled.waiters {
            waiter.resume(returning: settled.ok)
        }
    }

    /// 窗口结算：不可变结果、要唤醒的等待者、（失败时）唯一一次退避通知。
    struct WindowSettlement {
        let ok: Bool
        let waiters: [CheckedContinuation<Bool, Never>]
        let notify: (@Sendable () -> Void)?
    }

    /// `live`：单飞注册里是否还有有效等待者（APP-04 三端共性第 22、46 条）。内部等待结束后、读标识前、实际发送前
    /// （并交给 ApiClient 的发送守卫）都要为真，否则按「已取消」停止，不读标识、不发请求。
    func performRegistration(
        ticket: RegistrationTicket,
        rereadAllowed: Bool,
        live: @escaping @Sendable () -> Bool = { true }
    ) async -> DeviceRegistrationOutcome {
        let startEpoch = ticket.epoch
        guard await allowed(), isCurrent(startEpoch) else {
            return .notAllowed
        }
        guard live() else {
            return .cancelled
        }
        // 最后一次放行检查与读取本身在同一个同步区（主线程 + 注册表的锁），与清理（invalidateAndClear）共用：
        // 撤回同意完成之后，旧任务不会再开始读取 identifierForVendor（APP-03b 共性 12）。桥在主线程上撤销调用，
        // 读取前在主线程上查有效等待者。
        let read: String?? = await MainActor.run {
            guard live() else {
                return .none
            }
            return lock.withLock { () -> String?? in
                guard epoch == startEpoch, admitRead() else {
                    return .none
                }
                return .some(reader.readIdentifier())
            }
        }
        guard case let .some(raw) = read else {
            return live() ? .notAllowed : .cancelled
        }
        let decision = DeviceIdPolicy.evaluate(platform: platform, rawId: raw, privacy: DeviceIdPolicy.consented)
        guard decision.register, let hash = decision.deviceHash, let source = decision.idSource else {
            return .invalidIdentifier
        }
        let (rejected, sender): (Bool, ApiClient?) = lock.withLock { (rejectedHashes.contains(hash), client) }
        guard !rejected else {
            return .rejectedHash
        }
        guard let sender, let clientEpoch = ticket.clientEpoch,
              let body = Self.requestBody(hash: hash, idSource: source)
        else {
            return .requestFailed
        }
        guard isCurrent(startEpoch), live() else {
            return .cancelled
        }
        lock.withLock { requestCount += 1 }
        // 带原始票据发送：ApiClient 在实际发送前的守卫里按它校验，不把这次请求重新绑定到当前环境（共性 13）；
        // 有效等待者的约束同样交给实际发送前的守卫。
        let result = await sender.send(
            ApiCall(operationId: Self.registerOperation, body: body), ticket: clientEpoch, isValid: live
        )
        // 结果（成功、失败、20001）处理前先核对清理世代与隐私：已失效的结果不改写被拒哈希、不重读、不继续注册。
        guard isCurrent(startEpoch), await allowed(), isCurrent(startEpoch) else {
            return .cancelled
        }
        return await handle(
            result, hash: hash, idSource: source, ticket: ticket, rereadAllowed: rereadAllowed, live: live
        )
    }

    /// 已核对世代的注册结果：成功先落盘；20001 记下被拒哈希并至多重读一次；其余按失败。
    func handle(
        _ result: ApiResult,
        hash: String,
        idSource source: String,
        ticket: RegistrationTicket,
        rereadAllowed: Bool,
        live: @escaping @Sendable () -> Bool = { true }
    ) async -> DeviceRegistrationOutcome {
        let startEpoch = ticket.epoch
        switch result {
        case let .success(data, _, _):
            return save(data, idSource: source, epoch: startEpoch)
        case let .failure(_, _, _, _, effect, _) where effect.kind == .rereadDeviceHash:
            // 每次 20001 都记下这次被拒的哈希（重读后的请求也一样），只在本清理世代里记。
            let current: Bool = lock.withLock {
                guard epoch == startEpoch else {
                    return false
                }
                rejectedHashes.insert(hash)
                return true
            }
            guard current else {
                return .cancelled
            }
            guard rereadAllowed else {
                return .rejectedHash
            }
            return await performRegistration(ticket: ticket, rereadAllowed: false, live: live)
        case let .localReject(reason) where reason == LocalRejectReason.callCancelled:
            return .cancelled
        default:
            return isCurrent(startEpoch) ? .requestFailed : .cancelled
        }
    }

    /// 先落盘再改内存；作废后到达的结果丢弃。
    func save(_ data: Data?, idSource: String, epoch startEpoch: UInt64) -> DeviceRegistrationOutcome {
        guard let data,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let deviceId = object["device_id"] as? String, !deviceId.isEmpty,
              let secret = object["install_secret"] as? String, !secret.isEmpty
        else {
            return .requestFailed
        }
        let identity = DeviceIdentity(deviceId: deviceId, installSecret: secret, idSource: idSource)
        return lock.withLock {
            guard epoch == startEpoch else {
                return .cancelled
            }
            do {
                try store.save(identity)
            } catch {
                return .storeFailed
            }
            cache = .known(identity)
            rejectedDeviceIds.remove(identity.deviceId)
            // 被拒凭据的恢复状态由所有注册入口共用：本世代里任何一次注册成功（含退避注册），此前被拒的 device_id
            // 都已被替换，晚到的同一 device_id 的 10402 直接复用成功结果（R3-01）。
            for rejected in rejectedDeviceIds {
                reRegisterResults[rejected] = true
            }
            return .registered
        }
    }

    static func requestBody(hash: String, idSource: String) -> String? {
        let object = ["device_hash": hash, "id_source": idSource]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
