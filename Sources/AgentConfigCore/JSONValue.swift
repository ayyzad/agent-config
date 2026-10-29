import Foundation

public struct JSONMember: Equatable, Sendable {
    public var key: String
    public var value: JSONValue

    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }
}

/// A JSON value that keeps key order and the exact text of numbers, so a file
/// can be read, changed in one place and written back with nothing else moved.
public indirect enum JSONValue: Equatable, Sendable {
    case object([JSONMember])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    public var keys: [String] {
        guard case .object(let members) = self else { return [] }
        return members.map(\.key)
    }

    /// Replaces the member in place, or inserts it at `index` (default: the end).
    public mutating func set(_ key: String, _ value: JSONValue, insertAt index: Int? = nil) {
        guard case .object(var members) = self else { return }
        if let i = members.firstIndex(where: { $0.key == key }) {
            members[i].value = value
        } else {
            let at = min(max(index ?? members.count, 0), members.count)
            members.insert(JSONMember(key: key, value: value), at: at)
        }
        self = .object(members)
    }

    public mutating func remove(_ key: String) {
        guard case .object(var members) = self else { return }
        members.removeAll { $0.key == key }
        self = .object(members)
    }
}

public struct JSONParseError: Error, CustomStringConvertible, LocalizedError, Sendable {
    public let message: String
    public let line: Int
    public let column: Int

    public var description: String { "\(message) (line \(line), column \(column))" }
    public var errorDescription: String? { "This file isn't valid JSON: \(description)." }
}

public enum JSON {
    public static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(bytes: Array(text.utf8))
        return try parser.document()
    }

    /// Same layout as JavaScript's `JSON.stringify(value, null, 2)`, which is
    /// how Claude Code writes its settings files.
    public static func serialize(_ value: JSONValue) -> String {
        var out = ""
        write(value, depth: 0, into: &out)
        return out
    }

    private static func write(_ value: JSONValue, depth: Int, into out: inout String) {
        switch value {
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{\n"
            for (i, member) in members.enumerated() {
                out += indent(depth + 1) + quote(member.key) + ": "
                write(member.value, depth: depth + 1, into: &out)
                out += i < members.count - 1 ? ",\n" : "\n"
            }
            out += indent(depth) + "}"
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += indent(depth + 1)
                write(item, depth: depth + 1, into: &out)
                out += i < items.count - 1 ? ",\n" : "\n"
            }
            out += indent(depth) + "]"
        case .string(let s):
            out += quote(s)
        case .number(let raw):
            out += raw
        case .bool(let b):
            out += b ? "true" : "false"
        case .null:
            out += "null"
        }
    }

    private static func indent(_ depth: Int) -> String {
        String(repeating: "  ", count: depth)
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

private struct Parser {
    let bytes: [UInt8]
    var i = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
    }

    var current: UInt8? { i < bytes.count ? bytes[i] : nil }

    mutating func document() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard i == bytes.count else { throw error("Unexpected text after the end of the JSON") }
        return value
    }

    func error(_ message: String) -> JSONParseError {
        var line = 1, column = 1
        for b in bytes[..<min(i, bytes.count)] {
            if b == 0x0A {
                line += 1
                column = 1
            } else if b & 0xC0 != 0x80 {
                column += 1
            }
        }
        return JSONParseError(message: message, line: line, column: column)
    }

    mutating func skipWhitespace() {
        while let c = current, c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1 }
    }

    mutating func expect(_ c: UInt8, _ what: String) throws {
        guard current == c else { throw error("Expected \(what)") }
        i += 1
    }

    mutating func parseValue() throws -> JSONValue {
        guard let c = current else { throw error("Unexpected end of file") }
        switch c {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw error("Unexpected character")
        }
    }

    mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else {
            throw error("Expected \(word)")
        }
        i += w.count
    }

    mutating func parseObject() throws -> JSONValue {
        i += 1
        var members: [JSONMember] = []
        skipWhitespace()
        if current == UInt8(ascii: "}") { i += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\"") else { throw error("Expected a quoted key") }
            let key = try parseString()
            skipWhitespace()
            try expect(UInt8(ascii: ":"), "':'")
            skipWhitespace()
            members.append(JSONMember(key: key, value: try parseValue()))
            skipWhitespace()
            if current == UInt8(ascii: ",") { i += 1; continue }
            try expect(UInt8(ascii: "}"), "',' or '}'")
            return .object(members)
        }
    }

    mutating func parseArray() throws -> JSONValue {
        i += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if current == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            if current == UInt8(ascii: ",") { i += 1; continue }
            try expect(UInt8(ascii: "]"), "',' or ']'")
            return .array(items)
        }
    }

    func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    mutating func parseNumber() throws -> String {
        let start = i
        if current == UInt8(ascii: "-") { i += 1 }
        guard let first = current, isDigit(first) else { throw error("Invalid number") }
        if first == UInt8(ascii: "0") {
            i += 1
        } else {
            while let c = current, isDigit(c) { i += 1 }
        }
        if current == UInt8(ascii: ".") {
            i += 1
            guard let c = current, isDigit(c) else { throw error("Invalid number") }
            while let c = current, isDigit(c) { i += 1 }
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            i += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { i += 1 }
            guard let c = current, isDigit(c) else { throw error("Invalid number") }
            while let c = current, isDigit(c) { i += 1 }
        }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    mutating func parseString() throws -> String {
        i += 1
        var result = ""
        var chunkStart = i
        while true {
            guard let c = current else { throw error("Unterminated string") }
            if c == UInt8(ascii: "\"") {
                result += String(decoding: bytes[chunkStart..<i], as: UTF8.self)
                i += 1
                return result
            }
            if c == UInt8(ascii: "\\") {
                result += String(decoding: bytes[chunkStart..<i], as: UTF8.self)
                i += 1
                guard let e = current else { throw error("Unterminated string") }
                i += 1
                switch e {
                case UInt8(ascii: "\""): result += "\""
                case UInt8(ascii: "\\"): result += "\\"
                case UInt8(ascii: "/"): result += "/"
                case UInt8(ascii: "b"): result += "\u{08}"
                case UInt8(ascii: "f"): result += "\u{0C}"
                case UInt8(ascii: "n"): result += "\n"
                case UInt8(ascii: "r"): result += "\r"
                case UInt8(ascii: "t"): result += "\t"
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), current == UInt8(ascii: "\\"),
                       i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "u") {
                        let saved = i
                        i += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            i = saved
                        }
                    }
                    result.unicodeScalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default:
                    throw error("Invalid escape")
                }
                chunkStart = i
                continue
            }
            if c < 0x20 { throw error("Control character in string") }
            i += 1
        }
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count else { throw error("Invalid \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[i]
            let digit: UInt32
            switch c {
            case 0x30...0x39: digit = UInt32(c - 0x30)
            case 0x41...0x46: digit = UInt32(c - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(c - 0x61 + 10)
            default: throw error("Invalid \\u escape")
            }
            value = value << 4 | digit
            i += 1
        }
        return value
    }
}
