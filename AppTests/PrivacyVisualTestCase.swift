@testable import Couli
import DesignSystem
import Foundation
@testable import Me
import MeCore
import SwiftUI
import UIKit
import XCTest

/// APP-12w-b 视觉用例底座：在 `SettingsVisualTestCase`（真实 App 组装、固定时钟、测量桥重报、轻提示旁路记录）上换页面入口。
/// 隐私中心、关于走真实 Router；强更上下文用生产 `PrivacyCenterController(forceUpdate: true)`；客服见 `CsSheetHarness`。
@MainActor
class PrivacyVisualTestCase: SettingsVisualTestCase {
    typealias Canvas = SettingsVisualHost.Canvas

    struct Scene {
        var session = "privacy_member"
        var canvas = Canvas(height: 1200)
        var kf: String?
        var filing = ""
        var personalization = true
    }

    private(set) var entry: MePageEntry?
    private(set) var forcedHost: MePageHost<PrivacyCenterController>?

    override func tearDown() async throws {
        entry = nil
        forcedHost = nil
        try await super.tearDown()
    }

    // MARK: - 组装

    /// 按 fixture 的 session 组装：身份档位、系统权限、设备注册、个性化、配置（kf、filing_text、legal 版本）。
    func prepare(_ scene: Scene, file: StaticString = #filePath, line: UInt = #line) async throws
        -> SettingsVisualHost {
        let session = try PrivacyVisualData.session(scene.session)
        let status = try XCTUnwrap(session["permissionStatus"] as? [String: String], file: file, line: line)
        let level: Level = switch session["level"] as? String {
        case "guest": .guest
        case "basic": .basic
        default: .member
        }
        let host = try fresh(Setup(level: level, canvas: scene.canvas, push: status["push"] ?? "not_asked"))
        host.fixture.system.status["photos"] = status["photos"]
        host.fixture.me.deviceId = (session["deviceRegistered"] as? Bool) == true ? { "device-fixture-0001" } : { nil }
        try host.script.ok("GET /v1/config", PrivacyVisualData.config(kf: scene.kf, filing: scene.filing))
        host.fixture.config.startIfSettled(.settled)
        let me = host.fixture.me
        if level != .basic {
            await waitUntil("配置没有拉到", file: file, line: line) {
                (me.configObject("agent") as? [String: Any])?[PrivacyVisualData.marker] != nil
            }
            XCTAssertEqual(me.legalPrivacyVersion(), 3, file: file, line: line)
            XCTAssertEqual(me.kfUrl(), scene.kf, "配置里的 kf", file: file, line: line)
        }
        if !scene.personalization {
            host.fixture.local.setPersonalization(false, now: 1)
        }
        return host
    }

    private func mount(_ host: SettingsVisualHost, _ screen: AnyView, _ canvas: Canvas) {
        host.mountScreen(screen, canvas: canvas)
    }

    // MARK: - 隐私中心

    var center: PrivacyCenterController {
        get throws {
            try XCTUnwrap(forcedHost?.controller ?? entry?.controller() as? PrivacyCenterController, "隐私中心没有打开")
        }
    }

    var centerActions: PrivacyCenterActions {
        get throws {
            let controller = try center
            return PrivacyCenterActions.make(controller, controller.state)
        }
    }

    /// 打开隐私中心并等系统权限查完、`waitFor` 测量到位。`waitFor` 为 nil 不等测量（行为用例不把「测量未接」混进来）。
    @discardableResult
    func openPrivacy(_ scene: Scene = Scene(), waitFor: String? = nil, file: StaticString = #filePath,
                     line: UInt = #line) async throws -> UIImage {
        let host = try await prepare(scene, file: file, line: line)
        let forced = try (PrivacyVisualData.session(scene.session)["forceUpdate"] as? Bool) == true
        if forced {
            let me = host.fixture.me
            let controller = PrivacyCenterController(deps: me.deps, identity: me.identity(), page: nil,
                                                     forceUpdate: true)
            let page = MePageHost(controller)
            page.onAppear = { [weak page] in page?.controller.refresh() }
            forcedHost = page
            mount(host, AnyView(PrivacyCenterScreen(host: page)), scene.canvas)
        } else {
            entry = try XCTUnwrap(host.fixture.open("PrivacyCenter"), "隐私中心没有打开", file: file, line: line)
            try mount(host, XCTUnwrap(entry).screen(), scene.canvas)
        }
        return try await privacyFrame(waitFor, file: file, line: line)
    }

    func privacyFrame(_ waitFor: String? = nil, file: StaticString = #filePath, line: UInt = #line,
                      until ready: @escaping () -> Bool = { true }) async throws -> UIImage {
        try await frame(waitFor, file: file, line: line) { [weak self] _ in
            guard let self, let controller = try? center else { return false }
            return controller.state.permissionStatus.count == controller.model().permissionRows.count && ready()
        }
    }

    /// 出确认框。
    @discardableResult
    func askWithdraw(file: StaticString = #filePath, line: UInt = #line) throws -> MeDialog {
        try centerActions.askWithdraw()
        return try XCTUnwrap(center.state.dialog, "确认框没有出现", file: file, line: line)
    }

    /// 协调器真实收到的撤回记录（recordConsent type=privacy）。
    var withdrawRecords: Int {
        WalletStubProtocol.requests("POST", "/v1/consents").filter { $0.json["type"] as? String == "privacy" }.count
    }

    var consentRecords: Int {
        WalletStubProtocol.requests("POST", "/v1/consents").count
    }

    // MARK: - 关于

    var about: AboutController {
        get throws {
            try XCTUnwrap(entry?.controller() as? AboutController, "关于页没有打开")
        }
    }

    @discardableResult
    func openAbout(filed: Bool = true, canvas: Canvas = Canvas(height: 900), waitFor: String? = nil,
                   file: StaticString = #filePath, line: UInt = #line) async throws -> UIImage {
        let filing = try PrivacyVisualData.about(filed ? "filed" : "unfiled") as? String ?? ""
        let host = try await prepare(Scene(canvas: canvas, filing: filing), file: file, line: line)
        entry = try XCTUnwrap(host.fixture.open("About"), "关于页没有打开", file: file, line: line)
        try mount(host, XCTUnwrap(entry).screen(), canvas)
        return try await frame(waitFor, file: file, line: line)
    }

    // MARK: - 客服半屏

    var cs: CustomerServiceEntry {
        get throws {
            try XCTUnwrap(page?.fixture.me.cs, "没有组装")
        }
    }

    var csActions: CsActions {
        get throws {
            let entry = try cs
            return try CsActions.make(entry, XCTUnwrap(entry.sheet, "半屏没有打开"))
        }
    }

    /// 按 fixture 的 `cs.cases` 组装并打开半屏：`cs_open_failed` 走真实路径（HANDOFF → 拉不起 → 换 OPEN_FAILED）。
    @discardableResult
    func openCs(_ name: String, canvas: Canvas = Canvas(height: 620, top: 0), waitFor: String? = "cs.panel",
                file: StaticString = #filePath, line: UInt = #line) async throws -> UIImage {
        let setup = try PrivacyVisualData.csCase(name)
        let group = try XCTUnwrap(PrivacyVisualData.root()["cs"] as? [String: Any])
        let kf: String? = switch setup["kf"] as? String {
        case "https": group["kf"] as? String
        case "http": group["kfInsecure"] as? String
        default: nil
        }
        let host = try await prepare(Scene(canvas: canvas, kf: kf), file: file, line: line)
        host.fixture.system.wechat = setup["wechat"] as? String ?? "unknown"
        host.fixture.system.openResult = setup["opens"] as? Bool ?? false
        host.fixture.ledgerStore.failWrites = (setup["copies"] as? Bool) == false
        let entry: CustomerServiceEntry = host.fixture.me.cs
        entry.open(from: "Me")
        if setup["sheet"] as? String == CsEntryDecision.openFailed {
            try csActions.openWechat()
            await waitUntil("没有换成打不开", file: file, line: line) {
                entry.sheet?.decision.sheetRaw == CsEntryDecision.openFailed
            }
        }
        let want = setup["sheet"] as? String
        XCTAssertEqual(entry.sheet?.decision.sheetRaw, want, "fixture 与决策不一致", file: file, line: line)
        XCTAssertEqual(entry.sheet?.decision.buttons, setup["buttons"] as? [String], "按钮序列（动作映射）",
                       file: file, line: line)
        let texts = host.fixture.me.deps.texts
        mount(host, AnyView(CsSheetHarness(entry: entry, texts: texts)), canvas)
        return try await frame(waitFor, file: file, line: line)
    }

    // MARK: - 像素小件

    /// 判图标形状（v2）：参考图与生产 `CouliIconView` 同画法（0.8 倍字号），`nearestIcon` 的 `.resizable()` 铺满框、尺度不同（钱包用例共用，不动它）。
    func nearestSymbol(_ image: UIImage, in rect: CGRect, candidates: [String], background: Color,
                       ink: Color) async -> String? {
        let size = rect.size
        let view = HStack(spacing: 20) {
            ForEach(candidates, id: \.self) { name in
                Image(systemName: name)
                    .font(.system(size: size.width * 0.8, weight: .regular))
                    .frame(width: size.width, height: size.height)
                    .foregroundColor(ink)
                    .couliProbe("ref.\(name)", role: "icon")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        let width = CGFloat(candidates.count) * (size.width + 20) + 40
        let ground = ProductVisualPixels.RGB(background, dark: false)
        let (reference, probes) = await WalletVisualRender.standalone(
            view, size: CGSize(width: width, height: size.height + 40)
        ) { pixels in
            pixels.count(in: CGRect(x: 0, y: 0, width: width, height: size.height + 40)) { !$0.near(
                ground,
                tolerance: 40
            ) }
                > 20 * candidates.count
        }
        let target = ProductVisualIconProbe.ink(ProductVisualPixels(image), in: rect, background: ground)
        let referencePixels = ProductVisualPixels(reference)
        var best: (name: String, difference: Int)?
        for name in candidates {
            guard let frame = probes["ref.\(name)"]?.rect else { continue }
            let drawn = ProductVisualIconProbe.ink(referencePixels, in: frame, background: ground)
            let difference = ProductVisualIconProbe.difference(target, drawn)
            if best.map({ difference < $0.difference }) ?? true {
                best = (name, difference)
            }
        }
        return best?.name
    }

    /// 框内近 `color` 的像素占比超过九成（底色判据）。
    func assertFill(_ image: UIImage, _ box: CGRect, _ color: ProductVisualPixels.RGB, _ message: String,
                    tolerance: Int = 3, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(share(image, in: box, near: color, tolerance: tolerance), 0.9, message, file: file,
                             line: line)
    }

    /// 文字框内有该颜色的墨迹。
    func assertInk(_ image: UIImage, _ id: String, _ color: Color, _ message: String, dark: Bool = false,
                   minimum: Int = 8, file: StaticString = #filePath, line: UInt = #line) throws {
        let box = try rect(id, file: file, line: line)
        XCTAssertGreaterThan(count(image, in: box, near: pixel(color, dark: dark)), minimum, message, file: file,
                             line: line)
    }

    /// 通栏次按钮：无品牌填充、有控件边。
    func assertSecondary(_ image: UIImage, _ id: String, _ message: String, dark: Bool = false,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let box = try rect(id, file: file, line: line)
        let brand = pixel(CouliColor.brandPrimary, dark: dark)
        XCTAssertEqual(count(image, in: box.insetBy(dx: 4, dy: 4), near: brand, tolerance: 6), 0,
                       "\(message)：不是实底按钮", file: file, line: line)
        let edge = CGRect(x: box.minX + 16, y: box.minY - 1, width: box.width - 32, height: 3)
        XCTAssertGreaterThan(count(image, in: edge, near: pixel(CouliColor.borderControl, dark: dark), tolerance: 12),
                             40, "\(message)：有控件边", file: file, line: line)
    }

    /// 通栏主按钮：品牌实底。
    func assertPrimary(_ image: UIImage, _ id: String, _ message: String, file: StaticString = #filePath,
                       line: UInt = #line) throws {
        let box = try rect(id, file: file, line: line)
        let corner = CGRect(x: box.minX + 14, y: box.midY - 6, width: 12, height: 12)
        assertFill(image, corner, pixel(CouliColor.brandPrimary, dark: false), "\(message)：品牌实底", tolerance: 6,
                   file: file, line: line)
    }
}
