import Foundation

/// Safe arithmetic expression evaluator (recursive descent). Supports
/// `+ - * / % ^`, parentheses, unary minus, constants (`pi`, `e`) and common
/// math functions (`sqrt sin cos tan ln log log2 abs floor ceil round min max`).
/// Returns nil for anything that isn't a well-formed numeric expression, so
/// arbitrary user input can be probed safely.
enum Calculator {
    static func evaluate(_ query: String) -> Double? {
        let input = query.trimmingCharacters(in: .whitespaces)
        guard input.count >= 3 else { return nil }
        var parser = Parser(tokens: tokenize(input))
        guard let value = parser.parseExpression(), parser.atEnd else { return nil }
        return value.isFinite ? value : nil
    }

    static func format(_ value: Double) -> String {
        if value.rounded() == value && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        var out = String(format: "%.10f", value)
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }

    // MARK: - tokenizer

    private enum Token {
        case number(Double)
        case op(Character)
        case name(String)
        case lparen, rparen
    }

    private static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || c == "." {
                var num = ""
                while i < chars.count && (chars[i].isNumber || chars[i] == ".") {
                    num.append(chars[i]); i += 1
                }
                tokens.append(.number(Double(num) ?? .nan))
                continue
            }
            if c.isLetter {
                var name = ""
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber) {
                    name.append(chars[i]); i += 1
                }
                tokens.append(.name(name.lowercased()))
                continue
            }
            switch c {
            case "+", "-", "*", "/", "%", "^":
                tokens.append(.op(c)); i += 1
            case "(": tokens.append(.lparen); i += 1
            case ")": tokens.append(.rparen); i += 1
            default: return [] // unknown character invalidates the whole input
            }
        }
        return tokens
    }

    // MARK: - parser
    // expression := term (('+'|'-') term)*
    // term       := power (('*'|'/'|'%') power)*
    // power      := unary ('^' power)?
    // unary      := ('-')? primary
    // primary    := number | name | name '(' expression (',' expression)* | '(' expression ')'

    private struct Parser {
        let tokens: [Token]
        var pos = 0

        var atEnd: Bool { pos >= tokens.count }

        mutating func parseExpression() -> Double? {
            guard var lhs = parseTerm() else { return nil }
            while !atEnd, case .op(let op) = tokens[pos], op == "+" || op == "-" {
                pos += 1
                guard let rhs = parseTerm() else { return nil }
                lhs = op == "+" ? lhs + rhs : lhs - rhs
            }
            return lhs
        }

        private mutating func parseTerm() -> Double? {
            guard var lhs = parsePower() else { return nil }
            while !atEnd, case .op(let op) = tokens[pos], op == "*" || op == "/" || op == "%" {
                pos += 1
                guard let rhs = parsePower() else { return nil }
                switch op {
                case "*": lhs = lhs * rhs
                case "/": lhs = rhs == 0 ? .infinity : lhs / rhs
                default: lhs = rhs == 0 ? .infinity : lhs.truncatingRemainder(dividingBy: rhs)
                }
            }
            return lhs
        }

        private mutating func parsePower() -> Double? {
            guard let base = parseUnary() else { return nil }
            if !atEnd, case .op(let op) = tokens[pos], op == "^" {
                pos += 1
                guard let exponent = parsePower() else { return nil } // right-assoc
                return Darwin.pow(base, exponent)
            }
            return base
        }

        private mutating func parseUnary() -> Double? {
            if !atEnd, case .op(let op) = tokens[pos], op == "-" {
                pos += 1
                guard let value = parseUnary() else { return nil }
                return -value
            }
            if !atEnd, case .op(let op) = tokens[pos], op == "+" {
                pos += 1
                return parseUnary()
            }
            return parsePrimary()
        }

        private mutating func parsePrimary() -> Double? {
            guard !atEnd else { return nil }
            switch tokens[pos] {
            case .number(let n):
                pos += 1
                return n
            case .name(let name):
                pos += 1
                if name == "pi" { return .pi }
                if name == "e" { return M_E }
                // function call?
                if !atEnd, case .lparen = tokens[pos] {
                    pos += 1
                    guard let arg = parseExpression() else { return nil }
                    var extra: Double? = nil
                    if !atEnd, case .op(let op) = tokens[pos], op == "," {
                        pos += 1
                        extra = parseExpression()
                        guard extra != nil else { return nil }
                    }
                    guard !atEnd, case .rparen = tokens[pos] else { return nil }
                    pos += 1
                    return applyFunction(name, arg, extra)
                }
                return nil
            case .lparen:
                pos += 1
                guard let value = parseExpression() else { return nil }
                guard !atEnd, case .rparen = tokens[pos] else { return nil }
                pos += 1
                return value
            case .op, .rparen:
                return nil
            }
        }

        private func applyFunction(_ name: String, _ a: Double, _ b: Double?) -> Double? {
            switch name {
            case "sqrt": return sqrt(a)
            case "sin": return sin(a)
            case "cos": return cos(a)
            case "tan": return tan(a)
            case "asin": return asin(a)
            case "acos": return acos(a)
            case "atan": return atan(a)
            case "ln": return log(a)
            case "log": return log10(a)
            case "log2": return log2(a)
            case "exp": return exp(a)
            case "abs": return abs(a)
            case "floor": return floor(a)
            case "ceil": return ceil(a)
            case "round": return round(a)
            case "min": return b.map { min(a, $0) } ?? a
            case "max": return b.map { max(a, $0) } ?? a
            case "pow": return b.map { pow(a, $0) }
            default: return nil
            }
        }
    }
}
