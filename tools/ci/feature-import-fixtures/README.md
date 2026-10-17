# check-feature-imports 违反样例（FU-IOS-0712，F-IOS-01 / F-X-07）

每个子目录是一棵最小的 `Features/Sources`：文件名 `<Feature>__<文件名>.fixture` 由 `tools/ci/verify.sh` 的
「check-feature-imports 违反样例」一步还原到临时目录（另补一个 `Search/SearchScreen.swift`），再运行
`check-feature-imports.py`，退出码必须等于同目录 `expect` 里的值（1 = 违反，4 = 扫不完整 / 无法确认注释、字符串边界）。

- `comment-prefixed-if/`：块注释后的 `#if`（F-IOS-01：原来按行首匹配，展平漏掉，非活动分支里的 import 逃过检查）。第 1 轮修复（R1-02）起
  指令不在行首无法确认，退出 4（原为 1）。
- `comment-marker-moves-boundary/`：评审 R1-02 原样例 `/* #if note */ … // */`（「从任意位置删到行尾」会删掉注释结束符、让 import 落进注释）：块注释里出现指令记号，退出 4。
- `inline-comment-then-if/`：行内 `/* */` 之后同一行接 `#if`：退出 4。
- `string-with-if/`：普通字符串里的 `#if`，下一行是真实跨 Feature 导入：退出 4（字符串里的指令记号一律不猜）。
- `multiline-string-endif/`：多行字符串里的 `#endif`，之后是真实非活动分支导入：退出 4。
- `glued-comment-import/`：非活动分支里注释紧贴的导入 `@testable/* */import/**/Search`（指令行换成等长空格、不依赖空白）：违反 1。
- `bare-slash-regex-quote/`：裸正则 `/"/` 后跟跨 Feature 导入（无法确认是除法还是正则、引号会不会开字符串）：退出 4。
- `lone-cr-inactive-branch/`：只用单独 CR 换行的非活动分支（`.gitattributes` 标 `-text`，CR 字节原样入库）。
- `unknown-source-file/`：Feature 目录里有不是 .swift 的源码文件。

另有两种 git 存不了的情况由 verify 现造：子目录列不出内容（chmod 000）、条目属性查不了（chmod 444）。
后缀用 `.fixture`：不进 swiftlint / swiftformat / 源码树检查的扫描范围。
