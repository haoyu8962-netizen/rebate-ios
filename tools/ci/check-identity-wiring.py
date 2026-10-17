#!/usr/bin/env python3
"""身份暂时未知时的页面展示接线检查（FU-IOS-0713 接口约定 T-01，第 3 版）。

    python3 tools/ci/check-identity-wiring.py [仓库根]   检查；违反退出 1，文件读不出退出 2
    python3 tools/ci/check-identity-wiring.py --self-test  用内置漏接样例自测（每类漏接都必须被拦，合规样例必须放行）

为什么要查：「是否转圈」「本页【重试】是否可见可用」「返回是否可见」由执行器 / 状态上的展示接口决定
（StepUpUiState.showsSending / showsVerifying / showsRecheck、RealNameSnapshot.showsSubmitting / showsRecheck、
LaborSnapshot.showsSigning / showsRecheck、RiskNoticeController.showsBack），单测断言这些接口；页面只做受约束的一行转发。

受约束的转发结构（swiftformat --lint 保证缩进反映嵌套，本检查依赖它）：
  A. 属性转发：转圈只按 shows*；旧字段（phase / submitting / signing / model?.showBack）不得出现；展示变量不得被重新赋值、
     isLoading 不得写死。
  B. 【重试】块必须正好是
         if <快照>.showsRecheck {
             CouliButton(texts.text("wallet.retry")[, kind: .text], action: actions.recheck)
             [.accessibilityIdentifier(...)]
         }
     ——条件不得追加别的条件；按钮不得带 isEnabled / 别的回调；块内除 accessibilityIdentifier 外不得有修饰符（禁用、隐藏、不可点）。
  C. 【重试】块可达、可点：与页面主按钮（step_up.submit / realname.submit / labor.sign）在同一容器、同一缩进，二者之间不跨出容器；
     块的每一层外层（容器、闭包、函数）都不得是条件分支（if / else / switch / case / guard / #if，即死分支或被条件覆盖），外层行与外层
     容器闭合后的修饰符里不得有 .disabled / .hidden / .allowsHitTesting(false) / .opacity(0)。
  D. Actions.make 的 recheck 必须转到执行器的 recheckIdentity。
  E. 返回：`let showBack = controller.showsBack` 只此一处；`.navigationBarBackButtonHidden(!showBack || state.logoutDialog != nil)`
     只此一处、条件不得追加；showBack 不得再出现在别处。
只用 Python 3 标准库。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

STEP_UP = "Packages/Features/Sources/Wallet/StepUpSheet.swift"
REAL_NAME = "Packages/Features/Sources/Wallet/IdentityScreens.swift"
LABOR = "Packages/Features/Sources/Wallet/LaborAgreementScreen.swift"
RISK = "Packages/Features/Sources/Me/RiskNoticeScreen.swift"

# 文件 → (说明, 必须出现, 不得出现, 【重试】块：(快照变量, 主按钮文案键) 或 None)
RULES = {
    STEP_UP: ("二次验证面板", [
        r"if\s+state\.showsSending\s*\{",
        r"isLoading:\s*state\.showsVerifying\s*[,)]",
        r"recheck:\s*\{\s*\[weak controller\]\s*in\s*controller\?\.recheckIdentity\(instance:\s*instance\)\s*\}",
    ], [
        r"state\.phase\s*==\s*\.sending",
        r"isLoading:\s*state\.phase\s*==\s*\.verifying",
        r"isLoading:\s*true",
        r"\bshows(Sending|Verifying|Recheck)\s*=[^=]",
    ], ("state", "step_up.submit")),
    REAL_NAME: ("实名页", [
        r"isLoading:\s*snapshot\.showsSubmitting\s*[,)]",
        r"recheck:\s*\{\s*\[weak controller\]\s*in\s*controller\?\.recheckIdentity\(\)\s*\}",
    ], [
        r"isLoading:\s*snapshot\.submitting\b",
        r"isLoading:\s*true",
        r"\bshows(Submitting|Recheck)\s*=[^=]",
    ], ("snapshot", "realname.submit")),
    LABOR: ("劳务协议页", [
        r"isLoading:\s*snapshot\.showsSigning\s*[,)]",
        r"recheck:\s*\{\s*\[weak controller\]\s*in\s*controller\?\.recheckIdentity\(\)\s*\}",
    ], [
        r"isLoading:\s*snapshot\.signing\b",
        r"isLoading:\s*true",
        r"\bshows(Signing|Recheck)\s*=[^=]",
    ], ("snapshot", "labor.sign")),
    RISK: ("风险说明", [], [
        r"model\??\.showBack",
        r"enteredBy10006",
    ], None),
}

LOADING = {
    STEP_UP: r"isLoading:\s*state\.showsVerifying\s*[,)]",
    REAL_NAME: r"isLoading:\s*snapshot\.showsSubmitting\s*[,)]",
    LABOR: r"isLoading:\s*snapshot\.showsSigning\s*[,)]",
}

BLOCKERS = re.compile(r"\.disabled\(|\.hidden\(|\.allowsHitTesting\(\s*false|\.opacity\(\s*0(\.0)?\s*\)")
BRANCH = re.compile(r"^\s*(\}\s*)?(if|else|switch|case|default|guard|#if|#else|#elseif)\b")


def indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def meaningful(line: str) -> bool:
    stripped = line.strip()
    return bool(stripped) and not stripped.startswith("//")


def check_block(name: str, lines: list[str], var: str, main_key: str) -> list[str]:
    errors = []
    head = re.compile(r"^(\s*)if\s+" + var + r"\.showsRecheck\s*\{\s*$")
    hits = [i for i, line in enumerate(lines) if f"{var}.showsRecheck" in line]
    exact = [i for i in hits if head.match(lines[i])]
    if not hits:
        return [f"{name}：缺少【重试】块（if {var}.showsRecheck {{）"]
    for i in hits:
        if i not in exact:
            errors.append(f"{name}:{i + 1}：【重试】条件被改写或追加了条件")
    for i in exact:
        ind = indent(lines[i])
        button = lines[i + 1] if i + 1 < len(lines) else ""
        if not re.match(r"^\s*CouliButton\(texts\.text\(\"wallet\.retry\"\),( kind: \.text,)? action: actions\.recheck\)\s*$",
                        button) or indent(button) != ind + 4:
            errors.append(f"{name}:{i + 2}：【重试】按钮必须是 CouliButton(texts.text(\"wallet.retry\"), action: actions.recheck)，"
                          "不得带 isEnabled 或别的回调")
        j = i + 2
        while j < len(lines) and not (indent(lines[j]) == ind and lines[j].strip().startswith("}")):
            if meaningful(lines[j]) and not lines[j].strip().startswith(".accessibilityIdentifier("):
                errors.append(f"{name}:{j + 1}：【重试】块内不得有别的内容或修饰符（{lines[j].strip()}）")
            j += 1
        end = j
        # C：与主按钮同一容器、同一缩进
        main = None
        for k in range(end + 1, len(lines)):
            if meaningful(lines[k]) and indent(lines[k]) < ind:
                break
            if indent(lines[k]) == ind and f'CouliButton(texts.text("{main_key}")' in lines[k] or (
                indent(lines[k]) == ind and lines[k].strip() == "CouliButton(" and main_key in "".join(lines[k:k + 2])
            ):
                main = k
                break
        if main is None:
            errors.append(f"{name}:{i + 1}：【重试】块与主按钮 {main_key} 不在同一容器同一层")
        # C：外层不得是条件分支，外层行与外层容器闭合后的修饰符不得禁用 / 隐藏
        level = ind
        k = i - 1
        while k >= 0 and level > 0:
            line = lines[k]
            if meaningful(line) and indent(line) < level:
                level = indent(line)
                if BRANCH.match(line):
                    errors.append(f"{name}:{k + 1}：【重试】块在条件分支里（{line.strip()}）")
                if BLOCKERS.search(line):
                    errors.append(f"{name}:{k + 1}：【重试】块的外层被禁用 / 隐藏（{line.strip()}）")
                # 这一层容器闭合之后的完整修饰符链：跨过修饰符的参数与闭包（缩进更深的行、同层的 ) / } 收尾）继续，直到链结束
                m = end + 1
                while m < len(lines) and not (indent(lines[m]) == level and lines[m].strip().startswith("}")):
                    if meaningful(lines[m]) and indent(lines[m]) < level:
                        break
                    m += 1
                m += 1
                while m < len(lines):
                    line = lines[m]
                    if meaningful(line):
                        stripped = line.strip()
                        if indent(line) < level:
                            break
                        if indent(line) == level and not stripped.startswith((".", "}", ")")):
                            break
                        if BLOCKERS.search(line):
                            errors.append(f"{name}:{m + 1}：【重试】块的外层容器被禁用 / 隐藏（{stripped}）")
                    m += 1
            k -= 1
    return errors


def check_risk(name: str, text: str) -> list[str]:
    errors = []
    lines = text.splitlines()
    assign = [i for i, line in enumerate(lines) if re.match(r"^\s*let\s+showBack\s*=\s*controller\.showsBack\s*$", line)]
    hidden = [i for i, line in enumerate(lines) if ".navigationBarBackButtonHidden(" in line]
    exact = [i for i in hidden if re.match(r"^\s*\.navigationBarBackButtonHidden\(!showBack \|\| state\.logoutDialog != nil\)\s*$",
                                           lines[i])]
    uses = [i for i, line in enumerate(lines) if re.search(r"\bshowBack\b", line)]
    if len(assign) != 1:
        errors.append(f"{name}：`let showBack = controller.showsBack` 必须恰好一处")
    if len(hidden) != 1 or len(exact) != 1:
        errors.append(f"{name}：返回按钮隐藏条件必须恰好是 `.navigationBarBackButtonHidden(!showBack || state.logoutDialog != nil)`")
    if set(uses) - set(assign) - set(exact):
        errors.append(f"{name}：showBack 不得在别处使用或改写")
    return errors


def check_text(rel: str, text: str) -> list[str]:
    name, must, never, block = RULES[rel]
    errors = []
    for pattern in must:
        if not re.search(pattern, text, re.MULTILINE):
            errors.append(f"{name}：缺少接线 /{pattern}/")
    for pattern in never:
        for match in re.finditer(pattern, text, re.MULTILINE):
            errors.append(f"{name}:{text.count(chr(10), 0, match.start()) + 1}：不得出现 /{pattern}/")
    if rel in LOADING:
        total = len(re.findall(r"isLoading:", text))
        exact = len(re.findall(LOADING[rel], text))
        if total != exact:
            errors.append(f"{name}：isLoading 的完整表达式只能转发展示属性（共 {total} 处，合规 {exact} 处），不得拼接别的条件")
    if block:
        errors += check_block(name, text.splitlines(), *block)
    if rel == RISK:
        errors += check_risk(name, text)
    return errors


def check_repo(root: Path) -> int:
    errors = []
    for rel in RULES:
        try:
            text = (root / rel).read_text(encoding="utf-8")
        except OSError as error:
            print(f"读不出 {rel}：{error}", file=sys.stderr)
            return 2
        errors += check_text(rel, text)
    for line in errors:
        print(line)
    return 1 if errors else 0


# ---- 自测：合规样例必须放行；每类漏接样例必须被拦 ----

GOOD = {
    STEP_UP: """
