// 注销账号入口的本地发布闸（FU-IOS-CONTRACT-LOCK-6c97062，D10-2903 ②(b)）。

/// 契约 6c97062 起 routes.json DeleteAccount 的 since.ios = "1.0.0"（CT-17k），iOS 生成器读它，不加闸升锁就会打开注销入口。
/// 本闸与 PhoneChangeEntry 同口径：nil = 本端未发布（Release 也关）。设置页行（AppMe.availableRoutes）与路由表
/// （AppRouting.routeTable → Router / EntryGuard，含 10007 与强更页次要入口）都按它闸住。
/// TODO(APP-13a-3)：开门时改成版本号；开门前置 FU-IOS-DELETION-REAPPLY-STALE-KEY（公开发布前必须修完）、FU-IOS-DELETION-R4-S3。
public enum DeleteAccountEntry {
    public static let sinceIOS: String? = nil
}
