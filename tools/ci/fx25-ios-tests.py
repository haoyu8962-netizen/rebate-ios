#!/usr/bin/env python3
"""F-X-25 测试设施；不改源码、不装依赖、不运行 git。核心接口未实现时 --core-typecheck 应红。"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DEV = Path('/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer')
CORE_TEST = ROOT / 'Packages/Core/Tests/BridgeHostTests/FX25AuthChangeDecisionTests.swift'
APP_TESTS = sorted((ROOT / 'AppTests/FX25').glob('*.swift'))


def run(command, **kwargs):
    result = subprocess.run(command, cwd=ROOT, **kwargs)
    print(f'EXIT={result.returncode}: {command[0]}', flush=True)
    return result.returncode


def checks(vectors):
    source = vectors.read_text()
    block = re.search(r'```json\n(.*?)\n```', source, re.S)
    assert block, '共享 JSON 围栏缺失'
    copied = (ROOT / 'specs/fx25-auth-change-vectors.json').read_text()
    assert copied == block[1] + '\n', '必须逐字复制共享样例'
    assert len(json.loads(copied)['cases']) == 10
    schema = json.loads((ROOT / 'contracts/snapshot/contracts/bridge.schema.json').read_text())
    event = schema['events']['auth.changed']
    assert event['required'] == ['logged_in']
    assert event['properties'] == {'logged_in': {'type': 'boolean'}}
    assert event['additionalProperties'] is False
    print('共享样例逐字一致；auth.changed 契约核对一致', flush=True)
    for command in [
        ['swiftformat', '--lint', '.', '--cache', 'ignore'],
        ['swiftlint', 'lint', '--strict', '--no-cache'],
        ['xcrun', 'swiftc', '-frontend', '-parse', *map(str, APP_TESTS), str(CORE_TEST)],
        ['python3', 'tools/codegen/gen.py', '--check'],
    ]:
        if run(command):
            return 1
    journal = (ROOT / 'AppTests/FX25/FX25WebJournal.swift').read_text()
    for name in ('source', 'seed'):
        script = re.search(r'static let ' + name + r' = """\n(.*?)\n    """', journal, re.S)
        assert script, name
        parser = "new Function('return (async function(){'+require('fs').readFileSync(0,'utf8')+'\\n})');"
        if run(['node', '-e', parser], input=script[1], text=True):
            return 1
    tests = sum(len(re.findall(r'func test\w+\(', p.read_text())) for p in [*APP_TESTS, CORE_TEST])
    print(f'离线检查通过；发现 {tests} 个 XCTest 方法（不是已运行用例数）', flush=True)
    return 0


def core_typecheck():
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='fx25-core-') as temporary:
        out = Path(temporary)
        base = ['xcrun', 'swiftc', '-swift-version', '6', '-target', 'arm64-apple-ios16.0-simulator',
                '-sdk', sdk, '-module-cache-path', str(out / 'cache'), '-I', str(out),
                '-I', str(DEV / 'usr/lib'), '-F', str(DEV / 'Library/Frameworks')]
        for name, folder in [('Generated', 'Packages/Generated/Sources/Generated'),
                             ('BridgeHost', 'Packages/Core/Sources/BridgeHost')]:
            # 只排除桥完全不用的 DefaultTexts；它依赖 SPM 生成的 Bundle.module。
            # 其余均为当前工作树原生产源码；不加接口声明、替身或判定垫片。
            files = [str(p) for p in sorted((ROOT / folder).glob('*.swift')) if p.name != 'DefaultTexts.swift']
            command = base + ['-emit-module', '-parse-as-library', '-enable-testing', '-module-name', name,
                              '-emit-module-path', str(out / (name + '.swiftmodule')), *files]
            if run(command):
                return 1
        return run(base + ['-typecheck', str(CORE_TEST)])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core-typecheck', action='store_true')
    parser.add_argument('--vectors', type=Path, default=ROOT.parents[2] / 'NATIVE/F-X-25/vectors.md')
    options = parser.parse_args()
    raise SystemExit(core_typecheck() if options.core_typecheck else checks(options.vectors))