public struct StepUpActions {
    public static func make(_ controller: StepUpController, _ state: StepUpUiState) -> StepUpActions {
        let instance = state.instance
        return StepUpActions(
            close: { [weak controller] in controller?.close(instance: instance) },
            recheck: { [weak controller] in controller?.recheckIdentity(instance: instance) }
        )
    }
}

struct Body {
    func footer(_ state: StepUpUiState, _ actions: StepUpActions) -> some View {
        VStack(spacing: CouliSpacing.s3) {
            if state.showsRecheck {
                CouliButton(texts.text("wallet.retry"), kind: .text, action: actions.recheck)
                    .accessibilityIdentifier("stepUp.recheck")
            }
            if state.showsSending {
                Text(verbatim: texts.text("step_up.sending"))
            }
            CouliButton(
                texts.text("step_up.submit"), isLoading: state.showsVerifying,
                isEnabled: state.canVerify, fillsWidth: true, action: actions.verify
            )
        }
        .padding(CouliSpacing.s4)
    }
}
""",
    REAL_NAME: """
        return RealNameActions(
            recheck: { [weak controller] in controller?.recheckIdentity() }
        )
    public var body: some View {
        WalletPageScaffold(title: title) {
            ScrollView {}
        } bottom: {
            VStack(spacing: CouliSpacing.s2) {
                if snapshot.showsRecheck {
                    CouliButton(texts.text("wallet.retry"), action: actions.recheck)
                }
                CouliButton(texts.text("realname.submit"), isLoading: snapshot.showsSubmitting,
                            isEnabled: controller.submitEnabled, fillsWidth: true, action: actions.submit)
                    .accessibilityIdentifier("realname.submit")
            }
            .padding(CouliSpacing.s4)
            .frame(maxWidth: WalletLayout.maxContentWidth)
            .background {
                CouliColor.backgroundSurface.ignoresSafeArea(edges: .bottom)
            }
            .accessibilityElement(children: .contain)
        }
    }
