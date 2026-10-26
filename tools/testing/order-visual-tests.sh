#!/usr/bin/env bash
# APP-08v 订单视觉测试入口：固定指定模拟器的状态栏时间，不并行。
# 用法：bash tools/testing/order-visual-tests.sh <UDID> [其余 xcodebuild 参数]
# 录缺图时在命令前加 TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1；默认只比对，不覆盖已有基准。
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo '用法：order-visual-tests.sh <模拟器 UDID> [其余 xcodebuild 参数]' >&2
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
    -only-testing:OrderCoreTests/OrderVectorTests \
    -only-testing:OrderCoreTests/OrderVisualFixtureTests \
    -only-testing:OrdersTests/OrderListVisualClaimTests \
    -only-testing:CouliTests/OrderVisualOracleTests \
    -only-testing:CouliTests/OrderListVisualLayoutTests \
    -only-testing:CouliTests/OrderListVisualCardTests \
    -only-testing:CouliTests/OrderListVisualAdaptTests \
    -only-testing:CouliTests/OrderListVisualSnapshotTests \
    -only-testing:CouliTests/OrderListVisualReviewR1Tests \
    -only-testing:CouliTests/OrderListVisualReviewR2Tests \
    -only-testing:CouliUITests/OrderListVisualUITests \
    -only-testing:CouliUITests/OrderListVisualReviewR2UITests
fi

exec xcodebuild -scheme Couli -configuration Debug "$@" \
  -destination "platform=iOS Simulator,id=$simulator_udid" -parallel-testing-enabled NO test
