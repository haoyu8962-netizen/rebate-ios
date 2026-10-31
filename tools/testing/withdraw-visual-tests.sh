#!/usr/bin/env bash
# APP-09v-c 提现页视觉测试入口：固定指定模拟器的状态栏时间，不并行。
# 用法：bash tools/testing/withdraw-visual-tests.sh <UDID> [其余 xcodebuild 参数]
# 录缺图时在命令前加 TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1；默认只比对，不覆盖已有基准。
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo '用法：withdraw-visual-tests.sh <模拟器 UDID> [其余 xcodebuild 参数]' >&2
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
    -only-testing:WalletCoreTests/WithdrawVisualFixtureTests \
    -only-testing:CouliTests/WithdrawVisualFundsGuardTests \
    -only-testing:CouliTests/WithdrawVisualMoneyTests \
    -only-testing:CouliTests/WithdrawVisualOracleTests \
    -only-testing:CouliTests/WithdrawVisualLayoutTests \
    -only-testing:CouliTests/WithdrawVisualPendingTests \
    -only-testing:CouliTests/WithdrawVisualStateTests \
    -only-testing:CouliTests/WithdrawVisualAdaptTests \
    -only-testing:CouliTests/WithdrawVisualPayoutSharedTests \
    -only-testing:CouliTests/WithdrawVisualSnapshotTests \
    -only-testing:CouliTests/WithdrawVisualErrorTests \
    -only-testing:CouliUITests/WithdrawVisualUITests \
    -only-testing:CouliUITests/WithdrawVisualLookUITests \
    -only-testing:CouliUITests/WithdrawVisualAmountUITests \
    -only-testing:CouliTests/StepUpVisualOracleTests \
    -only-testing:CouliTests/StepUpVisualFundsGuardTests \
    -only-testing:CouliTests/StepUpVisualMoneyTests \
    -only-testing:CouliTests/StepUpVisualActionTests \
    -only-testing:CouliTests/StepUpVisualLayoutTests \
    -only-testing:CouliTests/StepUpVisualAdaptTests \
    -only-testing:CouliTests/StepUpVisualSnapshotTests \
    -only-testing:CouliUITests/StepUpVisualUITests
fi

exec xcodebuild -scheme Couli -configuration Debug "$@" \
  -destination "platform=iOS Simulator,id=$simulator_udid" -parallel-testing-enabled NO test
