#!/usr/bin/env bash
# APP-09v-b 提现记录视觉测试入口：固定指定模拟器的状态栏时间，不并行。
# 用法：bash tools/testing/records-visual-tests.sh <UDID> [其余 xcodebuild 参数]
# 录缺图时在命令前加 TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1；默认只比对，不覆盖已有基准。
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo '用法：records-visual-tests.sh <模拟器 UDID> [其余 xcodebuild 参数]' >&2
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
    -only-testing:WalletCoreTests/WalletVectorTests \
    -only-testing:WalletCoreTests/RecordsVisualFixtureTests \
    -only-testing:CouliTests/WithdrawRecordsTests \
    -only-testing:CouliTests/RecordsVisualLayoutTests \
    -only-testing:CouliTests/RecordsVisualStateTests \
    -only-testing:CouliTests/RecordsVisualPagingTests \
    -only-testing:CouliTests/RecordsVisualAdaptTests \
    -only-testing:CouliTests/RecordsVisualMoneyTests \
    -only-testing:CouliTests/RecordsVisualSnapshotTests \
    -only-testing:CouliTests/RecordsVisualR1Tests \
    -only-testing:CouliUITests/RecordsVisualUITests
fi

exec xcodebuild -scheme Couli -configuration Debug "$@" \
  -destination "platform=iOS Simulator,id=$simulator_udid" -parallel-testing-enabled NO test
