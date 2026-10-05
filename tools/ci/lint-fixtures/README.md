# SwiftLint 违反样例

每个子目录名 = 一条自定义规则；目录里的样例**必须**被该规则拦下（`tools/ci/verify.sh` 的
「lint 违反样例」一步逐个检查）。`allowed/` 里的样例必须**不**触发任何自定义规则（证明排除项生效）。
本目录在 `.swiftlint.yml` 与 `.swiftformat` 里被排除，不参与正常 lint。
