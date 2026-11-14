import Foundation
import XCTest

/// LOCK-ios（编排 D10-1716 ③）源码守卫：`readSessionLocked()` 可能发现损坏条目、在锁里记下待发的 `.cleared`，只有经
/// `withSessionLock` 取锁的地方会在出锁后发出。所以 CouliNetwork 源码里凡是 `lock.withLock {` 的闭包体都不得直接调用
/// `readSessionLocked(`，也不得调用「（传递地）会调用它的 *Locked 函数」（按函数名 + 实参个数区分重载，例如 Prepare 的两参
/// `admitLocked(state, options)` 与 Refresh 的四参 `admitLocked`）。文本扫描：先把注释与字符串字面量抹成空白，再做括号配对。
/// 已知局限：只认 `lock.withLock {` 尾随闭包写法与具名调用；经闭包参数间接调用（如 `awaitRefresh` 的 `admit`）看不到。
final class LockIosSessionLockSourceGuardTests: XCTestCase {
    /// 4a. 任何 `lock.withLock {` 闭包体里都不直接或经 *Locked 函数间接调用 `readSessionLocked(`。
    func testPlainLockBodiesNeverReadSessionLocked() throws {
        let files = try Self.sourceFiles()
        XCTAssertGreaterThan(files.count, 20, "前提：读到了 CouliNetwork 的源文件")
        let readers = LockSourceScan.readers(in: files)
        let names = Set(readers.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["readSessionLocked", "admitLocked", "barrierAdmitLocked"]), "\(names)")
        XCTAssertTrue(readers.contains { $0.name == "admitLocked" && $0.total == 4 }, "Refresh 的四参 admitLocked 读会话")
        XCTAssertFalse(readers.contains { $0.name == "admitLocked" && $0.total == 2 }, "Prepare 的两参 admitLocked 不读会话")

        let bodies = files.reduce(0) { $0 + LockSourceScan.closureBodies(of: "lock.withLock", in: $1).count }
        XCTAssertGreaterThan(bodies, 20, "前提：扫到了 lock.withLock 闭包（扫描没有失效）")
        let violations = files.flatMap { LockSourceScan.plainLockViolations(in: $0, readers: readers) }
        XCTAssertEqual(violations, [], "lock.withLock 闭包里读会话：出锁后不会发出待发的 .cleared，应改用 withSessionLock")
    }

    /// 4b. 每一处 `readSessionLocked(` 调用都在 `withSessionLock {` 闭包里，或在调用方已持锁的 *Locked 函数体里。
    func testEveryReadSessionLockedCallIsInSessionLockOrLockedFunction() throws {
        let files = try Self.sourceFiles()
        var calls = 0
        var stray: [String] = []
        for file in files {
            let allowed = LockSourceScan.closureBodies(of: "withSessionLock", in: file)
                + LockSourceScan.definitions(in: file).filter { $0.name.hasSuffix("Locked") }.map(\.body)
            let all = LockSourceScan.calls(in: file, range: 0..<file.code.count)
            for call in all where call.name == "readSessionLocked" {
                calls += 1
                if !allowed.contains(where: { $0.contains(call.offset) }) {
                    stray.append("\(file.name):\(file.line(call.offset))")
                }
            }
        }
        XCTAssertGreaterThan(calls, 10, "前提：扫到了 readSessionLocked 调用")
        XCTAssertEqual(stray, [], "readSessionLocked 调用不在 withSessionLock / *Locked 函数里")
    }

    /// 4c. 扫描器自检：合成源码里直接调用、经 *Locked 间接调用都能被抓到；注释、字符串、withSessionLock 里的不算。
    func testScannerFlagsSyntheticViolations() {
        let text = """
        func a() { lock.withLock { _ = readSessionLocked() } }
        func b() { lock.withLock { _ = helperLocked(1) } }
        func helperLocked(_ value: Int) -> Int { _ = innerLocked(); return value }
        func innerLocked() -> Int { readSessionLocked() == .none ? 0 : 1 }
        func c() { let text = "lock.withLock { readSessionLocked() }"; withSessionLock { _ = readSessionLocked() } }
        // lock.withLock { readSessionLocked() }
        func d() { lock.withLock { _ = helperLocked() } }
        func e() { lock.withLock { generation } }
        """
        let file = ScannedSource(name: "Synthetic.swift", text: text)
        let readers = LockSourceScan.readers(in: [file])
        XCTAssertEqual(Set(readers.map(\.name)), ["readSessionLocked", "helperLocked", "innerLocked"])
        XCTAssertEqual(
            LockSourceScan.plainLockViolations(in: file, readers: readers),
            ["Synthetic.swift:1 readSessionLocked", "Synthetic.swift:2 helperLocked"],
            "d() 的 helperLocked() 实参个数对不上任何读会话的定义，不算"
        )
    }

    private static func sourceFiles() throws -> [ScannedSource] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NetworkTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Core
            .appendingPathComponent("Sources/CouliNetwork")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map { name in
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            return ScannedSource(name: name, text: text)
        }
    }
}

