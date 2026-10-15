import Foundation

/// The same bounded JSON expression language as the server. No JavaScript runs on the device.
public enum MiniAppExpression {
    private static let forbidden: Set<String> = ["__proto__", "prototype", "constructor"]

    public static func read(_ root: JSONValue, path: String) -> JSONValue {
        var current = root
        for key in path.split(separator: ".").map(String.init) {
            guard !forbidden.contains(key) else { return .null }
            if case .array(let values) = current, let index = Int(key), values.indices.contains(index) { current = values[index] }
            else { current = current[key] ?? .null }
        }
        return current
    }

    public static func write(_ state: inout [String: JSONValue], path: String, value: JSONValue) {
        let keys = path.split(separator: ".").map(String.init)
        guard !keys.isEmpty, keys.allSatisfy({ !forbidden.contains($0) }) else { return }
        put(&state, keys: keys[...], value: value)
    }

    private static func put(_ state: inout [String: JSONValue], keys: ArraySlice<String>, value: JSONValue) {
        guard let key = keys.first else { return }
        if keys.count == 1 { state[key] = value }
        else {
            var child = state[key]?.miniObject ?? [:]
            put(&child, keys: keys.dropFirst(), value: value)
            state[key] = .object(child)
        }
    }

    public static func evaluate(_ value: JSONValue, context: [String: JSONValue], depth: Int = 0) -> JSONValue {
        guard depth < 24 else { return .null }
        switch value {
        case .array(let values): return .array(values.map { evaluate($0, context: context, depth: depth + 1) })
        case .object(let object):
            if let path = object["get"]?.stringValue, object.count == 1 { return read(.object(context), path: path) }
            if let op = object["op"]?.stringValue, let args = object["args"] {
                return operation(op, args: args.miniArray.map { evaluate($0, context: context, depth: depth + 1) })
            }
            return .object(object.filter { !forbidden.contains($0.key) }.mapValues { evaluate($0, context: context, depth: depth + 1) })
        default: return value
        }
    }

    private static func operation(_ op: String, args: [JSONValue]) -> JSONValue {
        let first = args.first ?? .null
        let second = args.count > 1 ? args[1] : .null
        func number(_ value: JSONValue) -> Double { if case .number(let n) = value { n } else { 0 } }
        switch op {
        case "eq": return .bool(first == second)
        case "ne": return .bool(first != second)
        case "gt": return .bool(number(first) > number(second))
        case "gte": return .bool(number(first) >= number(second))
        case "lt": return .bool(number(first) < number(second))
        case "lte": return .bool(number(first) <= number(second))
        case "and": return .bool(args.allSatisfy(\.miniTruth))
        case "or": return .bool(args.contains(where: \.miniTruth))
        case "not": return .bool(!first.miniTruth)
        case "add": return .number(args.reduce(0) { $0 + number($1) })
        case "sub": return .number(number(first) - number(second))
        case "mul": return .number(args.reduce(1) { $0 * number($1) })
        case "div": return number(second) == 0 ? .null : .number(number(first) / number(second))
        case "concat": return .string(args.map(\.miniText).joined())
        case "length": return .number(Double(first.stringValue?.utf16.count ?? first.miniArray.count))
        case "coalesce": return args.first(where: { $0 != .null }) ?? .null
        case "contains": return .bool(first.stringValue?.contains(second.miniText) ?? first.miniArray.contains(second))
        default: return .null
        }
    }
}
