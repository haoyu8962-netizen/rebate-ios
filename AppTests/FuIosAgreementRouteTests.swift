import BridgeHost
import ClientCore
@testable import Couli
import Foundation
import Generated
import Router
import SwiftUI
import XCTest

/// FU-IOS-AGREEMENT-ROUTE（D10-3505 / D10-3554 / D10-3555）：协议页 Agreement 登记到 H5 容器（H5RouteView），不再落占位页；
/// 地址按「配置基址 + 契约 h5_path /agreement + 参数」生成；游客 / 基本模式 / 隐私未决（只读）/ 强更低于最低版经 Router 都能打开并落到
/// 已登记的协议页；隐私未决时桥调用方状态为 not_decided；契约枚举外的 type 按现有参数校验拒绝。
@MainActor
final class FuIosAgreementRouteTests: MeTestCase {
    private static let agreement = "Agreement"
    private static let types = ["agreement", "privacy", "sdk_list", "labor_agreement", "collect_list"]
    private static let config = "{\"h5_base_url\":\"https://h5.example.invalid/app/\"}"
    private static let base = "https://h5.example.invalid/app/agreement"

    private var guardState = GuardState(
        privacyState: .consented, updateState: .ok, sessionState: .guest, environmentSettled: true,
        appVersion: AppWeb.appVersion, isDebugBuild: true
    )

    // MARK: - 夹具

    private func makeRouter() -> Router {
        Router(
            pendingStore: PendingActionStore(backend: MemoryPendingBackend()),
            state: { [unowned self] in guardState }
        )
    }

    private func agreementRequest(
        _ values: [String: JSONValue] = [:], from source: RouteSource = .inApp
    ) -> RouteRequest {
        RouteRequest(route: Self.agreement, values: values, from: source)
    }

    /// 结论可打开、栈顶是 Agreement，且这个落点有登记的页面（不是占位页）。
    private func assertLandsOnAgreementPage(
        _ decision: GuardDecision, _ router: Router, readonly: Bool, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected: GuardDecisionKind = readonly ? .openReadonly : .open
        XCTAssertEqual(decision.kind, expected, label, file: file, line: line)
        XCTAssertEqual(decision.route, Self.agreement, label, file: file, line: line)
        XCTAssertEqual(router.path.last?.route, Self.agreement, label, file: file, line: line)
        XCTAssertEqual(router.path.last?.readonly, readonly, label, file: file, line: line)
        XCTAssertNotNil(
            RouteViewRegistry.builders[Self.agreement], "\(label)：Agreement 没有接页面（落占位页）", file: file, line: line
        )
    }

    /// 登记的页面视图的类型描述（AnyView 内的具体视图类型名）。
    private func registeredViewDump(_ destination: RouteDestination) -> String? {
        guard let builder = RouteViewRegistry.builders[Self.agreement] else { return nil }
        var text = ""
        dump(builder(destination), to: &text)
        return text
    }

    private func makeWeb(_ app: MeAppFixture) -> AppWeb {
        let directory = MeAppFixture.localDirectory(suiteName)
        let tracker = AppTracker(
            privacy: app.routing.privacy, update: app.update, network: app.network,
            environmentReady: { true }, credentialsReadable: { app.runner.credentialsReadable },
            file: ClientFile(name: "agreement-route-tracker.json", baseDirectory: directory),
            withdrawalRegistry: app.withdrawal, environmentRegistry: app.environmentSwitch
        )
        return AppWeb(
            config: app.config, network: app.network, routing: app.routing, privacy: app.routing.privacy,
            update: app.update, tracker: tracker,
            permissions: AppPermissions(
                file: ClientFile(name: "agreement-route-permissions.json", baseDirectory: directory)
            ),
            withdrawalRegistry: app.withdrawal, environmentRegistry: app.environmentSwitch
        )
    }

    // MARK: - 登记

