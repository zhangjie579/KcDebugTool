import Foundation

/// 表达式语法（刻意受限，不做通用 Swift 语法）：
///
/// ```
/// 程序     := 表达式 (';' 表达式)* ';'?
/// 表达式   := 主体 ('.' 成员 [ '(' 实参 ')' ])* [ '=' 表达式 ]
/// 主体     := 标识符 | 标识符 '(' 实参 ')' | 字面量 | 数组/字典 | '(' 表达式 ')'
/// 实参     := (标识符 ':')? 表达式 (',' ...)*
/// ```
///
/// `Type.method()` 解析成 member(identifier(Type), method, isCall: true)，
/// `Type().method()` 解析成 member(construct(Type), method, isCall: true)，
/// 两者分别对应「类方法」与「实例方法」，求值器据此决定接收者。

/// 表达式实参的语法期载体。`value` 保留 AST 而非立即求值，确保调用前按从左到右顺序执行
/// 子表达式，并使解释器能将标签与原始字符偏移一并用于重载匹配和错误定位。
struct EvalCallArgument {
    /// 源码中的外部标签；位置参数为 `nil`。
    let label: String?
    /// 尚未求值的参数表达式节点。
    let value: EvalNode
    /// 参数起始字符位置，用于生成可定位的诊断信息。
    let offset: Int
}

/// 表达式 AST。节点只描述语法，不保存运行时对象；解释器据此延迟解析类型、根变量和成员调用。
indirect enum EvalNode {
    case literal(EvalValue, Int)
    case identifier(String, Int)
    case construct(String, [EvalCallArgument], Int)
    case member(EvalNode, String, isCall: Bool, [EvalCallArgument], Int)
    case assignment(EvalNode, EvalNode, Int)
}

// MARK: - 词法

/// 受限表达式语言的词法器。它逐字符扫描而非依赖正则，以正确处理转义字符串、十六进制数、
/// 行注释和精确 offset；tokenize 期间不执行任何业务代码，能在动态调用前安全报语法错误。
private struct EvalLexer {

    /// 词法单元及其在原输入中的位置；解析器只依赖此结构，不再回读源字符串。
    struct Token {
        enum Kind {
            case identifier(String)
            case string(String)
            case integer(Int64)
            case address(UInt)
            case double(Double)
            case punctuation(Character)
            case eof
        }

        /// 单元种类和关联字面值。
        let kind: Kind
        /// 单元第一个字符的零基偏移。
        let offset: Int
    }

    /// 预拆分为扩展字形簇，保证错误位置与 Swift `Character` 视图一致。
    private let characters: [Character]
    /// 下一个待扫描字符的下标；读取方法只推进该游标，避免重复扫描。
    private var index: Int = 0

    /// 保存输入的字符快照；不保留 String.Index，因此后续随机访问为常数时间。
    init(source: String) {
        characters = Array(source)
    }

    /// 扫描完整输入并追加 EOF 哨兵。空白和 `//` 注释被丢弃，其他无法归类的字符立即定位报错。
    mutating func tokenize() throws -> [Token] {
        var tokens: [Token] = []
        while let character = current {
            let start = index
            if character == " " || character == "\n" || character == "\t" || character == "\r" {
                advance()
                continue
            }
            if character == "/" && peek() == "/" {
                skipLineComment()
                continue
            }
            if isIdentifierHead(character) || canStartProjectedMember(character, after: tokens.last) {
                tokens.append(Token(kind: .identifier(readIdentifier()), offset: start))
                continue
            }
            if character == "-" || isDigit(character) {
                tokens.append(try readNumber(start: start))
                continue
            }
            if character == "\"" {
                tokens.append(Token(kind: .string(try readString()), offset: start))
                continue
            }
            if ".,:()[];=".contains(character) {
                // 单字符标点直接成 token：`.` `,` `:` `(` `)` `[` `]` `;`。
                advance()
                tokens.append(Token(kind: .punctuation(character), offset: start))
                continue
            }
            throw EvalError(kind: .syntax, message: "第 \(start) 个字符「\(character)」无法识别")
        }
        tokens.append(Token(kind: .eof, offset: index))
        return tokens
    }

