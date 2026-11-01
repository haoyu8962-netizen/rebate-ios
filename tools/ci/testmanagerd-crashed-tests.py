#!/usr/bin/env python3
"""从 xcresulttool 摘要（stdin）列出被 testmanagerd 崩溃打断的用例，一行一个 Target/Class/test。

只有全部失败都是「Lost connection to testmanagerd」时才输出：混了别的失败就输出空，由调用方按红处理。
--selftest 跑内置用例。
"""
import json
import sys

CRASH_TEXT = "Lost connection to testmanagerd"


def crashed_tests(summary):
    failures = summary.get("testFailures") or []
    if not failures or any(f.get("failureText") != CRASH_TEXT for f in failures):
        return []
    tests = sorted({f["targetName"] + "/" + f["testIdentifierString"].removesuffix("()") for f in failures})
    return tests if len(tests) == summary.get("failedTests") else []


def selftest():
    crash = {"failureText": CRASH_TEXT, "targetName": "CouliUITests", "testIdentifierString": "A/testB()"}
    other = {"failureText": "XCTAssertTrue failed", "targetName": "CouliUITests", "testIdentifierString": "A/testC()"}
    cases = [
        ({"failedTests": 1, "testFailures": [crash]}, ["CouliUITests/A/testB"]),
        ({"failedTests": 2, "testFailures": [crash, other]}, []),
        ({"failedTests": 2, "testFailures": [crash]}, []),
        ({"failedTests": 0, "testFailures": []}, []),
        ({}, []),
    ]
    for given, expected in cases:
        actual = crashed_tests(given)
        if actual != expected:
            sys.exit(f"selftest failed: {given} -> {actual}")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        selftest()
    else:
        print("\n".join(crashed_tests(json.load(sys.stdin))))
