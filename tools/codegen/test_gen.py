#!/usr/bin/env python3
"""gen.py 的命名冲突探针（标准库 unittest）：python3 tools/codegen/test_gen.py

每个用例把真实快照复制到临时目录，再加入造出来的探针枚举文件，覆盖：
  R1-05 输出文件名冲突（规范化后相同、大小写不同）必须报错，不能静默覆盖；
  R1-06 类型名与模板直接使用的 Swift 类型 / 协议（Decoder 等）冲突时加 Contract 前缀，模板写限定名；
  R1-07 case 名与生成器自带成员（allCases、rawValue、init、unknown…）冲突时改名，rawValue 保持原值。
  R2-02 j_s_o_n_decoder / any_object / int32 等标准库与 Foundation 名字加前缀，模板写模块限定名。
每个会生成代码的用例都对**全部**生成文件（含 DefaultTexts 与 SwiftPM 资源访问器）按 iOS 模拟器做类型检查；
没有 swiftc 时失败，不跳过。
"""

from __future__ import annotations

import importlib.util
import json
import re
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("gen", os.path.join(HERE, "gen.py"))
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

REAL_SNAPSHOT = gen.SNAPSHOT

# Xcode 27 为带资源的 Generated 包生成的 resource_bundle_accessor.swift（逐字取自 DerivedData 的
# Generated.build/DerivedSources）。它用未限定的 Bundle、URL、ProcessInfo，所以类型检查时一并编译：
# 同名枚举若没加 Contract 前缀，这里会编译失败。
RESOURCE_BUNDLE_ACCESSOR = """import class Foundation.Bundle
import class Foundation.ProcessInfo
import struct Foundation.URL

private class BundleFinder {}

extension Foundation.Bundle {
    /// Returns the resource bundle associated with the current Swift module.
    static nonisolated let module: Bundle = {
        let bundleName = "Generated_Generated"

        let overrides: [URL]
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
                       ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            overrides = [URL(fileURLWithPath: override)]
        } else {
            overrides = []
        }
        #else
        overrides = []
        #endif

        let candidates = overrides + [
            Bundle.main.resourceURL,
            Bundle(for: BundleFinder.self).resourceURL,
            Bundle.main.bundleURL,
        ]

        for candidate in candidates {
            let bundlePath = candidate?.appendingPathComponent(bundleName + ".bundle")
            if let bundle = bundlePath.flatMap(Bundle.init(url:)) {
                return bundle
            }
        }
        fatalError("unable to find bundle named Generated_Generated")
    }()
}
"""


def has_swiftc() -> bool:
    return shutil.which("xcrun") is not None and subprocess.run(
        ["xcrun", "--find", "swiftc"], capture_output=True
    ).returncode == 0