/// 一个源文件：注释与字符串字面量已抹成空格（换行保留，行号不变）。
struct ScannedSource {
    let name: String
    let code: [UInt8]

    init(name: String, text: String) {
        self.name = name
        code = Self.blank(Array(text.utf8))
    }

    func line(_ offset: Int) -> Int {
        code[..<offset].reduce(1) { $1 == 10 ? $0 + 1 : $0 }
    }

    private static func blank(_ input: [UInt8]) -> [UInt8] {
        var out = input
        var index = 0
        func wipe(_ from: Int, _ upTo: Int) {
            for position in from..<min(upTo, out.count) where out[position] != 10 {
                out[position] = 32
            }
        }
        func at(_ offset: Int, _ text: String) -> Bool {
            let bytes = Array(text.utf8)
            return offset + bytes.count <= input.count && Array(input[offset..<offset + bytes.count]) == bytes
        }
        while index < input.count {
            let start = index
            if at(index, "//") {
                while index < input.count, input[index] != 10 {
                    index += 1
                }
            } else if at(index, "/*") {
                index += 2
                while index < input.count, !at(index, "*/") {
                    index += 1
                }
                index += 2
            } else if at(index, "\"") {
                let delimiter = at(index, "\"\"\"") ? "\"\"\"" : "\""
                index += delimiter.count
                while index < input.count, !at(index, delimiter) {
                    index += input[index] == UInt8(ascii: "\\") ? 2 : 1
                }
                index += delimiter.count
            } else {
                index += 1
                continue
            }
            wipe(start, index)
        }
        return out
    }
}

/// 括号配对的小扫描器（只看抹掉注释、字符串之后的代码）。
enum LockSourceScan {
    struct Definition {
        let name: String
        let required: Int
        let total: Int
        let body: Range<Int>
    }

    struct Call {
        let name: String
        let args: Int
        let offset: Int
    }

    /// 读会话的 *Locked 函数（名 + 形参个数范围）：`readSessionLocked` 本身，加上函数体里（传递地）调用了它们的 *Locked 定义。
    static func readers(in files: [ScannedSource]) -> [Definition] {
        let all = files.flatMap { file in
            definitions(in: file).filter { $0.name.hasSuffix("Locked") }.map { (file, $0) }
        }
        var found = [Definition(name: "readSessionLocked", required: 0, total: 0, body: 0..<0)]
        var changed = true
        while changed {
            changed = false
            for (file, definition) in all where !found.contains(where: { same($0, definition) }) {
                if calls(in: file, range: definition.body).contains(where: { call in matches(call, found) }) {
                    found.append(definition)
                    changed = true
                }
            }
        }
        return found
    }

    /// `lock.withLock {` 闭包体里对读会话函数的调用（「文件:行 函数名」）。
    static func plainLockViolations(in file: ScannedSource, readers: [Definition]) -> [String] {
        closureBodies(of: "lock.withLock", in: file).flatMap { body in
            calls(in: file, range: body).filter { matches($0, readers) }.map {
                "\(file.name):\(file.line($0.offset)) \($0.name)"
            }
        }
    }

    /// `token {`（或 `token({`）尾随闭包的闭包体范围。
    static func closureBodies(of token: String, in file: ScannedSource) -> [Range<Int>] {
        let code = file.code
        return occurrences(of: token, in: code).compactMap { offset -> Range<Int>? in
            guard !precededByFunc(code, offset) else { return nil }
            var index = skipSpaces(code, offset + token.utf8.count)
            if index < code.count, code[index] == UInt8(ascii: "(") {
                index = skipSpaces(code, index + 1)
            }
            guard index < code.count, code[index] == UInt8(ascii: "{"), let close = matching(code, index) else {
                return nil
            }
            return index..<close
        }
    }

