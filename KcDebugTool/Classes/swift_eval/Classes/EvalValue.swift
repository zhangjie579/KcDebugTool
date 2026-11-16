import Foundation

/// 保留十六进制字面量的「对象地址」语义，避免与普通整数接收者混淆。
struct EvalObjectAddress {
    let rawValue: UInt
}

/// eval 里的统一值模型：表达式字面量、方法实参、方法返回值都走这一层。
///
/// `.object` 刻意保留原始 Swift 值：返回值可能还要参与链式调用、按真实类型继续派发，
/// 因此不能只留一份文本快照。基础类型单独成 case，方便做参数转换与字面量输出。
public enum EvalValue {
    /// Swift nil、Optional.none 或 NSNull 的统一表示。
    case null
    /// 布尔字面量或经 CFBoolean 识别的 NSNumber。
    case bool(Bool)
    /// 统一保存的有符号整数；无符号值按位转换，以保留寄存器/地址语义。
    case int(Int64)
    /// 显式十六进制对象地址，不与普通整数混淆，使用时需经过 isa 校验。
    case address(UInt)
    /// 双精度浮点字面量或 NSNumber 浮点值。
    case double(Double)
    /// 未加引号的 Swift 字符串内容。
    case string(String)
    /// 递归装箱的数组字面量或桥接数组。
    case array([EvalValue])
    /// 键限定为 String 的递归装箱字典，便于稳定 JSON 输出。
    case dictionary([String: EvalValue])
    /// 无法安全归入基础 case 的原始值；保留它才能继续做真实类型的链式分派。
    case object(Any)

    /// 属性递归展示最多允许 10 层，防止 UIView 等大型对象图拖垮调试页。
    static let maximumDisplayDepth = 10
    private static var configuredMaxDepth: Int = maximumDisplayDepth
    /// 全局默认展示深度；setter 会夹紧到 `1...maximumDisplayDepth`，防止对象图无限展开。
    public static var maxDepth: Int {
        get { configuredMaxDepth }
        set { configuredMaxDepth = min(max(newValue, 1), maximumDisplayDepth) }
    }

    /// 每层最多展示的元素/属性数；超过部分以省略标记输出，不影响原始值。
    public static var maxItems: Int = 200