    /// 当前游标字符；到末尾返回 nil，所有读取循环都以此自然终止。
    private var current: Character? {
        index < characters.count ? characters[index] : nil
    }

    /// 前瞻指定字符数但不移动游标，用于识别 `//`、`0x` 和小数点等双字符语法。
    private func peek(_ delta: Int = 1) -> Character? {
        let target = index + delta
        return target < characters.count ? characters[target] : nil
    }

    /// 消费一个已确认属于当前 token 的字符；调用者必须先确保未到输入末尾。
    /// 消费当前 token；EOF 仍可安全前进，`current` 会钳制在末尾哨兵。
    /// 消费当前 token；EOF 仍可安全前进，current 会钳制在末尾哨兵。
    private mutating func advance() {
        index += 1
    }

    /// 丢弃从 `//` 到换行（不含换行）的内容，换行会在下一轮作为普通空白消费。
    private mutating func skipLineComment() {
        while let character = current, character != "\n" { advance() }
    }

    /// 判断 ASCII 十进制数字；表达式语言不接受全角数字和科学计数法。
    private func isDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }

    /// 判断标识符首字符，只开放 ASCII 字母和下划线以与 runtime 类型/成员命名保持一致。
    private func isIdentifierHead(_ character: Character) -> Bool {
        (character >= "a" && character <= "z") || (character >= "A" && character <= "Z") || character == "_"
    }

    /// 判断非首位标识符字符；在首字符规则基础上额外允许数字。
    private func isIdentifierBody(_ character: Character) -> Bool {
        isIdentifierHead(character) || isDigit(character)
    }

    /// Swift property wrapper 的 projected value 以 `$name` 暴露。`$` 只允许出现在点号后的
    /// 成员首位，避免同时放宽顶层类型、根变量和参数标签的语法。
    private func canStartProjectedMember(_ character: Character, after token: Token?) -> Bool {
        guard character == "$", let next = peek(), isIdentifierHead(next), let token = token else {
            return false
        }
        if case .punctuation(".") = token.kind { return true }
        return false
    }

    /// 贪婪读取一个完整标识符，并把游标停在第一个非标识符字符上。
    private mutating func readIdentifier() -> String {
        var text = ""
        if current == "$" {
            text.append("$")
            advance()
        }
        while let character = current, isIdentifierBody(character) {
            text.append(character)
            advance()
        }
        return text
    }

    /// 数字：十进制仍是普通数字；非负 0x 字面量单独保留为对象地址接收者。
    private mutating func readNumber(start: Int) throws -> Token {
        let negative = current == "-"
        if negative {
            advance()
            guard let next = current, isDigit(next) else {
                throw EvalError(kind: .syntax, message: "第 \(start) 个字符的 '-' 后面不是数字")
            }
        }
        let sign: Int64 = negative ? -1 : 1
        if current == "0", let next = peek(), next == "x" || next == "X" {
            guard !negative else {
                throw EvalError(kind: .syntax, message: "第 \(start) 个字符的对象地址不能为负数")
            }
            advance()
            advance()
            var hex = ""
            while let character = current, isHexDigit(character) {
                hex.append(character)
                advance()
            }
            guard !hex.isEmpty, let number = UInt(hex, radix: 16) else {
                throw EvalError(kind: .syntax, message: "第 \(start) 个字符的十六进制字面量不完整")
            }
            return Token(kind: .address(number), offset: start)
        }
        var text = ""
        while let character = current, isDigit(character) {
            text.append(character)
            advance()
        }
        if current == ".", let next = peek(), isDigit(next) {
            text.append(".")
            advance()
            while let character = current, isDigit(character) {
                text.append(character)
                advance()
            }
            guard let number = Double(text) else {
                throw EvalError(kind: .syntax, message: "第 \(start) 个字符的浮点字面量不合法")
            }
            return Token(kind: .double(negative ? -number : number), offset: start)
        }
        guard !text.isEmpty, let number = Int64(text) else {
            throw EvalError(kind: .syntax, message: "第 \(start) 个字符的整数超出 Int64 或不合法")
        }
        return Token(kind: .integer(sign * number), offset: start)
    }

    /// 判断对象地址字面量可接受的 ASCII 十六进制位。
    private func isHexDigit(_ character: Character) -> Bool {
        isDigit(character) || (character >= "a" && character <= "f") || (character >= "A" && character <= "F")
    }

    /// 消费双引号字符串并处理最小转义集；未知转义按原字符保留，未闭合时抛出语法错误。
    private mutating func readString() throws -> String {
        advance()
        var text = ""
        while let character = current {
            if character == "\"" {
                advance()
                return text
            }
            if character == "\\" {
                advance()
                guard let escaped = current else { break }
                switch escaped {
                case "n": text.append("\n")
                case "t": text.append("\t")
                case "r": text.append("\r")
                case "0": text.append("\0")
                default: text.append(escaped)
                }
                advance()
                continue
            }
            text.append(character)
            advance()
        }
        throw EvalError(kind: .syntax, message: "字符串字面量缺少结束引号")
    }
}