    /// Agreement 在 routes.json 是 h5 / h5_path /agreement / since.ios 1.0.0，
    /// 且 RouteViewRegistry 登记为 H5 容器（H5RouteView），不落占位页。
    func testAgreementRegisteredAsH5Container() throws {
        let spec = try XCTUnwrap(Routes.all[Self.agreement], "Agreement 不在 routes.json")
        XCTAssertEqual(spec.kind, .h5)
        XCTAssertEqual(spec.h5Path, "/agreement")
        XCTAssertEqual(spec.sinceIOS, "1.0.0")
        XCTAssertNotNil(RouteViewRegistry.builders[Self.agreement], "Agreement 没有接页面（落占位页）")
        let dumped = registeredViewDump(RouteDestination(route: Self.agreement, params: ["type": .string("privacy")]))
        XCTAssertEqual(dumped?.contains("H5RouteView"), true, "Agreement 应接 H5 容器（H5RouteView）")
    }

    // MARK: - 地址

    /// 契约 type 五个取值各一：基址 + /agreement + ?type=…；两者都缺：只有 /agreement。
    func testAgreementAddressForEachContractTypeAndBare() {
        for type in Self.types {
            XCTAssertEqual(
                H5RouteURL.make(route: Self.agreement, params: ["type": .string(type)], configJson: Self.config)?
                    .absoluteString,
                Self.base + "?type=" + type, type
            )
        }
        XCTAssertEqual(
            H5RouteURL.make(route: Self.agreement, params: [:], configJson: Self.config)?.absoluteString, Self.base,
            "type 与 version 都缺：只带路径"
        )
        XCTAssertNil(H5RouteURL.make(route: Self.agreement, params: [:], configJson: "{}"), "基址缺失不加载")
    }

    /// version（契约 integer ≥ 1）经 Router 校验后是整数参数，生成的协议地址要带上它（不得静默丢掉）。
    func testAgreementAddressCarriesIntegerVersion() throws {
        let router = makeRouter()
        let decision = router.open(agreementRequest(["type": .string("privacy"), "version": .integer(3)]))
        XCTAssertEqual(decision.kind, .open)
        let destination = try XCTUnwrap(router.path.last)
        XCTAssertEqual(destination.params["version"], .integer(3), "Router 落点保留整数 version")
        XCTAssertEqual(
            H5RouteURL.make(route: Self.agreement, params: destination.params, configJson: Self.config)?.absoluteString,
            Self.base + "?type=privacy&version=3", "type + version"
        )
        XCTAssertEqual(
            H5RouteURL.make(route: Self.agreement, params: ["version": .integer(1)], configJson: Self.config)?
                .absoluteString,
            Self.base + "?version=1", "只带 version"
        )
    }

    // MARK: - 各状态经 Router 打开

    /// 游客（已同意、未登录）：App 内与深链打开 Agreement（auth none）直接放行，五个 type 各一、两者都缺，参数原样落栈。
    func testGuestOpensAgreementForEveryType() {
        let router = makeRouter()
        for type in Self.types {
            router.path.removeAll()
            let decision = router.open(agreementRequest(["type": .string(type)]))
            assertLandsOnAgreementPage(decision, router, readonly: false, "游客 \(type)")
            XCTAssertEqual(router.path.last?.params, ["type": .string(type)], type)
        }
        router.path.removeAll()
        let bare = router.open(agreementRequest())
        assertLandsOnAgreementPage(bare, router, readonly: false, "游客 无参数")
        XCTAssertEqual(router.path.last?.params, [:])

        router.path.removeAll()
        let deeplink = router.open(agreementRequest(["type": .string("agreement")], from: .deeplink))
        assertLandsOnAgreementPage(deeplink, router, readonly: false, "游客 深链")
    }

    /// 基本模式：Agreement 在基本模式清单里，App 内打开得到只读放行（basic_readonly），不弹补同意。
    func testBasicModeOpensAgreementReadonly() {
        guardState.privacy = .basicMode
        let router = makeRouter()
        let decision = router.open(agreementRequest(["type": .string("sdk_list")]))
        assertLandsOnAgreementPage(decision, router, readonly: true, "基本模式")
        XCTAssertEqual(decision.reason, GuardReason.basicReadonly)
        XCTAssertFalse(router.consentRequested, "基本模式读协议不要求补同意")
    }

    /// 隐私未决：App 内（首启弹窗里的链接）打开 Agreement 只读放行（privacy_undecided_readonly）。
    func testPrivacyUndecidedOpensAgreementReadonly() {
        guardState.privacy = .notDecided
        let router = makeRouter()
        let decision = router.open(agreementRequest(["type": .string("privacy")]))
        assertLandsOnAgreementPage(decision, router, readonly: true, "隐私未决")
        XCTAssertEqual(decision.reason, GuardReason.privacyUndecidedReadonly)
        XCTAssertEqual(router.path.last?.params, ["type": .string("privacy")])
    }

