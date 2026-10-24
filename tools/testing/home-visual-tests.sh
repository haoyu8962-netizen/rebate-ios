#!/usr/bin/env bash
# APP-11v 截图入口：固定指定模拟器的状态栏时间，并禁止 Xcode 另开未设时间的克隆设备。
# 用法：bash tools/testing/home-visual-tests.sh <UDID> [其余 xcodebuild 参数]
# 录缺图时在命令前加 TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1；默认只比对，不覆盖已有基准。
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo '用法：home-visual-tests.sh <模拟器 UDID> [其余 xcodebuild 参数]' >&2
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
    -only-testing:HomeTests/HomeVisualFixtureTests \
    -only-testing:HomeTests/HomeVisualHeaderTests \
    -only-testing:HomeTests/HomeVisualFeedPagingTests \
    -only-testing:HomeTests/HomeVisualFeedWindowTests \
    -only-testing:HomeTests/HomeVisualSnapshotTests \
    -only-testing:CouliTests/HomeVisualAppSnapshotTests \
    -only-testing:CouliUITests/HomeVisualBehaviorTests \
    -only-testing:CouliUITests/HomeVisualAccessibilityTests \
    -only-testing:CouliUITests/HomeVisualFeedWindowUITests \
    -only-testing:CouliUITests/HomeVisualLayoutTests \
    -only-testing:CouliUITests/HomeVisualOverlayTests \
    -only-testing:CouliUITests/HomeVisualScreenSnapshotTests
fi

exec xcodebuild -scheme Couli -configuration Debug "$@" \
  -destination "platform=iOS Simulator,id=$simulator_udid" -parallel-testing-enabled NO test
