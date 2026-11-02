#!/usr/bin/env bash
# APP-12w-b「隐私中心 / 关于 / 联系客服」视觉测试入口：固定指定模拟器的状态栏时间，不并行。
# 用法：bash tools/testing/privacy-visual-tests.sh <UDID> [其余 xcodebuild 参数]
# 录缺图时在命令前加 TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1；默认只比对，不覆盖已有基准。
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo '用法：privacy-visual-tests.sh <模拟器 UDID> [其余 xcodebuild 参数]' >&2
  exit 64
fi
simulator_udid="$1"
shift
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

xcrun simctl bootstatus "$simulator_udid" -b
xcrun simctl status_bar "$simulator_udid" override --time '9:41'

if [[ $# -eq 0 ]]; then
  set -- \
    -only-testing:MeCoreTests/MeVectorTests \
    -only-testing:CouliTests/MeVisualFundsGuardTests \
    -only-testing:CouliTests/SettingsVisualGuardTests \
    -only-testing:CouliTests/MePrivacyTests \
    -only-testing:CouliTests/MeCsAboutTests \
    -only-testing:CouliTests/PrivacyVisualFixtureTests \
    -only-testing:CouliTests/PrivacyVisualGuardTests \
    -only-testing:CouliTests/PrivacyVisualRedLineTests \
    -only-testing:CouliTests/PrivacyVisualLayoutTests \
    -only-testing:CouliTests/PrivacyVisualAboutTests \
    -only-testing:CouliTests/PrivacyVisualCsTests \
    -only-testing:CouliTests/PrivacyVisualNoticeTests \
    -only-testing:CouliTests/PrivacyVisualBehaviorTests \
    -only-testing:CouliTests/PrivacyVisualPaletteTests \
    -only-testing:CouliTests/PrivacyVisualAdaptTests \
    -only-testing:CouliTests/PrivacyVisualFollowupTests \
    -only-testing:CouliTests/PrivacyVisualSnapshotTests \
    -only-testing:CouliUITests/PrivacyVisualUITests
fi

exec xcodebuild -scheme Couli -configuration Debug "$@" \
  -destination "platform=iOS Simulator,id=$simulator_udid" -parallel-testing-enabled NO test