    /// 函数定义：名字、形参个数（必填 / 全部）、函数体范围。
    static func definitions(in file: ScannedSource) -> [Definition] {
        let code = file.code
        return occurrences(of: "func", in: code).compactMap { offset -> Definition? in
            var index = skipSpaces(code, offset + 4)
            let nameStart = index
            while index < code.count, isIdentifier(code[index]) {
                index += 1
            }
            let name = text(code[nameStart..<index])
            if index < code.count, code[index] == UInt8(ascii: "<") {
                while index < code.count, code[index] != UInt8(ascii: ">") {
                    index += 1
                }
                index += 1
            }
            guard !name.isEmpty, index < code.count, code[index] == UInt8(ascii: "("),
                  let close = matching(code, index),
                  let open = code[close...].firstIndex(of: UInt8(ascii: "{")), let end = matching(code, open)
            else { return nil }
            let parts = arguments(code, index, close, generics: true)
            let required = parts.filter { !$0.contains(UInt8(ascii: "=")) }.count
            return Definition(name: name, required: required, total: parts.count, body: open..<end)
        }
    }

    /// 范围内对 *Locked 函数的具名调用（不含定义处）。
    static func calls(in file: ScannedSource, range: Range<Int>) -> [Call] {
        let code = file.code
        var result: [Call] = []
        var index = range.lowerBound
        while index < range.upperBound {
            guard isIdentifier(code[index]), index == 0 || !isIdentifier(code[index - 1]) else {
                index += 1
                continue
            }
            let start = index
            while index < range.upperBound, isIdentifier(code[index]) {
                index += 1
            }
            let name = text(code[start..<index])
            let open = skipSpaces(code, index)
            guard name.hasSuffix("Locked"), open < code.count, code[open] == UInt8(ascii: "("),
                  !precededByFunc(code, start), let close = matching(code, open)
            else { continue }
            result.append(Call(name: name, args: arguments(code, open, close).count, offset: start))
        }
        return result
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private static func same(_ lhs: Definition, _ rhs: Definition) -> Bool {
        lhs.name == rhs.name && lhs.total == rhs.total && lhs.body == rhs.body
    }

    private static func matches(_ call: Call, _ readers: [Definition]) -> Bool {
        readers.contains { $0.name == call.name && $0.required <= call.args && call.args <= $0.total }
    }

    /// `(` 到 `)` 之间按顶层逗号切开的各段（空括号为空数组）。`generics`：形参表里 `<A, B>` 的逗号不算（`->` 的 `>` 除外）；
    /// 调用处的实参可能有比较运算，不按尖括号配对。
    private static func arguments(_ code: [UInt8], _ open: Int, _ close: Int, generics: Bool = false) -> [[UInt8]] {
        var parts: [[UInt8]] = [[]]
        var depth = 0
        for index in (open + 1)..<close {
            let byte = code[index]
            let angle = generics && (byte == UInt8(ascii: "<")
                || (byte == UInt8(ascii: ">") && code[index - 1] != UInt8(ascii: "-")))
            switch byte {
            case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
            case UInt8(ascii: "<") where angle: depth += 1
            case UInt8(ascii: ">") where angle: depth -= 1
            case UInt8(ascii: ",") where depth == 0:
                parts.append([])
                continue
            default: break
            }
            parts[parts.count - 1].append(byte)
        }
        return parts.filter { $0.contains { $0 != 32 && $0 != 10 } }
    }

    private static func occurrences(of token: String, in code: [UInt8]) -> [Int] {
        let bytes = Array(token.utf8)
        guard code.count >= bytes.count else { return [] }
        return (0...(code.count - bytes.count)).filter { offset in
            code[offset] == bytes[0] && Array(code[offset..<offset + bytes.count]) == bytes
                && (offset == 0 || !isIdentifier(code[offset - 1]))
                && (offset + bytes.count == code.count || !isIdentifier(code[offset + bytes.count]))
        }
    }

    /// 与 `open` 处括号配对的右括号位置。
    private static func matching(_ code: [UInt8], _ open: Int) -> Int? {
        let opener = code[open]
        let closer = opener == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: ")")
        var depth = 0
        for index in open..<code.count {
            if code[index] == opener {
                depth += 1
            } else if code[index] == closer {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
        }
        return nil
    }

    private static func precededByFunc(_ code: [UInt8], _ offset: Int) -> Bool {
        var index = offset - 1
        while index >= 0, code[index] == 32 {
            index -= 1
        }
        return index >= 3 && Array(code[(index - 3)...index]) == Array("func".utf8)
            && (index == 3 || !isIdentifier(code[index - 4]))
    }

    private static func skipSpaces(_ code: [UInt8], _ offset: Int) -> Int {
        var index = offset
        while index < code.count, code[index] == 32 || code[index] == 10 {
            index += 1
        }
        return index
    }

    private static func isIdentifier(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "_") || byte >= 128 || (48...57).contains(byte)
            || (65...90).contains(byte) || (97...122).contains(byte)
    }
}