class ProbeSnapshot(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gen-probe-")
        self.snapshot = os.path.join(self.tmp, "snapshot")
        shutil.copytree(REAL_SNAPSHOT, self.snapshot)
        gen.SNAPSHOT = self.snapshot

    def tearDown(self):
        gen.SNAPSHOT = REAL_SNAPSHOT
        shutil.rmtree(self.tmp)

    def add_enum_file(self, filename: str, enums: dict[str, list[str]]):
        doc = {"enums": {key: {"values": {value: {} for value in values}} for key, values in enums.items()}}
        with open(os.path.join(self.snapshot, "contracts", "enums", filename), "w", encoding="utf-8") as f:
            json.dump(doc, f)

    def typecheck(self, files: dict[str, str]):
        """对全部生成的 Swift 文件（含 DefaultTexts）加上 SwiftPM 资源访问器，按 iOS 模拟器做类型检查。"""
        if not has_swiftc():
            self.fail("xcrun swiftc 不可用：生成物类型检查是必需步骤，不能跳过")
        out = os.path.join(self.tmp, "out")
        tree = gen.split_roots(files)[gen.OUTPUT]
        gen.write_tree(tree, out)
        sources = sorted(os.path.join(out, rel) for rel in tree if rel.endswith(".swift"))
        self.assertIn(os.path.join(out, "DefaultTexts.swift"), sources)
        accessor = os.path.join(self.tmp, "resource_bundle_accessor.swift")
        with open(accessor, "w", encoding="utf-8") as f:
            f.write(RESOURCE_BUNDLE_ACCESSOR)
        sdk = subprocess.run(
            ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], capture_output=True, text=True, check=True
        ).stdout.strip()
        result = subprocess.run(
            ["xcrun", "--sdk", "iphonesimulator", "swiftc", "-typecheck", "-parse-as-library", "-swift-version", "6",
             "-module-name", "Generated", "-sdk", sdk, "-target", "arm64-apple-ios16.0-simulator", "-D", "DEBUG"]
            + sources + [accessor],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, "生成物无法通过类型检查：\n" + result.stderr[-4000:])

    # ---- R1-05 ----

    def test_normalized_enum_file_names_collide(self):
        self.add_enum_file("foo-bar.json", {"first_probe": ["a"]})
        self.add_enum_file("foo_bar.json", {"second_probe": ["b"]})
        with self.assertRaisesRegex(gen.GenError, "输出文件名冲突"):
            gen.generate()

    def test_case_insensitive_file_names_collide(self):
        # FooBar 与 Foobar 只差大小写：macOS 文件系统上是同一个文件。
        self.add_enum_file("foo_bar.json", {"first_probe": ["a"]})
        self.add_enum_file("foobar.json", {"second_probe": ["b"]})
        with self.assertRaisesRegex(gen.GenError, "输出文件名冲突"):
            gen.generate()

    def test_distinct_file_names_keep_every_enum(self):
        self.add_enum_file("probe_one.json", {"first_probe": ["a"]})
        self.add_enum_file("probe_two.json", {"second_probe": ["b"]})
        files = gen.generate()
        self.assertIn("public enum FirstProbe:", files["Enums+ProbeOne.swift"])
        self.assertIn("public enum SecondProbe:", files["Enums+ProbeTwo.swift"])

    # ---- R1-06 ----

    def test_type_names_shadowing_template_types_get_contract_prefix(self):
        probes = ["decoder", "encoder", "codable", "case_iterable", "string", "sendable", "generated", "swift"]
        self.add_enum_file("probe_types.json", {key: ["a", "b"] for key in probes})
        files = gen.generate()
        body = files["Enums+ProbeTypes.swift"]
        for type_name in ["Decoder", "Encoder", "Codable", "CaseIterable", "String", "Sendable", "Generated", "Swift"]:
            self.assertIn(f"public enum Contract{type_name}:", body)
            self.assertNotIn(f"public enum {type_name}:", body)
        self.assertIn("init(from decoder: any Swift.Decoder)", body)
        self.typecheck(files)

    def test_prefixed_type_name_still_conflicting_is_an_error(self):
        self.add_enum_file("probe_dup.json", {"decoder": ["a"], "contract_decoder": ["b"]})
        with self.assertRaisesRegex(gen.GenError, "ContractDecoder"):
            gen.generate()

    def test_r2_02_foundation_and_stdlib_names_get_contract_prefix(self):
        # 评审 R2-02：j_s_o_n_decoder → JSONDecoder 曾遮蔽 DefaultTexts 里的 JSONDecoder()；any_object、int32 未加前缀。
        probes = {"j_s_o_n_decoder": "JSONDecoder", "any_object": "AnyObject", "int32": "Int32",
                  "bundle": "Bundle", "data": "Data", "u_r_l": "URL", "process_info": "ProcessInfo"}
        self.add_enum_file("probe_r2.json", {key: ["a", "b"] for key in probes})
        files = gen.generate()
        body = files["Enums+ProbeR2.swift"]
        for type_name in probes.values():
            self.assertIn(f"public enum Contract{type_name}:", body)
        texts = files["DefaultTexts.swift"]
        for qualified in ("Foundation.JSONDecoder()", "Foundation.Bundle.module", "Foundation.Data(contentsOf:"):
            self.assertIn(qualified, texts)
        self.typecheck(files)

    def test_every_conflict_name_is_prefixed_and_whole_output_typechecks(self):
        # 冲突表里每个能由枚举键得到的名字都造一个探针枚举，全部生成文件一起类型检查。
        # 真实快照里已经出现的（如 scene → ContractScene）不再重复造。
        taken = {type_name for _, group in gen.collect_enums() for _, type_name, _ in group}
        names = sorted(
            n for n in gen.TYPE_NAME_CONFLICTS if gen.upper_camel(n) == n and "Contract" + n not in taken
        )
        self.assertGreater(len(names), 150)
        self.add_enum_file("probe_all_conflicts.json", {name: ["a"] for name in names})
        files = gen.generate()
        body = files["Enums+ProbeAllConflicts.swift"]
        for name in names:
            self.assertIn(f"public enum Contract{name}:", body)
        self.typecheck(files)

    # ---- R1-07 ----

    def test_case_names_shadowing_generated_members_are_renamed(self):
        values = ["all_cases", "raw_value", "hash_value", "init", "unknown", "self", "encode", "plain"]
        self.add_enum_file("probe_cases.json", {"member_probe": values})
        files = gen.generate()
        body = files["Enums+ProbeCases.swift"]
        for name, raw in [
            ("contractAllCases", "all_cases"),
            ("contractRawValue", "raw_value"),
            ("contractHashValue", "hash_value"),
            ("contractInit", "init"),
            ("contractUnknown", "unknown"),
            ("contractSelf", "self"),
            ("contractEncode", "encode"),
        ]:
            self.assertIn(f'case {name} = "{raw}"', body)
        self.assertIn("    case plain\n", body)
        self.assertIn('case unknown = "__unknown__"', body)
        self.assertIn('"member_probe": [' + ", ".join(f'"{v}"' for v in values) + "]", files["ContractEnums.swift"])
        self.typecheck(files)

    def test_renamed_case_colliding_with_another_value_is_an_error(self):
        self.add_enum_file("probe_case_dup.json", {"member_probe": ["all_cases", "contract_all_cases"]})
        with self.assertRaisesRegex(gen.GenError, "contractAllCases"):
            gen.generate()

    # ---- APP-03b：埋点字段名禁用规则（events.yaml 头注释），命中即生成失败 ----

    def set_event_fields(self, fields: dict):
        path = os.path.join(self.snapshot, "specs", "events.json")
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
        doc["events"]["probe_event"] = {"description": "probe", "source": "probe", "fields": fields}
        with open(path, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False)

    def test_forbidden_event_field_segments_fail_generation(self):
        for name in ["promo_url", "item_url", "tpwd", "relation_id", "deeplink", "adzone_id", "href",
                     "sub_union_id", "my_custom_parameters", "pid", "union_link"]:
            with self.subTest(name=name):
                self.set_event_fields({name: {"type": "string", "required": False}})
                with self.assertRaisesRegex(gen.GenError, name):
                    gen.generate()

    def test_event_field_exceptions_and_common_name_clash(self):
        self.set_event_fields({"link_id": {"type": "string", "required": True},
                               "pid_scene": {"type": "string", "required": False}})
        files = gen.generate()
        self.assertIn("public static func probeEvent(", files["TrackerEvents.swift"])
        self.set_event_fields({"page": {"type": "string", "required": True}})
        with self.assertRaisesRegex(gen.GenError, "公共字段同名"):
            gen.generate()

    def test_required_when_must_reference_existing_field(self):
        self.set_event_fields({"attempt_id": {"type": "string", "required_when": {"phase": "purchase"}}})
        with self.assertRaisesRegex(gen.GenError, "required_when"):
            gen.generate()

    # ---- 现有快照 ----

    def test_real_snapshot_typechecks_and_marks_debug_only_table(self):
        files = gen.generate()
        self.assertIn(gen.DEBUG_ONLY_ROUTE_MARKER, files["Routes.swift"])
        app = files[gen.APP_PREFIX + "DebugOnlyRoutes.swift"]
        self.assertTrue(app.splitlines()[3] == "#if DEBUG", "App 侧 debug_only 表必须整个在 #if DEBUG 里")
        self.assertIn(gen.DEBUG_ONLY_ROUTE_MARKER, app)
        self.assertGreater(len(gen.DEBUG_ONLY_ROUTE_MARKER.encode()), 15, "标记必须长于 15 字节，避免被内联")
        self.assertIn("public static func appLaunch(", files["TrackerEvents.swift"])
        self.assertNotRegex(files["DefaultConfig.swift"], r"https?://|example\\.test")
        self.typecheck(files)