    /// 把任意 Swift 返回值装箱。Optional.none 统一成 .null，其余非基础类型保留原值。
    /// 将任意运行时值装箱：先解开 Optional，再识别 Foundation 桥接数值，最后保留原值。
    /// 该顺序避免 `NSNumber(true)` 被误显示为整数 1，也避免丢失链式调用所需的对象身份。
    public init(any value: Any?) {
        guard let value = value else {
            self = .null
            return
        }
        if value is NSNull {
            self = .null
            return
        }
        if value is Void {
            self = .object(value)
            return
        }
        // Any 里装 Optional 时不能用 as? 直接取 Wrapped，需靠 Mirror 拆一层
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            if let child = mirror.children.first {
                self = EvalValue(any: child.value)
            } else {
                self = .null
            }
            return
        }
        switch value {
        case let address as EvalObjectAddress:
            self = .address(address.rawValue)
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            self = EvalValue(number: number)
        case let flag as Bool:
            self = .bool(flag)
        case let number as Int:
            self = .int(Int64(number))
        case let number as Int64:
            self = .int(number)
        case let number as UInt:
            self = .int(Int64(bitPattern: UInt64(number)))
        case let number as UInt64:
            self = .int(Int64(bitPattern: number))
        case let number as Int32:
            self = .int(Int64(number))
        case let number as UInt32:
            self = .int(Int64(number))
        case let number as Double:
            self = .double(number)
        case let number as Float:
            self = .double(Double(number))
        default:
            self = .object(value)
        }
    }

    /// NSNumber 的 Bool 与 0/1 在 ObjC 编码里都是 'c'，靠 CFBoolean 单例区分，避免把数字 1 显示成 true。
    private init(number: NSNumber) {
        if number === NSNumber(value: true) || number === NSNumber(value: false) {
            self = .bool(number.boolValue)
            return
        }
        let encoding = String(cString: number.objCType)
        switch encoding {
        case "f", "d":
            self = .double(number.doubleValue)
        case "c", "C", "s", "S", "i", "I", "l", "L", "q", "Q", "B":
            self = .int(number.int64Value)
        default:
            self = .object(number)
        }
    }

    // MARK: - 基础信息

    /// 动态类型名，去掉模块前缀，便于和 Mach-O 符号里的短类型名比对。
    /// 用于结果页与错误信息的短动态类型名；对象类型去除模块前缀以便阅读和符号匹配。
    public var typeName: String {
        switch self {
        case .null: return "nil"
        case .bool: return "Bool"
        case .int: return "Int"
        case .address: return "Address"
        case .double: return "Double"
        case .string: return "String"
        case .array: return "Array"
        case .dictionary: return "Dictionary"
        case .object(let value): return EvalValue.shortTypeName(of: value)
        }
    }

    /// 是否为空值（nil / NSNull），供可选链与布尔判断使用。
    /// 是否为统一空值，用于解释器的 nil 安全链判断。
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// 获取值的动态类型并剥离最后一个模块前缀；不会读取对象属性或执行 getter。
    public static func shortTypeName(of value: Any) -> String {
        let full = String(reflecting: Swift.type(of: value))
        return full.split(separator: ".").last.map(String.init) ?? full
    }

    // MARK: - 取参

    /// 还原成 Swift 值：`.object` 原样返回，用于把前一步的返回值传给下一步。
    /// 还原可传给下一次调用的 Swift 值；容器递归还原，`object` 保持对象/值类型原貌。
    public var anyValue: Any? {
        switch self {
        case .null: return nil
        case .bool(let flag): return flag
        case .int(let number): return number
        case .address(let address): return EvalObjectAddress(rawValue: address)
        case .double(let number): return number
        case .string(let text): return text
        case .array(let items): return items.map { $0.anyValue as Any }
        case .dictionary(let items):
            var result: [String: Any] = [:]
            for (key, item) in items { result[key] = item.anyValue as Any }
            return result
        case .object(let value): return value
        }
    }

    /// 转换为 String；仅允许标量，地址会格式化为十六进制，集合与对象必须由调用方显式处理。
    public func asString() throws -> String {
        switch self {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .address(let address): return "0x" + String(address, radix: 16)
        case .double(let number): return String(number)
        case .bool(let flag): return String(flag)
        default: throw EvalError(kind: .argument, message: "期望 String，实际是 \(typeName)")
        }
    }

    /// 转换为平台 `Int`；字符串支持十进制和 `0x` 十六进制，溢出会抛出参数错误。
    public func asInt() throws -> Int {
        switch self {
        case .int(let number): return Int(number)
        case .address(let address):
            guard let number = Int(exactly: address) else {
                throw EvalError(kind: .argument, message: "对象地址超出 Int 范围")
            }
            return number
        case .double(let number): return Int(number)
        case .bool(let flag): return flag ? 1 : 0
        case .string(let text):
            guard let number = Int(text.trimmingCharacters(in: .whitespaces), radix: 10)
                    ?? EvalValue.parseHex(text) else {
                throw EvalError(kind: .argument, message: "无法把 \"\(text)\" 转成 Int")
            }
            return number
        default: throw EvalError(kind: .argument, message: "期望 Int，实际是 \(typeName)")
        }
    }

    /// 转换为 Double；不把字符串隐式解析为浮点，避免表达式文本的歧义。
    public func asDouble() throws -> Double {
        switch self {
        case .double(let number): return number
        case .int(let number): return Double(number)
        case .address(let address): return Double(address)
        default: throw EvalError(kind: .argument, message: "期望 Double，实际是 \(typeName)")
        }
    }

    /// 转换为 Bool；数值/地址按是否为零判断，其余类型拒绝以避免意外真值语义。
    public func asBool() throws -> Bool {
        switch self {
        case .bool(let flag): return flag
        case .int(let number): return number != 0
        case .address(let address): return address != 0
        default: throw EvalError(kind: .argument, message: "期望 Bool，实际是 \(typeName)")
        }
    }

    /// 获取数组；对原始 `[Any]` 按元素重新装箱，保证后续参数转换和展示规则一致。
    public func asArray() throws -> [EvalValue] {
        switch self {
        case .array(let items): return items
        case .object(let value):
            if let array = value as? [Any] { return array.map { EvalValue(any: $0) } }
            throw EvalError(kind: .argument, message: "期望 Array，实际是 \(typeName)")
        default: throw EvalError(kind: .argument, message: "期望 Array，实际是 \(typeName)")
        }
    }

    /// 获取字符串键字典；对原始 `[String: Any]` 逐值装箱，其他键类型明确拒绝。
    public func asDictionary() throws -> [String: EvalValue] {
        switch self {
        case .dictionary(let items): return items
        case .object(let value):
            if let dict = value as? [String: Any] {
                var result: [String: EvalValue] = [:]
                for (key, item) in dict { result[key] = EvalValue(any: item) }
                return result
            }
            throw EvalError(kind: .argument, message: "期望 Dictionary，实际是 \(typeName)")
        default: throw EvalError(kind: .argument, message: "期望 Dictionary，实际是 \(typeName)")
        }
    }

    /// 解析带 0x 前缀的十六进制字符串；只用于显式 Int 转换，不影响词法阶段的对象地址 case。
    private static func parseHex(_ text: String) -> Int? {
        var raw = text.trimmingCharacters(in: .whitespaces)
        guard raw.hasPrefix("0x") || raw.hasPrefix("0X") else { return nil }
        raw = String(raw.dropFirst(2))
        return Int(raw, radix: 16)
    }

    // MARK: - 传给 ObjC 方法

    /// 转成 ObjC 消息参数。基本数据类型装箱成 NSNumber，NSInvocation 再按真实
    /// type encoding 拆箱；对象参数直接透传。结构体 / union / 指针不做猜测。
    /// 转为可由 `NSInvocation` 接收的对象参数。标量转 NSNumber，容器转 Foundation 容器；
    /// 非 class 的 Swift 值类型拒绝桥接，避免生成 `__SwiftValue` 后在目标方法侧崩溃。
    public var objcObject: AnyObject? {
        switch self {
        case .null: return NSNull()
        case .bool(let flag): return NSNumber(value: flag)
        case .int(let number): return NSNumber(value: number)
        case .address(let address): return NSNumber(value: address)
        case .double(let number): return NSNumber(value: number)
        case .string(let text): return text as NSString
        case .array(let items): return items.compactMap { $0.objcObject } as NSArray
        case .dictionary(let items):
            var result: [String: AnyObject] = [:]
            for (key, item) in items { result[key] = item.objcObject ?? NSNull() }
            return result as NSDictionary
        case .object(let value):
            // Swift 值类型桥接成 __SwiftValue 后会导致方法侧类型转换崩溃，这里只放行类实例
            if Mirror(reflecting: value).displayStyle == .class || value is NSObject {
                return value as AnyObject
            }
            return NSNull()
        }
    }

    // MARK: - 展示与 JSON

    /// 人类可读输出：标量走 Swift 字面量样式，容器 / 对象先转安全 JSON 树再格式化。
    /// 使用当前全局限制生成可读文本；调试页的单次覆盖请调用带参数版本。
    public var displayText: String {
        displayText(maxDepth: Self.maxDepth, maxItems: Self.maxItems)
    }

    /// 以指定预算格式化值。对象先生成安全 JSON 树，再按 IDE/LLDB 常见格式呈现字段。
    public func displayText(maxDepth: Int, maxItems: Int) -> String {
        switch self {
        case .null:
            return "nil"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .int(let number):
            return String(number)
        case .address(let address):
            return "0x" + String(address, radix: 16)
        case .double(let number):
            return String(number)
        case .string(let text):
            return "\"" + text + "\""
        case .array, .dictionary:
            // 容器先生成安全 JSON 树，再按缩进序列化输出。
            let json = jsonObject(maxDepth: maxDepth, maxItems: maxItems)
            return Self.prettyJSON(json)
        case .object(let value):
            let tree = jsonObject(maxDepth: maxDepth, maxItems: maxItems)
            if Self.prefersJSONDisplay(value) { return Self.prettyJSON(tree) }
            return Self.ideDisplay(value: value, tree: tree)
        }
    }

    /// 在值是合法 JSON 时使用稳定排序与缩进序列化，否则降级为 Swift 描述，保证展示永不抛错。
    private static func prettyJSON(_ value: Any) -> String {
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    /// 只有真正的 JSON 容器使用 JSON 展示；普通 class/struct 即使能转换成字典，
    /// 也按 Xcode/LLDB 常见的对象格式输出。
    private static func prefersJSONDisplay(_ value: Any) -> Bool {
        if value is NSArray || value is NSDictionary { return true }
        let style = Mirror(reflecting: value).displayStyle
        return style == .collection || style == .dictionary
    }

    /// 使用安全 JSON 树生成接近 Xcode/LLDB 的对象展示；原值仅用来提供回退动态类型名。
    private static func ideDisplay(value: Any, tree: Any) -> String {
        let fallbackType = String(reflecting: Swift.type(of: value))
        return ideValue(tree, level: 0, fallbackType: fallbackType)
    }

    /// 递归格式化 JSON 树中的单项，识别截断/循环标记并保持它们不被二次加引号污染。
    private static func ideValue(_ value: Any, level: Int, fallbackType: String? = nil) -> String {
        if value is NSNull { return "nil" }
        if let text = value as? String {
            if text.hasPrefix("…（") || text.hasPrefix("↩︎（") || text.hasPrefix("<") { return text }
            return "\"" + text + "\""
        }
        if let number = value as? NSNumber { return EvalValue(number: number).displayText }
        if let array = value as? [Any] { return ideArray(array, level: level) }
        if let dictionary = value as? [String: Any] {
            return ideDictionary(dictionary, level: level, fallbackType: fallbackType)
        }
        return String(describing: value)
    }

    /// 以索引和缩进输出数组，层级由调用方传入以和对象字段保持对齐。
    private static func ideArray(_ values: [Any], level: Int) -> String {
        guard !values.isEmpty else { return "[]" }
        let indent = String(repeating: "  ", count: level)
        let childIndent = indent + "  "
        let lines = values.enumerated().map { index, value in
            "\(childIndent)[\(index)] = \(ideValue(value, level: level + 1))"
        }
        return "[\n" + lines.joined(separator: "\n") + "\n\(indent)]"
    }

    /// 输出带类型/地址头部的对象字段字典，并将属性元数据与普通键分开排版。
    private static func ideDictionary(_ dictionary: [String: Any], level: Int,
                                      fallbackType: String?) -> String {
        let typeName = dictionary["$type"] as? String ?? fallbackType
        let address = dictionary["$address"] as? String
        let header: String
        if let typeName = typeName, let address = address {
            header = "<\(typeName): \(address)>"
        } else if let typeName = typeName {
            header = typeName
        } else {
            header = ""
        }
        let indent = String(repeating: "  ", count: level)
        let childIndent = indent + "  "
        var lines: [String] = []
        var propertyNames = Set<String>()
        if let properties = dictionary["$properties"] as? [String: Any] {
            for name in properties.keys.sorted() {
                propertyNames.insert(name)
                guard let detail = properties[name] as? [String: Any] else { continue }
                let type = detail["type"] as? String ?? "?"
                let owner = detail["owner"] as? String ?? "?"
                let output: String
                if let propertyValue = detail["value"] {
                    output = ideValue(propertyValue, level: level + 1)
                } else if let unavailable = detail["valueUnavailable"] as? String {
                    output = "<unavailable: \(unavailable)>"
                } else if let error = detail["error"] as? String {
                    output = "<error: \(error)>"
                } else {
                    output = "<unavailable>"
                }
                lines.append("\(childIndent)\(name): \(type) [\(owner)] = \(output)")
            }
        }
        let reserved: Set<String> = ["$type", "$address", "$description", "$properties"]
        for key in dictionary.keys.sorted() where !reserved.contains(key) && !propertyNames.contains(key) {
            guard let child = dictionary[key] else { continue }
            lines.append("\(childIndent)\(key) = \(ideValue(child, level: level + 1))")
        }
        if lines.isEmpty { return header.isEmpty ? "{}" : header }
        let prefix = header.isEmpty ? "" : header + " "
        return prefix + "{\n" + lines.joined(separator: "\n") + "\n\(indent)}"
    }

    /// 转成 Foundation JSON 兼容对象；任意 Swift struct / class 经 Mirror 展开，
    /// 因此 `[HeapObject]`、`ReferenceReport` 这类返回值也能直接在网页里查看。
    public var jsonObject: Any {
        jsonObject(maxDepth: Self.maxDepth, maxItems: Self.maxItems)
    }

    /// 在调用方指定的深度和每层元素预算下生成 JSON 安全对象；预算会创建独立遍历上下文，互不污染。
    public func jsonObject(maxDepth: Int, maxItems: Int) -> Any {
        // 为本次转换创建独立遍历上下文（深度 + 每层数量 + 对象身份环检测）。
        let context = JSONTraversalContext(maxDepth: maxDepth, maxItems: maxItems)
        return jsonObject(context: context, depth: 0)
    }

    /// 按当前 EvalValue case 递归转换；对象 case 委托反射函数，并通过 context 统一处理数量/环引用限制。
    private func jsonObject(context: JSONTraversalContext, depth: Int) -> Any {
        if depth >= context.maxDepth { return "…（超出展示深度 \(context.maxDepth)）" }
        switch self {
        case .null: return NSNull()
        case .bool(let flag): return NSNumber(value: flag)
        case .int(let number): return NSNumber(value: number)
        case .address(let address): return "0x" + String(address, radix: 16)
        case .double(let number):
            guard number.isFinite else { return String(number) }
            return NSNumber(value: number)
        case .string(let text): return text
        case .array(let items):
            let head = items.prefix(context.maxItems).map { $0.jsonObject(context: context, depth: depth + 1) }
            return items.count > context.maxItems ? head + ["…（还有 \(items.count - context.maxItems) 项）"] : head
        case .dictionary(let items):
            var result: [String: Any] = [:]
            for (index, entry) in items.sorted(by: { $0.key < $1.key }).enumerated() {
                if index >= context.maxItems {
                    result["…"] = "还有 \(items.count - context.maxItems) 项"
                    break
                }
                result[entry.key] = entry.value.jsonObject(context: context, depth: depth + 1)
            }
            return result
        case .object(let value): return EvalValue.json(any: value, depth: depth, context: context)
        }
    }

    /// 将任意子值先解开 Optional、桥接容器和标量，最后才反射普通对象，避免 Mirror 分支吞掉标准集合。
    private static func json(any value: Any, depth: Int, context: JSONTraversalContext) -> Any {
        if depth >= context.maxDepth { return "…（超出展示深度 \(context.maxDepth)）" }
        if !Thread.isMainThread {
            let object = value as AnyObject
            if SEMachOSymbolResolver.requiresMainThread(object: object) {
                var reflected: Any = NSNull()
                DispatchQueue.main.sync {
                    reflected = json(any: value, depth: depth, context: context)
                }
                return reflected
            }
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return NSNull() }
            return json(any: child.value, depth: depth + 1, context: context)
        }
        if let text = value as? String { return text }
        if value is NSNull { return NSNull() }
        if let number = value as? NSNumber {
            return EvalValue(number: number).jsonObject(context: context, depth: depth)
        }
        if let flag = value as? Bool { return NSNumber(value: flag) }
        if let number = value as? Int { return NSNumber(value: number) }
        if let number = value as? Int64 { return NSNumber(value: number) }
        if let number = value as? UInt { return NSNumber(value: number) }
        if let number = value as? UInt64 { return NSNumber(value: number) }
        if let number = value as? Double {
            guard number.isFinite else { return String(number) }
            return NSNumber(value: number)
        }
        if let number = value as? Float {
            guard number.isFinite else { return String(number) }
            return NSNumber(value: number)
        }

        if mirror.displayStyle == .class {
            let object = value as AnyObject
            let identifier = ObjectIdentifier(object)
            if context.activeObjects.contains(identifier) {
                // 检测到对象身份环，停止递归读取，返回稳定的循环引用占位文本。
                return circularReference(object: object, value: value)
            }
            context.activeObjects.insert(identifier)
            defer { context.activeObjects.remove(identifier) }
            if let array = value as? NSArray {
                let count = min(array.count, context.maxItems)
                var result = (0..<count).map {
                    json(any: array[$0], depth: depth + 1, context: context)
                }
                if array.count > count { result.append("…（还有 \(array.count - count) 项）") }
                return result
            }
            if let dictionary = value as? NSDictionary {
                var result: [String: Any] = [:]
                for (index, key) in dictionary.allKeys.enumerated() {
                    guard index < context.maxItems else {
                        result["…"] = "还有 \(dictionary.count - context.maxItems) 项"
                        break
                    }
                    let name = String(describing: key)
                    if let item = dictionary[key] {
                        result[name] = json(any: item, depth: depth + 1, context: context)
                    }
                }
                return result
            }
            return reflectedClass(value: value, depth: depth, context: context)
        }
        if let array = value as? [Any] {
            let head = array.prefix(context.maxItems).map {
                json(any: $0, depth: depth + 1, context: context)
            }
            return array.count > context.maxItems
                ? head + ["…（还有 \(array.count - context.maxItems) 项）"]
                : head
        }
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (index, entry) in dict.sorted(by: { $0.key < $1.key }).enumerated() {
                if index >= context.maxItems {
                    result["…"] = "还有 \(dict.count - context.maxItems) 项"
                    break
                }
                result[entry.key] = json(any: entry.value, depth: depth + 1, context: context)
            }
            return result
        }
        switch mirror.displayStyle {
        case .collection?, .set?, .tuple?:
            let items = mirror.children.prefix(context.maxItems).map {
                json(any: $0.value, depth: depth + 1, context: context)
            }
            return Array(items)
        case .dictionary?:
            var result: [String: Any] = [:]
            for child in mirror.children.prefix(context.maxItems) {
                let pair = Mirror(reflecting: child.value).children
                if let key = pair.first?.value, let item = pair.dropFirst().first?.value {
                    result["\(key)"] = json(any: item, depth: depth + 1, context: context)
                }
            }
            return result
        case .enum?:
            if let child = mirror.children.first {
                var result: [String: Any] = ["case": "\(value)"]
                result["value"] = json(any: child.value, depth: depth + 1, context: context)
                return result
            }
            return "\(value)"
        case .struct?:
            var result: [String: Any] = [:]
            for child in mirror.children.prefix(context.maxItems) {
                result[child.label ?? "?"] = json(any: child.value, depth: depth + 1, context: context)
            }
            return result.isEmpty ? "\(value)" : result
        default:
            return "\(value)"
        }
    }

    /// 对 class 生成 `$type`/`$address`/`$properties` 树；利用对象身份集合检测循环，并限制每层字段数。
    private static func reflectedClass(value: Any, depth: Int,
                                       context: JSONTraversalContext) -> Any {
        let object = value as AnyObject
        let address = UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())
        var result: [String: Any] = [
            "$type": String(reflecting: Swift.type(of: value)),
            "$address": "0x" + String(address, radix: 16)
        ]
        let properties = SwiftMachOInvoker.reflectedProperties(
            of: value, maximumCount: context.maxItems + 1)
        for property in properties.prefix(context.maxItems) {
            let key = result[property.name] == nil
                ? property.name
                : property.ownerTypeName + "." + property.name
            if let propertyValue = property.value {
                result[key] = json(any: propertyValue, depth: depth + 1, context: context)
            } else {
                result[key] = NSNull()
            }
        }
        if properties.count > context.maxItems {
            result["…"] = "对象属性超过 \(context.maxItems) 项"
        }
        return result
    }

    /// 为检测到的对象身份环生成包含动态类型和地址的稳定占位文本，不再递归读取其属性。
    private static func circularReference(object: AnyObject, value: Any) -> String {
        let address = UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())
        return "↩︎（循环引用 \(shortTypeName(of: value)) @ 0x\(String(address, radix: 16))）"
    }

    private final class JSONTraversalContext {
        let maxDepth: Int
        let maxItems: Int
        var activeObjects = Set<ObjectIdentifier>()

        /// 创建单次 JSON 遍历的预算和身份集合；每次公开 jsonObject 调用都必须使用新实例。
        init(maxDepth: Int, maxItems: Int) {
            self.maxDepth = min(max(maxDepth, 1), EvalValue.maximumDisplayDepth)
            self.maxItems = max(maxItems, 1)
        }
    }
}