""",
    LABOR: """
        return LaborActions(
            recheck: { [weak controller] in controller?.recheckIdentity() }
        )
    public var body: some View {
        WalletPageScaffold(title: title) {
            ScrollView {}
        } bottom: {
            VStack(spacing: CouliSpacing.s2) {
                if snapshot.showsRecheck {
                    CouliButton(texts.text("wallet.retry"), action: actions.recheck)
                }
                CouliButton(texts.text("labor.sign"), isLoading: snapshot.showsSigning,
                            isEnabled: controller.signEnabled, fillsWidth: true, action: actions.sign)
                    .accessibilityIdentifier("labor.sign")
            }
            .padding(CouliSpacing.s4)
            .background(
                CouliColor.backgroundSurface
                    .ignoresSafeArea(edges: .bottom)
            )
            .frame(maxWidth: .infinity)
        }
    }
""",
    RISK: """
    public var body: some View {
        let state = controller.state
        let showBack = controller.showsBack
        Group {
            Text("x")
        }
        .navigationBarBackButtonHidden(!showBack || state.logoutDialog != nil)
        .accessibilityIdentifier("risk.page")
    }
""",
}

RETRY_RN = '                if snapshot.showsRecheck {\n                    CouliButton(texts.text("wallet.retry"), action: actions.recheck)\n                }\n'
RETRY_STEP = ('            if state.showsRecheck {\n                CouliButton(texts.text("wallet.retry"), kind: .text, action: actions.recheck)\n'
              '                    .accessibilityIdentifier("stepUp.recheck")\n            }\n')

# (类别：样例名, 文件, 旧片段, 新片段)
BAD = [
    ("未接入属性：面板仍按 phase 显示发送中", STEP_UP, "if state.showsSending {", "if state.phase == .sending {"),
    ("未接入属性：验证按钮仍按 phase 转圈", STEP_UP, "isLoading: state.showsVerifying", "isLoading: state.phase == .verifying"),
    ("未接入属性：实名仍按 submitting 转圈", REAL_NAME, "isLoading: snapshot.showsSubmitting", "isLoading: snapshot.submitting"),
    ("未接入属性：劳务仍按 signing 转圈", LABOR, "isLoading: snapshot.showsSigning", "isLoading: snapshot.signing"),
    ("未接入属性：返回仍按旧公式", RISK, "let showBack = controller.showsBack",
     "let showBack = model?.showBack ?? !controller.enteredBy10006"),
    ("按钮缺失：面板没有【重试】", STEP_UP, RETRY_STEP, ""),
    ("按钮缺失：实名没有【重试】", REAL_NAME, RETRY_RN, ""),
    ("按钮缺失：劳务【重试】块里换成空视图", LABOR,
     '                    CouliButton(texts.text("wallet.retry"), action: actions.recheck)\n', "                    EmptyView()\n"),
    ("错误回调：面板【重试】接到重新获取", STEP_UP, "kind: .text, action: actions.recheck", "kind: .text, action: actions.resend"),
    ("错误回调：劳务【重试】接到签署", LABOR, 'texts.text("wallet.retry"), action: actions.recheck', 'texts.text("wallet.retry"), action: actions.sign'),
    ("错误回调：实名 Actions.recheck 转到提交", REAL_NAME, "controller?.recheckIdentity() }", "controller?.submit(owner: owner) }"),
    ("错误回调：面板 Actions.recheck 转到关闭", STEP_UP, "controller?.recheckIdentity(instance: instance) }",
     "controller?.close(instance: instance) }"),
    ("禁用：实名【重试】沿用提交可用条件", REAL_NAME, 'texts.text("wallet.retry"), action: actions.recheck',
     'texts.text("wallet.retry"), isEnabled: controller.submitEnabled, action: actions.recheck'),
    ("禁用：劳务【重试】沿用签署可用条件", LABOR, 'texts.text("wallet.retry"), action: actions.recheck',
     'texts.text("wallet.retry"), isEnabled: controller.signEnabled, action: actions.recheck'),
    ("禁用：面板【重试】块内 .disabled", STEP_UP, '                    .accessibilityIdentifier("stepUp.recheck")\n',
     '                    .disabled(state.phase != .ready)\n'),
    ("禁用：实名底部容器整体禁用", REAL_NAME, "            .padding(CouliSpacing.s4)\n",
     "            .padding(CouliSpacing.s4)\n            .disabled(snapshot.submitting)\n"),
    ("禁用：劳务【重试】被隐藏", LABOR, '                    CouliButton(texts.text("wallet.retry"), action: actions.recheck)\n',
     '                    CouliButton(texts.text("wallet.retry"), action: actions.recheck)\n                        .hidden()\n'),
    ("死分支：实名【重试】块外套 if false", REAL_NAME, RETRY_RN,
     "                if false {\n" + "\n".join("    " + l if l else l for l in RETRY_RN.split("\n")) + "                }\n"),
    ("死分支：面板【重试】条件追加 && false", STEP_UP, "if state.showsRecheck {", "if state.showsRecheck && false {"),
    ("死分支：劳务【重试】放进别的容器（与主按钮不同层）", LABOR,
     '                if snapshot.showsRecheck {\n                    CouliButton(texts.text("wallet.retry"), action: actions.recheck)\n                }\n',
     '                VStack {\n                    if snapshot.showsRecheck {\n                        CouliButton(texts.text("wallet.retry"), action: actions.recheck)\n'
     '                    }\n                }\n'),
    ("条件覆盖：实名【重试】块放进提交中分支", REAL_NAME, RETRY_RN,
     "                if !snapshot.submitting {\n" + "\n".join("    " + l if l else l for l in RETRY_RN.split("\n")) + "                }\n"),
    ("条件覆盖：返回隐藏条件追加 || true", RISK, "!showBack || state.logoutDialog != nil)", "!showBack || state.logoutDialog != nil || true)"),
    ("条件覆盖：返回按钮另写一处写死隐藏", RISK, '        .accessibilityIdentifier("risk.page")\n',
     '        .accessibilityIdentifier("risk.page")\n        .navigationBarBackButtonHidden(true)\n'),
    ("条件覆盖：返回变量被改写", RISK, "        Group {\n", "        let shown = showBack && false\n        Group {\n"),
    ("禁用（评审完整页面反例）：实名底部容器 .background { } 之后接 .disabled(snapshot.submitting)", REAL_NAME,
     "            .accessibilityElement(children: .contain)\n",
     "            .accessibilityElement(children: .contain)\n            .disabled(snapshot.submitting)\n"),
    ("禁用（评审完整页面反例）：劳务底部容器 .background( ) 多行参数之后接 .disabled(snapshot.signing)", LABOR,
     "            .frame(maxWidth: .infinity)\n        }\n",
     "            .frame(maxWidth: .infinity)\n            .disabled(snapshot.signing)\n        }\n"),
    ("禁用：闭包修饰符之后隐藏", REAL_NAME, "            .accessibilityElement(children: .contain)\n",
     "            .accessibilityElement(children: .contain)\n            .opacity(0)\n"),
    ("条件拼接（评审反例）：实名转圈追加 || snapshot.submitting", REAL_NAME, "isLoading: snapshot.showsSubmitting,",
     "isLoading: snapshot.showsSubmitting || snapshot.submitting,"),
    ("条件拼接（评审反例）：劳务转圈追加 || snapshot.signing", LABOR, "isLoading: snapshot.showsSigning,",
     "isLoading: snapshot.showsSigning || snapshot.signing,"),
    ("条件拼接（评审反例）：面板转圈追加 || state.phase == .verifying", STEP_UP, "isLoading: state.showsVerifying,",
     "isLoading: state.showsVerifying || state.phase == .verifying,"),
    ("条件拼接：实名转圈用三元覆盖", REAL_NAME, "isLoading: snapshot.showsSubmitting,",
     "isLoading: snapshot.showsSubmitting ? true : snapshot.submitting,"),
    ("后续覆盖：实名转圈写死", REAL_NAME, "action: actions.submit)",
     'action: actions.submit)\n                    .overlay(CouliButton(texts.text("x"), isLoading: true, action: {}))'),
    ("后续覆盖：展示属性被页面重新赋值", LABOR, "                if snapshot.showsRecheck {",
     "                var shown = snapshot; shown.showsRecheck = false\n                if snapshot.showsRecheck {"),
]


def self_test() -> int:
    failures = []
    for rel, good in GOOD.items():
        errors = check_text(rel, good)
        if errors:
            failures.append(f"合规样例被误拦（{RULES[rel][0]}）：{errors}")
    for case, rel, old, new in BAD:
        good = GOOD[rel]
        if old not in good:
            failures.append(f"样例构造失败（{case}）：找不到旧片段")
            continue
        if not check_text(rel, good.replace(old, new, 1)):
            failures.append(f"漏接样例没有被拦：{case}")
    for line in failures:
        print(line)
    print(f"自测：合规 {len(GOOD)} 例、漏接 {len(BAD)} 例；失败 {len(failures)}")
    return 1 if failures else 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        return self_test()
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
    return check_repo(root)


if __name__ == "__main__":
    sys.exit(main())