# ---- DS-02-iOS-1：令牌段（colorsDark / componentNumber / shadowsDark、8 位色）brief §2.2-6 ----


def swift_table(body: str, name: str) -> dict:
    """从生成的 DesignTokens.swift 里取一个 [String: 标量] 表；没有该表返回 None。"""
    match = re.search(r"public static let " + re.escape(name) + r": \[[^\]]+\] = \[\n(.*?)\n    \]", body, re.S)
    if not match:
        return None
    table = {}
    for line in match.group(1).splitlines():
        row = re.fullmatch(r'\s*"([^"]+)": (.+),', line)
        if row:
            raw = row.group(2)
            table[row.group(1)] = json.loads(raw) if raw.startswith('"') else float(raw) if "." in raw else int(raw)
    return table


def swift_shadow_keys(body: str, name: str) -> dict:
    match = re.search(r"public static let " + re.escape(name) + r": \[Swift\.String: \[ShadowLayer\]\] = \[\n(.*?)\n    \]\n",
                      body, re.S)
    if not match:
        return None
    rows = {}
    for key, rest in re.findall(r'^        "([^"]+)": (\[\],|\[\n.*?\n        \],)', match.group(1), re.S | re.M):
        rows[key] = re.findall(r"color: \"([^\"]+)\", opacity: ([0-9.]+)", rest)
    return rows


