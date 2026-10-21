import CryptoKit
@testable import DesignSystem
import Foundation
import UIKit
import XCTest

/// F-X-05a：独立读 couli origin/main 的原文件得到，不能从实现者的 manifest 反生成期望值。
enum PlatformIconTestFixtures {
    static let sourceCommit = "8209d6e31bf5e4eb336421f51aa5354eb6b539c2"
    static let requiredCodes = ["taobao", "jd", "pdd"]
    static let names = ["taobao": "淘宝", "jd": "京东", "pdd": "拼多多"]
    static let missingCodes = ["tmall", "wechat", "wechat_pay", "alipay", "wecom"]

    struct Source {
        let code: String
        let digest: String
        let bytes: Int
    }

    static let sources: [String: Source] = [
        "taobao.png": Source(code: "taobao",
                             digest: "d987c0084948eeeada4da71bce00653a9eb2e5743149adb4b25587adb573a4ea", bytes: 34046),
        "jd.png": Source(code: "jd",
                         digest: "574f09c6bdfc99fa91e814a07e5fd569618060065fa723165059586b0e79766c", bytes: 6565),
        "pinduoduo.png": Source(code: "pdd",
                                digest: "6b9ff1c90ef7c168ecda69b56e5b33ab609a7883a910688aeeee8ca8ee07997d",
                                bytes: 9935),
        "vip.png": Source(code: "vip",
                          digest: "456f08146a062d5d473d0afd5bcd0834ffb998fb1c68214b5f63d4cfbd921ffc", bytes: 3839),
        "douyin.png": Source(code: "douyin",
                             digest: "5f953c7cc1c0d170797c2594c9985fbed83fe074091a05755526e10f5e0d6934", bytes: 15269),
        "douyin-white.png": Source(code: "douyin",
                                   digest: "96f1f823f2f794b2845824763f302125590e240faf8456410fe843aada8b9dcb",
                                   bytes: 13704),
        "meituan.png": Source(code: "meituan",
                              digest: "cc903df41d19b3d64ec7ba865b2bd153fcf216f9484b6af8d893ae5295174efc", bytes: 15745),
        "eleme.png": Source(code: "eleme",
                            digest: "339ac42dee1c281abddcea1a4ec0064eb1afeb17af27f28b81583ed6a277d05e", bytes: 17592),
        "fliggy.png": Source(code: "fliggy",
                             digest: "f2d4b6800645c512f486ad880d357adb81a65dc07bef54048e8aa0854c42e9b9", bytes: 18335),
        "didi.png": Source(code: "didi",
                           digest: "99fe6bd2d354bba2b1846e6f9734de1214ee16c8af3c4d7ed8cc2a0c6e3ba81d", bytes: 11409),
    ]

    struct Manifest: Decodable {
        let schemaVersion: Int
        let sourceRepository: String
        let sourceCommit: String
        let files: [Entry]
    }

    struct Entry: Decodable {
        let platformCode: String
        let file: String
        let sourcePath: String
        let sha256: String
        let bytes: Int
        let width: Int
        let height: Int
    }

    static func directory() throws -> URL {
        let root = try XCTUnwrap(Bundle.module.resourceURL)
        let directory = root.appendingPathComponent("PlatformIcons", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                      "实现者须将 PlatformIcons 目录原样 copy 进 DesignSystem 的资源包")
        XCTAssertTrue(isDirectory.boolValue)
        return directory
    }

    static func manifest() throws -> Manifest {
        let url = try directory().appendingPathComponent("manifest.json")
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    static func image(code: String) throws -> UIImage {
        let file = code == "pdd" ? "pinduoduo.png" : code + ".png"
        let data = try Data(contentsOf: directory().appendingPathComponent(file))
        return try XCTUnwrap(UIImage(data: data), "包内原图不能解码：\(file)")
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
