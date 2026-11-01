#!/usr/bin/env bash
# APP-12v「我的」视觉测试入口：固定指定模拟器的状态栏时间，不并行。
# 用法：bash tools/testing/me-visual-tests.sh <UDID> [其余 xcodebuild 参数]
# 录缺图时在命令前加 TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1；默认只比对，不覆盖已有基准。
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo '用法：me-visual-tests.sh <模拟器 UDID> [其余 xcodebuild 参数]' >&2
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
    -only-testing:CouliTests/MeVisualFixtureTests \
    -only-testing:CouliTests/MeVisualFundsGuardTests \
    -only-testing:CouliTests/MeVisualOracleTests \
    -only-testing:CouliTests/MeVisualLayoutTests \
    -only-testing:CouliTests/MeVisualPaletteTests \
    -only-testing:CouliTests/MeVisualStateTests \
    -only-testing:CouliTests/MeVisualAdaptTests \
    -only-testing:CouliTests/MeVisualNoticeTests \
    -only-testing:CouliTests/MeVisualBehaviorTests \
    -only-testing:CouliTests/MeVisualRestrictedTests \
    -only-testing:CouliTests/MeVisualMoneyTests \
    -only-testing:CouliTests/MeVisualSnapshotTests \
    -only-testing:CouliTests/MeTabTests \
    -only-testing:CouliUITests/MeVisualUITests \
    -only-testing:CouliUITests/MeVisualMoneyUITests
fi

exec xcodebuild -scheme Couli -configuration Debug "$@" \
  -destination "platform=iOS Simulator,id=$simulator_udid" -parallel-testing-enabled NO test