// MARK: - 语法

/// 递归下降语法分析器。它只构造 AST，不解析类型、不访问 registry，也不会触发被调方法。
struct EvalParser {

    /// 词法器产出的不可变 token 流，尾部始终有 EOF 哨兵。
    private let tokens: [EvalLexer.Token]
    /// 下一个待归约 token 的下标。
    private var index: Int = 0

    /// 先完成词法分析再创建解析器；词法错误在此阶段原样上抛，避免半初始化状态。
    init(source: String) throws {
        // 先完成词法分析再创建解析器；词法错误在此阶段原样上抛，避免半初始化状态。
        var lexer = EvalLexer(source: source)
        tokens = try lexer.tokenize()
    }

    /// 解析以分号分隔的表达式序列；只允许末尾可选分号，阻止无分隔的隐式拼接。
    mutating func parseProgram() throws -> [EvalNode] {
        var nodes: [EvalNode] = []
        while !isEOF {
            // 顺序解析每条表达式；遇到分号继续下一条，否则要求已到表达式结束。
            nodes.append(try parseExpression())
            if match(";") { continue }
            break
        }
        guard isEOF else {
            throw syntaxError("多余的符号，期望 ';' 或表达式结束")
        }
        return nodes
    }

    /// 当前 token；`min` 使异常路径重复 advance 时仍安全地落在 EOF 哨兵上。
    private var current: EvalLexer.Token {
        tokens[min(index, tokens.count - 1)]
    }

    /// 是否已消费到词法器追加的 EOF，用于判定完整程序而非单一表达式结束。
    private var isEOF: Bool {
        if case .eof = current.kind { return true }
        return false
    }

    /// 当前诊断位置的字符偏移，统一从当前 token 读取以避免各规则自行计算。
    private var offset: Int { current.offset }

    /// 解析主体后的零个或多个 `.member` 后缀，并以左结合方式构造链式访问 AST。
    private mutating func parseExpression() throws -> EvalNode {
        var node = try parsePrimary()
        while match(".") {
            guard case .identifier(let name) = current.kind else {
                throw syntaxError("'.' 后面必须是方法名或属性名")
            }
            let memberOffset = offset
            advance()
            if match("(") {
                let arguments = try parseArguments()
                node = .member(node, name, isCall: true, arguments, memberOffset)
            } else {
                node = .member(node, name, isCall: false, [], memberOffset)
            }
        }
        if match("=") {
            let assignmentOffset = tokens[index - 1].offset
            guard case .member(_, _, isCall: false, _, _) = node else {
                throw EvalError(kind: .syntax,
                                message: "第 \(assignmentOffset) 个字符：赋值目标必须是实例属性")
            }
            node = .assignment(node, try parseExpression(), assignmentOffset)
        }
        return node
    }