    /// 强更低于最低版：从强更页（及叠在强更页上的隐私弹窗）打开 Agreement 放行（force_update_exception），强更页留在下面。
    func testBelowMinimumOpensAgreementFromForceUpdatePage() {
        guardState.update = .belowMin
        let router = makeRouter()
        router.enterForceUpdate()
        let decision = router.openFromForceUpdatePage(agreementRequest(["type": .string("agreement")]))
        assertLandsOnAgreementPage(decision, router, readonly: false, "强更页")
        XCTAssertEqual(decision.reason, GuardReason.forceUpdateException)
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate, Self.agreement])
        XCTAssertEqual(router.path.last?.fromForceUpdatePage, true)

        router.path.removeLast()
        guardState.privacy = .notDecided
        let dialog = router.openFromPrivacyDialog(agreementRequest(["type": .string("privacy")]))
        assertLandsOnAgreementPage(dialog, router, readonly: false, "强更 + 隐私未决弹窗")
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate, Self.agreement])

        router.path.removeLast()
        guardState.privacy = .basicMode
        let basic = router.openFromForceUpdatePage(agreementRequest(["type": .string("collect_list")]))
        assertLandsOnAgreementPage(basic, router, readonly: false, "强更 + 基本模式")
    }

    // MARK: - App 接线：隐私未决与桥调用方状态

    /// 真实 AppRouting / AppWeb：隐私未决时从弹窗链接打开 Agreement 只读落栈、落点有页面；此时 AppWeb 给桥的调用方状态 privacy 为 not_decided。
    func testPrivacyUndecidedDialogLinkAndBridgeCallerState() throws {
        let fixture = make(account: nil, decision: "not_decided")
        XCTAssertEqual(fixture.routing.privacy.routerPrivacy, .notDecided, "夹具前提：隐私未决")
        fixture.routing.openAgreementFromPrivacyDialog(type: "privacy")
        let decision = try XCTUnwrap(fixture.router.lastDecision)
        assertLandsOnAgreementPage(decision, fixture.router, readonly: true, "App 隐私未决弹窗链接")
        XCTAssertEqual(decision.reason, GuardReason.privacyUndecidedReadonly)
        XCTAssertFalse(fixture.routing.showsPrivacyDialog, "读协议时弹窗让出")

        let web = makeWeb(fixture)
        let caller = web.callerState(fromForceUpdatePage: false)
        XCTAssertEqual(caller.privacy, BridgePrivacy.notDecided, "隐私未决：桥能力按 not_decided 受限")
        XCTAssertNil(caller.accountKey, "未同意不带账号归属")

        fixture.router.path.removeLast()
        XCTAssertTrue(fixture.routing.showsPrivacyDialog, "返回后弹窗回来")
    }

    // MARK: - 参数校验

    /// 契约枚举外的 type、version 低于 1 或不是整数、契约外参数：按现有参数校验拒绝（params_invalid），不落栈、不打开页面。
    func testInvalidParamsRejectedByExistingValidation() {
        let router = makeRouter()
        let cases: [(String, [String: JSONValue])] = [
            ("type 枚举外", ["type": .string("terms")]),
            ("type 空串", ["type": .string("")]),
            ("version 0", ["type": .string("privacy"), "version": .integer(0)]),
            ("version 字符串", ["version": .string("2")]),
            ("契约外参数", ["type": .string("privacy"), "lang": .string("en")]),
        ]
        for (label, values) in cases {
            let decision = router.open(agreementRequest(values))
            XCTAssertEqual(decision.kind, .reject, label)
            XCTAssertEqual(decision.reason, GuardReason.paramsInvalid, label)
            XCTAssertTrue(router.path.isEmpty, "\(label)：不落栈")
        }
        guardState.privacy = .notDecided
        let undecided = router.open(agreementRequest(["type": .string("terms")]))
        XCTAssertEqual(undecided.kind, .reject, "隐私未决也照样校验参数")
        XCTAssertEqual(undecided.reason, GuardReason.paramsInvalid)
        XCTAssertTrue(router.path.isEmpty)
    }
}