class TokenSegments(unittest.TestCase):
    """真实快照复制到临时目录后改 design-tokens.json；不继承 ProbeSnapshot（避免把探针用例再跑一遍），只借它的类型检查。"""

    setUp = ProbeSnapshot.setUp
    tearDown = ProbeSnapshot.tearDown
    typecheck = ProbeSnapshot.typecheck

    def tokens_path(self):
        return os.path.join(self.snapshot, "design", "design-tokens.json")

    def edit_tokens(self, change):
        with open(self.tokens_path(), encoding="utf-8") as f:
            doc = json.load(f)
        change(doc["tokens"])
        with open(self.tokens_path(), "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False)

    def reset(self):
        self.tearDown()
        self.setUp()

    def tokens_swift(self) -> str:
        return gen.generate()["DesignTokens.swift"]

    def test_locked_snapshot_emits_every_segment(self):
        with open(self.tokens_path(), encoding="utf-8") as f:
            doc = json.load(f)
        body = self.tokens_swift()
        self.assertIn('public static let version: Swift.String = "0.5.1"', body)
        colors, dark = swift_table(body, "colors"), swift_table(body, "colorsDark")
        self.assertIsNotNone(dark, "缺 colorsDark 段")
        self.assertEqual(set(colors), set(dark))
        self.assertEqual(colors["overlay.scrim"], "#28251F66")
        self.assertEqual(dark["overlay.scrim"], "#0000008C")
        ints, numbers = swift_table(body, "component"), swift_table(body, "componentNumber")
        self.assertIsNotNone(numbers, "缺 componentNumber 段")
        self.assertEqual(numbers, {"checkbox.max-scale": 1.5})
        self.assertFalse(set(ints) & set(numbers), "同一路径不能同时在两段")
        def count(node):
            return 1 if "value" in node else sum(count(child) for child in node.values())
        self.assertEqual(len(ints) + len(numbers), count(doc["tokens"]["component"]))
        light, night = swift_shadow_keys(body, "shadows"), swift_shadow_keys(body, "shadowsDark")
        self.assertIsNotNone(night, "缺 shadowsDark 段")
        self.assertEqual(set(light), set(night))
        self.assertEqual(night["none"], [])
        self.assertEqual(night["card"], [("#000000", "0.3")])
        self.assertEqual(night["floating"], [("#000000", "0.45")])

    def test_eight_digit_color_kept_verbatim_in_css_order(self):
        def change(tokens):
            tokens["color"]["brand"]["primary"]["value"] = "#c4482080"
            tokens["color"]["brand"]["primary"]["dark"] = "#80C44820"
        self.edit_tokens(change)
        body = self.tokens_swift()
        self.assertEqual(swift_table(body, "colors")["brand.primary"], "#c4482080", "源字符串原样，不改大小写、不换成 ARGB")
        self.assertEqual(swift_table(body, "colorsDark")["brand.primary"], "#80C44820")

    def test_malformed_colors_fail(self):
        for field in ("value", "dark"):
            for bad in ("#12345", "#1234567", "#123456789", "#GG0000", "C44820", "#C44820 ", ""):
                with self.subTest(field=field, bad=bad):
                    def change(tokens, bad=bad, field=field):
                        tokens["color"]["brand"]["primary"][field] = bad
                    self.reset()
                    self.edit_tokens(change)
                    with self.assertRaises(gen.GenError):
                        gen.generate()

    def test_missing_dark_fails_instead_of_falling_back(self):
        self.edit_tokens(lambda tokens: tokens["color"]["text"]["link"].pop("dark"))
        with self.assertRaisesRegex(gen.GenError, r"text\.link"):
            gen.generate()

    def test_dark_values_come_from_dark_field(self):
        def change(tokens):
            tokens["color"]["text"]["link"]["value"] = "#111111"
            tokens["color"]["text"]["link"]["dark"] = "#222222"
        self.edit_tokens(change)
        body = self.tokens_swift()
        self.assertEqual(swift_table(body, "colors")["text.link"], "#111111")
        self.assertEqual(swift_table(body, "colorsDark")["text.link"], "#222222")

    def test_component_split_by_type_not_by_value(self):
        def change(tokens):
            tokens["component"]["probe"] = {
                "ratio": {"type": "number", "value": 2.25},
                "whole": {"type": "number", "value": 3},
                "size": {"type": "dimension", "value": 40, "unit": "logical"},
            }
        self.edit_tokens(change)
        body = self.tokens_swift()
        ints, numbers = swift_table(body, "component"), swift_table(body, "componentNumber")
        self.assertEqual(numbers.get("probe.ratio"), 2.25)
        self.assertEqual(numbers.get("probe.whole"), 3.0, "type number 即使是整数也进 componentNumber")
        self.assertEqual(ints.get("probe.size"), 40)
        self.assertNotIn("probe.ratio", ints)
        self.assertNotIn("probe.whole", ints)
        self.assertNotIn("probe.size", numbers)

    def test_fractional_dimension_fails(self):
        self.edit_tokens(lambda tokens: tokens["component"]["chip"]["height"].update(value=32.5))
        with self.assertRaises(gen.GenError):
            gen.generate()

    def test_shadow_dark_rules(self):
        self.edit_tokens(lambda tokens: tokens["shadow"]["card"].pop("dark"))
        with self.assertRaisesRegex(gen.GenError, r"shadow\.card"):
            gen.generate()
        self.reset()
        self.edit_tokens(lambda tokens: tokens["shadow"]["none"].pop("dark", None))
        self.assertEqual(swift_shadow_keys(self.tokens_swift(), "shadowsDark")["none"], [])

    def test_minimal_token_fixture_output_typechecks(self):
        def change(tokens):
            tokens["color"]["probe"] = {"veil": {"type": "color", "value": "#0A0B0C0D", "dark": "#0d0c0b0a"}}
            tokens["component"]["probe"] = {"scale": {"type": "number", "value": 1.25}}
        self.edit_tokens(change)
        files = gen.generate()
        body = files["DesignTokens.swift"]
        self.assertEqual(swift_table(body, "colorsDark")["probe.veil"], "#0d0c0b0a")
        self.assertIn("public static let componentNumber: [Swift.String: Swift.Double]", body)
        self.assertIn("public static let shadowsDark: [Swift.String: [ShadowLayer]]", body)
        self.typecheck(files)


if __name__ == "__main__":
    unittest.main(verbosity=2)
