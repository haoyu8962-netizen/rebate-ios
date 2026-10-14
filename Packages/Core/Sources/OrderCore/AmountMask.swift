import ClientCore

/// 金额隐藏偏好（APP-08 建在这里；APP-09 按 G24 挪到共用的 ClientCore，存储与键不变）。订单页与 APP-08 的测试照常用这个名字。
public typealias AmountMaskStore = ClientCore.AmountMaskStore