    /// 解析标识符/构造、标量、集合或括号表达式；布尔和 nil 在此归一为字面量节点。
    private mutating func parsePrimary() throws -> EvalNode {
        let start = offset
        switch current.kind {
        case .identifier(let name):
            advance()
            if match("(") {
                return .construct(name, try parseArguments(), start)
            }
            switch name {
            case "true": return .literal(.bool(true), start)
            case "false": return .literal(.bool(false), start)
            case "nil": return .literal(.null, start)
            default: return .identifier(name, start)
            }
        case .string(let text):
            advance()
            return .literal(.string(text), start)
        case .integer(let number):
            advance()
            return .literal(.int(number), start)
        case .address(let address):
            advance()
            return .literal(.address(address), start)
        case .double(let number):
            advance()
            return .literal(.double(number), start)
        case .punctuation(let character) where character == "[":
            return try parseCollection(start: start)
        case .punctuation(let character) where character == "(":
            advance()
            let node = try parseExpression()
            guard match(")") else { throw syntaxError("缺少 ')'") }
            return node
        default:
            throw syntaxError("期望标识符或字面量")
        }
    }

    /// 根据首项后是否为冒号区分数组与字典；集合内容被限制为字面量，杜绝在 JSON 输入中触发调用。
    private mutating func parseCollection(start: Int) throws -> EvalNode {
        advance()
        if match("]") { return .literal(.array([]), start) }
        let first = try parseExpression()
        if match(":") {
            // 首个元素是 "key: value"，整个字面量按字典解析
            guard case .literal(.string(let key), _) = first else {
                throw syntaxError("字典字面量的键必须是字符串")
            }
            var items: [String: EvalValue] = [key: try parseLiteralAsValue()]
            while match(",") {
                guard case .string(let nextKey) = current.kind else {
                    throw syntaxError("字典字面量的键必须是字符串")
                }
                advance()
                guard match(":") else { throw syntaxError("字典字面量缺少 ':'") }
                items[nextKey] = try parseLiteralAsValue()
            }
            guard match("]") else { throw syntaxError("字典字面量缺少 ']'") }
            return .literal(.dictionary(items), start)
        }
        var values: [EvalValue] = [try flatten(first)]
        while match(",") {
            values.append(try flatten(try parseExpression()))
        }
        guard match("]") else { throw syntaxError("数组字面量缺少 ']'") }
        return .literal(.array(values), start)
    }

    /// 字面量容器里只允许字面量与字面量表达式，避免把运行时调用塞进静态字面量。
    private mutating func parseLiteralAsValue() throws -> EvalValue {
        return try flatten(try parseExpression())
    }

    /// 将字面量节点还原为值模型；任何标识符、构造或成员访问都被拒绝，保证集合静态可预测。
    private func flatten(_ node: EvalNode) throws -> EvalValue {
        switch node {
        case .literal(let value, _): return value
        default: throw EvalError(kind: .syntax, message: "数组 / 字典字面量里只能写字面量")
        }
    }

    /// 解析括号内实参直到右括号；通过“标识符紧跟冒号”识别标签，不与字典内容混淆。
    private mutating func parseArguments() throws -> [EvalCallArgument] {
        var arguments: [EvalCallArgument] = []
        if match(")") { return arguments }
        while true {
            let start = offset
            var label: String?
            // 标签形如 "forAddress:"；用「标识符 + 紧随其后的冒号」与字典字面量区分
            if case .identifier(let name) = current.kind, isPunctuation(":", at: 1) {
                label = name
                advance()
                advance()
            }
            arguments.append(EvalCallArgument(label: label, value: try parseExpression(), offset: start))
            if match(",") { continue }
            guard match(")") else { throw syntaxError("实参列表缺少 ')'") }
            return arguments
        }
    }

    /// 不消费 token 地检查相对位置的标点，专用于判定参数标签的冒号。
    private func isPunctuation(_ character: Character, at delta: Int) -> Bool {
        let target = index + delta
        guard target < tokens.count, case .punctuation(let found) = tokens[target].kind else { return false }
        return found == character
    }

    /// 为语法错误统一附加当前字符偏移，保证词法和语法阶段的错误格式一致。
    private func syntaxError(_ message: String) -> EvalError {
        EvalError(kind: .syntax, message: "第 \(offset) 个字符：\(message)")
    }

    @discardableResult
    /// 若当前 token 是指定标点则消费并返回 true，否则不移动游标并返回 false。
    private mutating func match(_ character: Character) -> Bool {
        guard case .punctuation(let found) = current.kind, found == character else { return false }
        advance()
        return true
    }

    private mutating func advance() {
        index += 1
    }
}
