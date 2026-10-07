// 生成物，禁止手改；来源 contract.lock
// 快照：specs/device-hash.vectors.json 的 invalid_hash_seeds（BR-ID-09 细则「设备标识的无效值」）

/// 无效设备哈希的种子（config device.invalid_hashes 的初值）：客户端求哈希后命中即视为取不到，不注册、不上报。
public enum DeviceHashSeeds {
    public static let invalidHashes: Swift.Set<Swift.String> = [
        "12b9377cbe7e5c94e8a70d9d23929523d14afa954793130f8a3959c7b849aca8",
        "4d853cd5e7d688e75b3dca9abc2fa52ac8bafb750b6d4dc01b78e2e7bb335f8f",
        "5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9",
        "84e0c0eafaa95a34c293f278ac52e45ce537bab5e752a00e6959a13ae103b65a",
        "bd64bb8efa5b3f27e6442f23600c3b516127ea17e23724b41e50da4c22883edd",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "fcdb4b423f4e5283afa249d762ef6aef150e91fccd810d43e5e719d14512dec7",
    ]
}
