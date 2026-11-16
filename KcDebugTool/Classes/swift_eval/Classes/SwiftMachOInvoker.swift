import Foundation

/// 原生 Swift 方法的 Mach-O 符号信息。动态调用只接受普通函数体符号，跳过 thunk、
/// 属性访问器和协议见证表入口，避免同名符号被当成可直接调用的方法。
private struct SwiftMachOMethod {

    enum Kind {
        case instanceMethod
        case classMethod
        case staticMethod
        case instanceProperty
        case classProperty
        case staticProperty
        case initializer
    }

    /// ASLR 后当前进程中的函数入口；只在本次进程生命周期内有效。
    let address: UInt
    let mangled: String
    let demangled: String
    let qualifiedTypeName: String
    let memberName: String
    let labels: [String]
    let parameterTypes: [String]
    let returnType: String
    let kind: Kind
}

/// Mach-O 只负责提供地址；签名解析、Swift 元数据解析和 `Any` 装箱必须留在 Swift，
/// 否则 ObjC 无法正确管理 String、Array、自定义 Swift 值等非 ObjC 返回值的生命周期。
enum SwiftMachOInvoker {

    /// Mirror 读取出的存储字段；与计算属性不同，读取此值不执行 getter。
    struct ReflectedProperty {
        let name: String
        let ownerTypeName: String
        let value: Any?
    }

    /// 成员清单用的 Swift 符号摘要。与动态调用共用同一套解析规则，
    /// 保证「清单里能看到的」与「表达式能调到的」是同一批符号。
    struct MemberDescription {
        enum Group {
            case property
            case instanceMethod
            case classMethod
        }

        let name: String
        let labels: [String]
        let parameterTypes: [String]
        let returnType: String
        let address: UInt
        let group: Group
        let isClassMember: Bool
        let demangled: String
    }

    /// 保护符号与方法缓存；递归锁允许 metadata 解析过程中再次查询符号而不死锁。
    private static let lock = NSRecursiveLock()
    private static var symbolCache: [String: [[String: Any]]] = [:]
    private static var methodCache: [String: [SwiftMachOMethod]] = [:]
    private static var discoveredTypes = Set<String>()

    /// 通过可解析成员或 Swift metadata 判断类型是否存在；后者覆盖没有可见方法符号的类型。
    static func hasType(named name: String) -> Bool {
        // 先看缓存/符号里有没有可调用方法，再退到 Swift 类型元数据（覆盖没有方法符号的纯类型）。
        !methods(typeName: name).isEmpty || metadataType(named: name) != nil
    }

    /// 返回去重排序后的成员短名，用于错误提示和目录，不承诺每个同名重载都可安全调用。
    static func memberNames(typeName: String) -> [String] {
        // 对每个类型去重成员短名并排序，供目录与错误提示使用（不保证每个重载都可安全调用）。
        Array(Set(methods(typeName: typeName).map(\.memberName))).sorted()
    }

    /// 纯 Swift 类不在 NSClassFromString 的名字表里；类型元数据仍可还原成类对象，
    /// 让成员清单能沿 class_getSuperclass 走完整条继承链。
    static func classType(named displayName: String) -> AnyClass? {
        metadataType(named: displayName) as? AnyClass
    }

    /// 一次扫描全部 Swift 符号并按类型短名分组，供成员清单沿继承链取用。
    /// 直接按每个类名调用 symbols(containing:) 会把整张符号表重复过滤 N 遍。
    static func memberDescriptions(forTypeNames typeNames: [String]) -> [String: [MemberDescription]] {
        let wanted = Set(typeNames.map(SwiftEvalRegistry.key))
        guard !wanted.isEmpty else { return [:] }
        var result: [String: [MemberDescription]] = [:]
        for raw in SEMachOSymbolResolver.symbols(containingAnyTypeIn: wanted.sorted()) {
            guard let demangled = raw["demangled"] as? String,
                  // @objc thunk 是 ObjC ABI 入口，清单里由 runtime 那份代表；
                  // 初始化表达式 / __allocating_init 等编译器产物也不属于可调用成员。
                  !demangled.hasPrefix("@objc "),
                  !demangled.contains("variable initialization expression of"),
                  !demangled.contains("with unmangled suffix"),
                  !demangled.contains(".__"),
                  !demangled.hasSuffix(".deinit"),
                  let method = parseMember(raw, requestedType: nil) else { continue }
            let key = SwiftEvalRegistry.key(method.qualifiedTypeName)
            guard wanted.contains(key) else { continue }
            result[key, default: []].append(description(of: method))
        }
        return result
    }

    /// 将内部 ABI 签名投影为详情页模型，并根据符号种类归类为属性、实例方法或类方法。
    private static func description(of method: SwiftMachOMethod) -> MemberDescription {
        let group: MemberDescription.Group
        let isClassMember: Bool
        switch method.kind {
        case .instanceProperty:
            group = .property
            isClassMember = false
        case .classProperty, .staticProperty:
            group = .property
            isClassMember = true
        case .instanceMethod:
            group = .instanceMethod
            isClassMember = false
        case .classMethod, .staticMethod, .initializer:
            group = .classMethod
            isClassMember = true
        }
        return MemberDescription(name: method.memberName, labels: method.labels,
                                 parameterTypes: method.parameterTypes,
                                 returnType: method.returnType, address: method.address,
                                 group: group, isClassMember: isClassMember,
                                 demangled: method.demangled)
    }

    /// 返回已经解析过的类型与成员缓存快照；不主动扫描所有类型，避免目录请求触发全量工作。
    static func catalog() -> [String: [String]] {
        lock.lock()
        let names = discoveredTypes
        lock.unlock()
        // 把已发现类型映射成「类型 -> 成员短名列表」，目录请求不触发全量符号扫描。
        return Dictionary(uniqueKeysWithValues: names.sorted().map { ($0, memberNames(typeName: $0)) })
    }

    /// 按标签和参数数消歧后调用 Swift 类型/静态方法；类方法使用 metadata 作 self，上下文布局由调用桩处理。
    static func callTypeMethod(typeName: String, name: String, labels: [String],
                               arguments: [EvalArguments.Item]) throws -> EvalReturn? {
        let candidates = matchingMethods(typeName: typeName, name: name, labels: labels,
                                         argumentCount: arguments.count)
        guard !candidates.isEmpty else { return nil }
        // 静态 / 类计算属性在符号表里是 `.staticProperty` / `.classProperty`，一并纳入。
        if let method = unique(candidates.filter {
            $0.kind == .staticMethod || $0.kind == .classMethod ||
            $0.kind == .staticProperty || $0.kind == .classProperty
        }) {
            // 取类型 metadata 作为 ABI 调用上下文（写入 x20），按类方法签名调用。
            let context = try metadataAddress(for: method.qualifiedTypeName)
            return try invoke(method, context: context, arguments: arguments)
        }
        if let method = unique(candidates.filter { $0.kind == .instanceMethod || $0.kind == .instanceProperty }) {
            // 没有类方法入口时，当作「在临时实例上调用」：先按零参构造实例，再以对象地址作上下文调用。
            let instance = try instantiate(typeName: method.qualifiedTypeName, arguments: [])
            let context = objectAddress(instance)
            return try withExtendedLifetime(instance) {
                try invoke(method, context: context, arguments: arguments)
            }
        }
        throw ambiguous(typeName: typeName, member: name, candidates: candidates)
    }

    /// 调用纯 Swift 或混编对象的实例方法；对象地址以非持有方式传给 ABI，调用期间由上层强引用保持存活。
    static func callInstanceMethod(object: Any, typeName: String, name: String, labels: [String],
                                   arguments: [EvalArguments.Item]) throws -> EvalReturn? {
        let candidates = matchingMethods(typeName: typeName, name: name, labels: labels,
                                         argumentCount: arguments.count)
        guard !candidates.isEmpty else { return nil }
        // getter 在符号表里是 `.instanceProperty`，与实例方法一并纳入，使计算属性可被调用。
        guard let method = unique(candidates.filter {
            $0.kind == .instanceMethod || $0.kind == .instanceProperty
        }) else {
            throw ambiguous(typeName: typeName, member: name, candidates: candidates)
        }
        // 以对象地址作 ABI 上下文（x20=self），调用期间强持有对象防止被释放。
        let context = objectAddress(object)
        return try withExtendedLifetime(object) {
            try invoke(method, context: context, arguments: arguments)
        }
    }

    /// 查找零参数静态/class getter 并调用；只接受符号表明确标识为属性的访问器。
    static func readTypeProperty(typeName: String, name: String) throws -> EvalReturn? {
        let candidates = methods(typeName: typeName).filter {
            $0.memberName == name && ($0.kind == .staticProperty || $0.kind == .classProperty)
        }
        guard !candidates.isEmpty else { return nil }
        guard let property = unique(candidates) else {
            throw ambiguous(typeName: typeName, member: name, candidates: candidates)
        }
        // 类型属性以 metadata 作 self，零参数调用 getter 取回属性值。
        let context = try metadataAddress(for: property.qualifiedTypeName)
        return try invoke(property, context: context, arguments: [])
    }

    /// 从 Mirror 存储字段读取实例属性，不触发 getter；找不到时返回 nil 交由计算属性路径继续处理。
    static func readInstanceProperty(object: Any, name: String) -> EvalReturn? {
        // 先从 Mirror 存储字段里找同名属性（不触发 getter），作为无副作用回退。
        guard let property = reflectedProperties(of: object).first(where: { $0.name == name }) else {
            return nil
        }
        return .value(property.value)
    }

    /// 读取计算 / 存储属性的 getter，供「无括号」形式 `instance.prop` 使用。
    /// 只匹配属性符号（`.instanceProperty`），不触碰普通实例方法，
    /// 避免把「无括号的方法引用」误当成调用产生副作用。
    /// 解析并调用 Mach-O 中的零参数实例 getter，使 Mirror 不可见的计算属性也可读取。
    static func readComputedInstanceProperty(object: Any, typeName: String, name: String) -> EvalReturn? {
        let candidates = methods(typeName: typeName).filter {
            $0.kind == .instanceProperty && $0.memberName == name && $0.parameterTypes.isEmpty
        }
        guard let property = unique(candidates) else { return nil }
        // 用对象地址作上下文调用零参数 getter；失败时静默放过，交由后续分支继续处理。
        let context = objectAddress(object)
        return try? invoke(property, context: context, arguments: [])
    }

    /// Mirror 的 class children 只包含当前层声明的存储属性，父类属性需要继续遍历
    /// `superclassMirror`。lazy 属性展示的是编译器 backing storage，这里还原业务属性名，
    /// 并拆掉 backing storage 自身的 Optional，避免后续链式调用拿到多余的可选层。
    /// 沿 Mirror.superclassMirror 收集存储字段，可按数量截断；不会调用 getter，适合作为低副作用回退。
    static func reflectedProperties(of object: Any, maximumCount: Int? = nil) -> [ReflectedProperty] {
        var result: [ReflectedProperty] = []
        var current: Mirror? = Mirror(reflecting: object)
        while let mirror = current, maximumCount.map({ result.count < $0 }) ?? true {
            let ownerTypeName = String(reflecting: mirror.subjectType)
            for child in mirror.children {
                guard maximumCount.map({ result.count < $0 }) ?? true else { break }
                guard let label = child.label else { continue }
                let field = reflectedField(label: label, value: child.value)
                result.append(ReflectedProperty(name: field.name,
                                                ownerTypeName: ownerTypeName,
                                                value: field.value))
            }
            current = mirror.superclassMirror
        }
        return result
    }

    /// 还原 Swift lazy 属性的 `$__lazy_storage_$_` 名称，并解开其 Optional 存储包装。
    private static func reflectedField(label: String, value: Any) -> (name: String, value: Any?) {
        let lazyStoragePrefix = "$__lazy_storage_$_"
        guard label.hasPrefix(lazyStoragePrefix) else { return (label, value) }
        let name = String(label.dropFirst(lazyStoragePrefix.count))
        let storage = Mirror(reflecting: value)
        guard storage.displayStyle == .optional else { return (name, value) }
        return (name, storage.children.first?.value)
    }

    /// 找到唯一匹配初始化器并以类型 metadata 为上下文调用；无参时额外尝试编译器生成的默认参数函数。
    static func instantiate(typeName: String, arguments: [EvalArguments.Item]) throws -> Any {
        let initializers = methods(typeName: typeName).filter {
            $0.kind == .initializer && $0.parameterTypes.count == arguments.count
        }
        guard let initializer = unique(initializers) else {
            // 无参且找不到显式 init 时，尝试调用编译器生成的默认参数 thunk 来构造实例。
            if initializers.isEmpty, arguments.isEmpty,
               let defaultInitializer = try initializerWithDefaults(typeName: typeName) {
                return defaultInitializer
            }
            throw ambiguous(typeName: typeName, member: "init", candidates: initializers)
        }
        // 用类型 metadata 作上下文动态调用初始化器，再把返回的寄存器值装箱成对象。
        let context = try metadataAddress(for: initializer.qualifiedTypeName)
        let result = try invokeRaw(initializer, context: context, arguments: arguments)
        return try box(result: result, typeName: initializer.returnType)
    }

    /// 支持所有参数都有默认值的初始化方法。默认参数生成器也是普通 Swift 符号，
    /// 因而仍然遵循“从 Mach-O 找地址并动态调用”，不需要业务方注册工厂闭包。
    /// 尝试调用 Swift 编译器为默认参数生成的 thunk，补全每个参数后再调用原初始化器；找不到任何 thunk 即放弃。
    private static func initializerWithDefaults(typeName: String) throws -> Any? {
        let initializers = methods(typeName: typeName).filter { $0.kind == .initializer && !$0.parameterTypes.isEmpty }
        for initializer in initializers {
            let rawSymbols = symbols(containing: SwiftEvalRegistry.key(typeName))
            var generatedArguments: [EvalArguments.Item] = []
            var allFound = true
            for index in initializer.parameterTypes.indices {
                let marker = "default argument \(index) of \(initializer.qualifiedTypeName).init("
                guard let symbol = rawSymbols.first(where: {
                    ($0["demangled"] as? String)?.contains(marker) == true
                }), let address = (symbol["address"] as? NSNumber)?.uintValue else {
                    allFound = false
                    break
                }
                let pseudo = SwiftMachOMethod(
                    address: address,
                    mangled: symbol["mangled"] as? String ?? "",
                    demangled: symbol["demangled"] as? String ?? "",
                    qualifiedTypeName: initializer.qualifiedTypeName,
                    memberName: "defaultArgument\(index)",
                    labels: [], parameterTypes: [],
                    returnType: initializer.parameterTypes[index],
                    kind: .staticMethod)
                let raw = try invokeRaw(pseudo, context: 0, arguments: [])
                let value = try box(result: raw, typeName: initializer.parameterTypes[index])
                generatedArguments.append(EvalArguments.Item(label: initializer.labels[index],
                                                               value: EvalValue(any: value)))
            }
            if allFound {
                let context = try metadataAddress(for: initializer.qualifiedTypeName)
                let raw = try invokeRaw(initializer, context: context, arguments: generatedArguments)
                return try box(result: raw, typeName: initializer.returnType)
            }
        }
        return nil
    }

    private struct RawCallResult {
        let general: [UInt]
        let floating: [UInt64]
    }

    /// 调用符号并将原始寄存器返回值依据 demangle 返回类型装箱成 EvalReturn；Void 保持独立语义。
    private static func invoke(_ method: SwiftMachOMethod, context: UInt,
                               arguments: [EvalArguments.Item]) throws -> EvalReturn {
        if ["Void", "()"].contains(normalized(method.returnType)) {
            // Void 返回无需取寄存器值，调用后直接标记无返回值。
            _ = try invokeRaw(method, context: context, arguments: arguments)
            return .void
        }
        let raw = try invokeRaw(method, context: context, arguments: arguments)
        // 将原始返回寄存器按 demangle 返回类型装箱为 EvalReturn.value。
        return .value(try box(result: raw, typeName: method.returnType))
    }

    /// 按 arm64 Swift ABI 布置 x0...x7/d0...d7 参数并调用 ObjC 层汇编桩；所有对象参数在调用期间强持有。
    private static func invokeRaw(_ method: SwiftMachOMethod, context: UInt,
                                  arguments: [EvalArguments.Item]) throws -> RawCallResult {
        guard SEMachOSymbolResolver.supportsCurrentArchitecture() else {
            throw EvalError(kind: .unsupported, message: "Mach-O Swift 动态调用当前只支持 arm64 真机")
        }
        guard arguments.count == method.parameterTypes.count else {
            throw EvalError(kind: .argument, message: "方法参数数量与 Swift 符号签名不一致")
        }
        try validateDirectReturn(typeName: method.returnType)
        var general: [UInt64] = []
        var floating: [UInt64] = []
        var keepAlive: [Any] = []
        for (item, expectedType) in zip(arguments, method.parameterTypes) {
            // 逐个把实参按目标参数 ABI 展开到通用/浮点寄存器，并登记强引用防止调用期间对象被释放。
            try appendArgument(item.value.anyValue, expectedType: expectedType,
                               general: &general, floating: &floating, keepAlive: &keepAlive)
        }
        guard general.count <= 8, floating.count <= 8 else {
            throw EvalError(kind: .unsupported,
                            message: "方法参数超过 arm64 可直接传递的 8 个普通或浮点寄存器")
        }
        let output: [String: [NSNumber]] = try withExtendedLifetime(keepAlive) {
            // 调用 ObjC 层汇编桩：把通用/浮点寄存器字交给 arm64 调用桩，返回捕获的寄存器值。
            try SEMachOSymbolResolver.invokeAddress(
                method.address,
                context: context,
                generalWords: general.map { NSNumber(value: $0) },
                floatingWords: floating.map { NSNumber(value: $0) })
        }
        return RawCallResult(
            general: (output["general"] ?? []).map { UInt(truncating: $0) },
            floating: (output["floating"] ?? []).map(\.uint64Value))
    }

    /// 将一个 Swift 值转换为目标参数 ABI 的通用寄存器或浮点寄存器字；不支持的布局立即拒绝而非猜测。
    private static func appendArgument(_ raw: Any?, expectedType: String,
                                       general: inout [UInt64], floating: inout [UInt64],
                                       keepAlive: inout [Any]) throws {
        let type = normalized(expectedType)
        if let wrappedType = optionalWrappedType(type) {
            try appendOptionalArgument(raw, wrappedType: wrappedType,
                                       general: &general, keepAlive: &keepAlive)
            return
        }
        switch type {
        case "Bool":
            guard let value = raw as? Bool else { throw mismatch(raw, expected: expectedType) }
            general.append(value ? 1 : 0)
        case "Int", "Int8", "Int16", "Int32", "Int64":
            guard let value = integer(raw) else { throw mismatch(raw, expected: expectedType) }
            general.append(UInt64(bitPattern: Int64(value)))
        case "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            guard let value = unsignedInteger(raw) else { throw mismatch(raw, expected: expectedType) }
            general.append(UInt64(value))
        case "Float":
            guard let value = floatingNumber(raw) else { throw mismatch(raw, expected: expectedType) }
            floating.append(UInt64(Float(value).bitPattern))
        case "Double":
            guard let value = floatingNumber(raw) else { throw mismatch(raw, expected: expectedType) }
            floating.append(value.bitPattern)
        case "String":
            guard var value = raw as? String else { throw mismatch(raw, expected: expectedType) }
            let words = withUnsafeBytes(of: &value) { bytes in
                Array(bytes.bindMemory(to: UInt64.self))
            }
            guard words.count == 2 else {
                throw EvalError(kind: .unsupported, message: "当前 Swift String ABI 不是预期的双字布局")
            }
            general.append(contentsOf: words)
            keepAlive.append(value)
        case "[String]", "Array<String>":
            guard var value = raw as? [String] else { throw mismatch(raw, expected: expectedType) }
            try appendSingleWord(&value, typeName: expectedType, general: &general)
            keepAlive.append(value)
        case "Set<String>":
            guard var value = raw as? Set<String> else { throw mismatch(raw, expected: expectedType) }
            try appendSingleWord(&value, typeName: expectedType, general: &general)
            keepAlive.append(value)
        case "[String: String]", "[String : String]", "Dictionary<String, String>":
            guard var value = raw as? [String: String] else { throw mismatch(raw, expected: expectedType) }
            try appendSingleWord(&value, typeName: expectedType, general: &general)
            keepAlive.append(value)
        default:
            guard let value = raw else {
                general.append(0)
                return
            }
            let objectType = type.hasSuffix("?") ? String(type.dropLast()) : expectedType
            guard metadataType(named: objectType) is AnyClass else {
                throw EvalError(kind: .unsupported,
                                message: "参数类型 \(expectedType) 不是已支持的基本类型或对象类型")
            }
            let object: AnyObject
            if let address = value as? EvalObjectAddress {
                object = try ObjectiveCEvalBridge.object(at: address.rawValue).value
            } else {
                object = value as AnyObject
            }
            general.append(UInt64(UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())))
            keepAlive.append(object)
        }
    }

    /// Optional<Int/UInt> 会按 payload + discriminator 展开到两个普通寄存器；
    /// discriminator 为 0 表示 some、1 表示 none。对象 Optional 使用空指针表达 nil。
    /// 编码受支持的一字 Optional：标量使用 payload+tag，对象 optional 用 nil/对象引用；多字 optional 明确拒绝。
    private static func appendOptionalArgument(_ raw: Any?, wrappedType: String,
                                               general: inout [UInt64],
                                               keepAlive: inout [Any]) throws {
        switch wrappedType {
        case "Int":
            guard raw == nil || integer(raw) != nil else { throw mismatch(raw, expected: "Int?") }
            let payload = integer(raw).map { UInt64(bitPattern: Int64($0)) } ?? 0
            general.append(payload)
            general.append(raw == nil ? 1 : 0)
        case "UInt":
            guard raw == nil || unsignedInteger(raw) != nil else { throw mismatch(raw, expected: "UInt?") }
            general.append(unsignedInteger(raw).map { UInt64($0) } ?? 0)
            general.append(raw == nil ? 1 : 0)
        default:
            guard metadataType(named: wrappedType) is AnyClass else {
                throw EvalError(kind: .unsupported,
                                message: "Optional<\(wrappedType)> 参数的 Swift ABI 尚未支持")
            }
            guard let raw = raw else {
                general.append(0)
                return
            }
            let object: AnyObject
            if let address = raw as? EvalObjectAddress {
                object = try ObjectiveCEvalBridge.object(at: address.rawValue).value
            } else {
                object = raw as AnyObject
            }
            general.append(UInt64(UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())))
            keepAlive.append(object)
        }
    }

    /// 从 `T?` 或 `Optional<T>` 提取包裹类型，供参数编码选择 optional 布局。
    private static func optionalWrappedType(_ type: String) -> String? {
        if type.hasSuffix("?") { return String(type.dropLast()) }
        return genericInner(type, names: ["Optional"])
    }

    /// 验证泛型值确为一个机器字后复制位模式到通用参数寄存器，避免误传多字 struct。
    private static func appendSingleWord<T>(_ value: inout T, typeName: String,
                                             general: inout [UInt64]) throws {
        guard MemoryLayout<T>.size == MemoryLayout<UInt64>.size else {
            throw EvalError(kind: .unsupported,
                            message: "参数类型 \(typeName) 不是预期的单字 Swift 容器布局")
        }
        let word = withUnsafeBytes(of: &value) { $0.load(as: UInt64.self) }
        general.append(word)
    }

    /// 将调用桩捕获的返回寄存器恢复为 Float/Double 或 Any existential；前置校验保证值为直接返回布局。
    private static func box(result: RawCallResult, typeName: String) throws -> Any {
        let type = normalized(typeName)
        if type == "Float" {
            guard let bits = result.floating.first else { throw invalidReturn(typeName) }
            return Float(bitPattern: UInt32(truncatingIfNeeded: bits))
        }
        if type == "Double" {
            guard let bits = result.floating.first else { throw invalidReturn(typeName) }
            return Double(bitPattern: bits)
        }
        guard let metadata = metadataType(named: typeName) else {
            throw EvalError(kind: .unsupported,
                            message: "无法从 Swift runtime 解析返回类型元数据：\(typeName)")
        }
        var words = result.general
        while words.count < 3 { words.append(0) }
        let container = SwiftExistentialContainer(
            word0: words[0], word1: words[1], word2: words[2], metadata: metadata)
        // Swift.Any 的 opaque existential 是三个 inline words + metadata。返回寄存器中的
        // +1 值在这里转移给 existential，之后由对应 ValueWitness 正确销毁。
        return unsafeBitCast(container, to: Any.self)
    }

    /// Swift 间接返回会要求调用方预先在 x8 放置结果缓冲区。当前桥只捕获 x0...x2，
    /// 因此必须在跳转前拒绝非 inline 或超过三个字的返回值，不能调用后再补救。
    private static func validateDirectReturn(typeName: String) throws {
        let type = normalized(typeName)
        if ["Void", "()", "Float", "Double"].contains(type) { return }
        guard let metadata = metadataType(named: typeName) else {
            throw EvalError(kind: .unsupported,
                            message: "无法从 Swift runtime 解析返回类型元数据：\(typeName)")
        }
        let metadataAddress = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
        let witnessTable = metadataAddress.load(fromByteOffset: -MemoryLayout<UInt>.size,
                                                as: UnsafeRawPointer.self)
        let size = witnessTable.load(fromByteOffset: 8 * MemoryLayout<UInt>.size, as: UInt.self)
        let flags = witnessTable.load(fromByteOffset: 10 * MemoryLayout<UInt>.size, as: UInt.self)
        let isNonInline = flags & 0x0002_0000 != 0
        guard size <= 3 * MemoryLayout<UInt>.size, !isNonInline else {
            throw EvalError(kind: .unsupported,
                            message: "返回类型 \(typeName) 需要间接返回缓冲区，当前动态调用不支持")
        }
        let knownRegisterValue = metadata is AnyClass || [
            "Bool", "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "String"
        ].contains(type) || type.hasPrefix("[") || type.hasPrefix("Array<") ||
            type.hasPrefix("Dictionary<") || type.hasPrefix("Set<") ||
            type.hasPrefix("Optional<") || type.hasSuffix("?")
        guard knownRegisterValue else {
            throw EvalError(kind: .unsupported,
                            message: "返回类型 \(typeName) 的寄存器布局无法安全确认",
                            suggestion: "当前支持对象、基本类型及标准 Array/Dictionary/Set/Optional")
        }
    }

    private struct SwiftExistentialContainer {
        let word0: UInt
        let word1: UInt
        let word2: UInt
        let metadata: Any.Type
    }

    // MARK: - 符号与签名

    /// 在缓存签名中筛选可调用种类、名称、实参数和外部标签；标签为空时只按数量匹配，供无标签调用兼容。
    private static func matchingMethods(typeName: String, name: String, labels: [String],
                                        argumentCount: Int) -> [SwiftMachOMethod] {
        methods(typeName: typeName).filter { method in
            // 计算 / 存储属性的 getter 在符号表里以 `.instanceProperty` 等形式存在，
            // 也需要纳入可调用集合，否则 `instance.prop` / `instance.prop()` 取不到值。
            let isCallable = method.kind == .instanceMethod || method.kind == .classMethod ||
                method.kind == .staticMethod || method.kind == .instanceProperty ||
                method.kind == .classProperty || method.kind == .staticProperty
            guard isCallable, method.memberName == name,
                  method.parameterTypes.count == argumentCount else { return false }
            if labels.isEmpty { return true }
            return zip(labels, method.labels).allSatisfy { supplied, declared in
                supplied.isEmpty || supplied == declared
            }
        }
    }

    /// 解析并缓存某类型关联的函数符号；缓存键保留全名以避免跨模块短名冲突。
    private static func methods(typeName: String) -> [SwiftMachOMethod] {
        let key = typeName
        let shortName = SwiftEvalRegistry.key(typeName)
        lock.lock()
        defer { lock.unlock() }
        if let cached = methodCache[key] { return cached }
        // 首次解析：按短类型名取符号并过滤成可调用方法，缓存后登记到已发现类型集合。
        let parsed = symbols(containing: shortName).compactMap { parseMember($0, requestedType: key) }
        methodCache[key] = parsed
        if !parsed.isEmpty { discoveredTypes.insert(shortName) }
        return parsed
    }

    /// 从 ObjC 符号解析器获取并缓存包含短类型名的 demangle 符号字典。
    private static func symbols(containing typeName: String) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = symbolCache[typeName] { return cached }
        // 首次扫描 ObjC 解析器里的 demangle 符号字典并按类型名缓存。
        let symbols = SEMachOSymbolResolver.symbolsContainingType(typeName)
        symbolCache[typeName] = symbols
        return symbols
    }

    /// requestedType 为 nil 时不过滤类型，用于成员清单的一次性全量分组。
    private static func parseMember(_ raw: [String: Any], requestedType: String?) -> SwiftMachOMethod? {
        guard let address = (raw["address"] as? NSNumber)?.uintValue,
              let mangled = raw["mangled"] as? String,
              let demangled = raw["demangled"] as? String,
              !demangled.contains("thunk for"), !demangled.contains("function signature specialization"),
              !demangled.contains("dispatch thunk"), !demangled.contains("method descriptor"),
              !demangled.contains("protocol witness"), !demangled.contains("partial apply"),
              !demangled.contains("outlined") else { return nil }
        let prefix: String
        let kindPrefix: SwiftMachOMethod.Kind
        if demangled.hasPrefix("static ") {
            prefix = "static "
            kindPrefix = .staticMethod
        } else if demangled.hasPrefix("class ") {
            prefix = "class "
            kindPrefix = .classMethod
        } else {
            prefix = ""
            kindPrefix = .instanceMethod
        }
        let body = String(demangled.dropFirst(prefix.count))
        // 先尝试按 `.getter :` 形式识别为属性符号，识别不到再走普通函数解析。
        if let property = parsePropertyBody(body, address: address, mangled: mangled,
                                            demangled: demangled, requestedType: requestedType,
                                            methodKind: kindPrefix) {
            return property
        }
        guard let bounds = functionParameterBounds(in: body) else { return nil }
        let open = bounds.open
        let close = bounds.close
        let head = String(body[..<open])
        guard let dot = head.lastIndex(of: ".") else { return nil }
        let qualifiedType = String(head[..<dot])
        let member = normalizedMemberName(String(head[head.index(after: dot)...]))
        if let requestedType = requestedType {
            if requestedType.contains(".") {
                guard qualifiedType == requestedType else { return nil }
            } else {
                guard SwiftEvalRegistry.key(qualifiedType) == requestedType else { return nil }
            }
        }
        let parameterText = String(body[body.index(after: open)..<close])
        // 按顶层逗号切分参数，逐个解析出「外部标签 + 类型」，再截取返回类型。
        let parameters = splitTopLevel(parameterText)
        let labelsAndTypes = parameters.map(parseParameter)
        let returnStart = body.index(close, offsetBy: 5)
        let returnType = String(body[returnStart...])
        let kind: SwiftMachOMethod.Kind = member == "init" ? .initializer : kindPrefix
        return SwiftMachOMethod(address: address, mangled: mangled, demangled: demangled,
                                qualifiedTypeName: qualifiedType, memberName: member,
                                labels: labelsAndTypes.map(\.0),
                                parameterTypes: labelsAndTypes.map(\.1),
                                returnType: returnType, kind: kind)
    }

    /// 识别 demangle 文本中的 `.getter :` 形式，将其映射为对应的实例/class/static 属性符号。
    private static func parsePropertyBody(_ body: String, address: UInt, mangled: String,
                                          demangled: String, requestedType: String?,
                                          methodKind: SwiftMachOMethod.Kind) -> SwiftMachOMethod? {
        let marker = ".getter : "
        guard let getterRange = body.range(of: marker) else { return nil }
        let head = String(body[..<getterRange.lowerBound])
        guard let dot = head.lastIndex(of: ".") else { return nil }
        let qualifiedType = String(head[..<dot])
        let propertyName = normalizedMemberName(String(head[head.index(after: dot)...]))
        if let requestedType = requestedType {
            if requestedType.contains(".") {
                guard qualifiedType == requestedType else { return nil }
            } else {
                guard SwiftEvalRegistry.key(qualifiedType) == requestedType else { return nil }
            }
        }
        let kind: SwiftMachOMethod.Kind
        switch methodKind {
        case .staticMethod: kind = .staticProperty
        case .classMethod: kind = .classProperty
        default: kind = .instanceProperty
        }
        return SwiftMachOMethod(address: address, mangled: mangled, demangled: demangled,
                                qualifiedTypeName: qualifiedType, memberName: propertyName,
                                labels: [], parameterTypes: [],
                                returnType: String(body[getterRange.upperBound...]), kind: kind)
    }

    /// 在嵌套泛型、数组和元组外层寻找第一个冒号，拆出外部标签与完整参数类型。
    private static func parseParameter(_ text: String) -> (String, String) {
        var depth = 0
        for index in text.indices {
            switch text[index] {
            case "<", "[", "(": depth += 1
            case ">", "]", ")": depth -= 1
            case ":" where depth == 0:
                let label = text[..<index].trimmingCharacters(in: .whitespaces)
                let type = text[text.index(after: index)...].trimmingCharacters(in: .whitespaces)
                return (label, type)
            default: break
            }
        }
        return ("_", text.trimmingCharacters(in: .whitespaces))
    }

    /// 从某个左括号向后匹配同层右括号，支持参数类型内嵌元组。
    private static func matchingClose(in text: String, open: String.Index) -> String.Index? {
        var depth = 0
        for index in text.indices[open...] {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    /// private/fileprivate 成员的 demangle 名会带文件级 discriminator：
    /// `Type.(method in _HASH)() -> Void`。第一个左括号属于成员名而非参数列表，
    /// 因此逐个检查左括号，取第一个闭括号后紧跟 ` -> ` 的完整参数列表。
    private static func functionParameterBounds(
        in text: String
    ) -> (open: String.Index, close: String.Index)? {
        for index in text.indices where text[index] == "(" {
            guard let close = matchingClose(in: text, open: index) else { continue }
            if text[close...].hasPrefix(") -> ") { return (index, close) }
        }
        return nil
    }

    /// 去掉 private/fileprivate demangle 名中的文件级 discriminator，使展示与用户输入使用业务成员名。
    private static func normalizedMemberName(_ name: String) -> String {
        guard name.hasPrefix("("), name.hasSuffix(")"),
              let discriminator = name.range(of: " in ", options: .backwards) else {
            return name
        }
        return String(name[name.index(after: name.startIndex)..<discriminator.lowerBound])
    }

    /// 按最外层逗号分割类型列表，忽略泛型、数组和元组内部的逗号。
    private static func splitTopLevel(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        var start = text.startIndex
        var depth = 0
        for index in text.indices {
            switch text[index] {
            case "<", "[", "(": depth += 1
            case ">", "]", ")": depth -= 1
            case "," where depth == 0:
                result.append(String(text[start..<index]).trimmingCharacters(in: .whitespaces))
                start = text.index(after: index)
            default: break
            }
        }
        result.append(String(text[start...]).trimmingCharacters(in: .whitespaces))
        return result
    }

    // MARK: - Swift 类型元数据

    /// 解析 Swift 类型元数据并转为 ABI 需要的裸地址；失败时抛出可读的 unknownType 错误。
    private static func metadataAddress(for typeName: String) throws -> UInt {
        guard let type = metadataType(named: typeName) else {
            throw EvalError(kind: .unknownType, message: "找不到 Swift 类型元数据：\(typeName)")
        }
        // 把 Any.Type 转换为 ABI 调用所需的裸指针地址（写入 x20 作为 metadata/self）。
        return UInt(bitPattern: unsafeBitCast(type, to: UnsafeRawPointer.self))
    }

    /// 将展示类型名先重写为 Swift mangled 名，再通过 runtime `_typeByName` 取得 metadata。
    private static func metadataType(named displayName: String) -> Any.Type? {
        // 先重写展示名为 mangled 名，再向 Swift runtime 请求类型元数据。
        guard let mangled = mangledTypeName(from: displayName) else { return nil }
        return Swift._typeByName(mangled)
    }

    /// 覆盖基础类型、Optional/集合泛型和镜像简写；自定义类型从 metadata accessor 符号反推出 mangled 名。
    private static func mangledTypeName(from displayName: String) -> String? {
        let text = displayName.trimmingCharacters(in: .whitespaces)
        let basics: [String: String] = [
            "Any": "yp", "AnyObject": "yXl", "Void": "yt", "()": "yt",
            "Swift.Bool": "Sb", "Bool": "Sb",
            "Swift.Int": "Si", "Int": "Si", "Swift.UInt": "Su", "UInt": "Su",
            "Swift.Int8": "s4Int8V", "Int8": "s4Int8V",
            "Swift.Int16": "s5Int16V", "Int16": "s5Int16V",
            "Swift.Int32": "s5Int32V", "Int32": "s5Int32V",
            "Swift.Int64": "s5Int64V", "Int64": "s5Int64V",
            "Swift.UInt8": "s5UInt8V", "UInt8": "s5UInt8V",
            "Swift.UInt16": "s6UInt16V", "UInt16": "s6UInt16V",
            "Swift.UInt32": "s6UInt32V", "UInt32": "s6UInt32V",
            "Swift.UInt64": "s6UInt64V", "UInt64": "s6UInt64V",
            "Swift.Float": "Sf", "Float": "Sf", "Swift.Double": "Sd", "Double": "Sd",
            "Swift.String": "SS", "String": "SS"
        ]
        if let basic = basics[text] { return basic }
        if text.hasSuffix("?"), let wrapped = mangledTypeName(from: String(text.dropLast())) {
            return wrapped + "Sg"
        }
        if let inner = genericInner(text, names: ["Swift.Optional", "Optional"]),
           let wrapped = mangledTypeName(from: inner) {
            return wrapped + "Sg"
        }
        if let inner = genericInner(text, names: ["Swift.Array", "Array"]),
           let element = mangledTypeName(from: inner) {
            return "Say\(element)G"
        }
        if let inner = genericInner(text, names: ["Swift.Set", "Set"]),
           let element = mangledTypeName(from: inner) {
            return "Shy\(element)G"
        }
        if let inner = genericInner(text, names: ["Swift.Dictionary", "Dictionary"]) {
            let parts = splitTopLevel(inner)
            if parts.count == 2,
               let key = mangledTypeName(from: parts[0]), let value = mangledTypeName(from: parts[1]) {
                return "SDy\(key)\(value)G"
            }
        }
        if text.hasPrefix("["), text.hasSuffix("]") {
            let inner = String(text.dropFirst().dropLast())
            let parts = splitTopLevel(inner.replacingOccurrences(of: ":", with: ",", options: [], range: nil))
            if inner.contains(":"), parts.count == 2,
               let key = mangledTypeName(from: parts[0]), let value = mangledTypeName(from: parts[1]) {
                return "SDy\(key)\(value)G"
            }
            if let element = mangledTypeName(from: inner) { return "Say\(element)G" }
        }
        let short = SwiftEvalRegistry.key(text)
        for symbol in symbols(containing: short) {
            guard let demangled = symbol["demangled"] as? String,
                  demangled == "type metadata accessor for \(text)",
                  let mangled = symbol["mangled"] as? String,
                  mangled.hasPrefix("$s"), mangled.hasSuffix("Ma") else { continue }
            return String(mangled.dropFirst(2).dropLast(2))
        }
        return nil
    }

    /// 若文本匹配指定泛型容器名，返回尖括号内部原始类型文本，不在此处递归解析。
    private static func genericInner(_ text: String, names: [String]) -> String? {
        for name in names {
            let prefix = name + "<"
            if text.hasPrefix(prefix), text.hasSuffix(">") {
                return String(text.dropFirst(prefix.count).dropLast())
            }
        }
        return nil
    }

    /// 移除 `Swift.` 前缀，统一 demangle、反射和手写表达式中的标准库类型名称。
    private static func normalized(_ typeName: String) -> String {
        typeName.replacingOccurrences(of: "Swift.", with: "")
    }

    /// 获取 Any 桥接为对象后的非持有地址；仅用于正在调用期间的 self 上下文，不能长期保存。
    private static func objectAddress(_ value: Any) -> UInt {
        let object = value as AnyObject
        return UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())
    }

    /// 仅当所有候选最终指向同一函数地址时返回，避免重载/重复符号的任意选择。
    private static func unique(_ methods: [SwiftMachOMethod]) -> SwiftMachOMethod? {
        guard let first = methods.first else { return nil }
        let uniqueAddresses = Set(methods.map(\.address))
        return uniqueAddresses.count == 1 ? first : nil
    }

    /// 将受支持有符号整数、NSNumber 或对象地址收窄为 Int；溢出返回 nil 交给参数错误路径。
    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? EvalObjectAddress { return Int(exactly: value.rawValue) }
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(exactly: value) }
        if let value = value as? UInt64 { return Int(exactly: value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    /// 将非负整数或地址转为 UInt；显式拒绝负数，防止二补码被误当大地址。
    private static func unsignedInteger(_ value: Any?) -> UInt? {
        if let value = value as? EvalObjectAddress { return value.rawValue }
        if let value = value as? UInt { return value }
        if let value = value as? Int, value >= 0 { return UInt(value) }
        if let value = value as? Int64, value >= 0 { return UInt(value) }
        if let value = value as? UInt64 { return UInt(exactly: value) }
        if let value = value as? NSNumber, value.int64Value >= 0 { return UInt(value.uint64Value) }
        return nil
    }

    /// 提取 Double/Float/NSNumber 的浮点值，不对字符串做隐式解析。
    private static func floatingNumber(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Float { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    /// 构造参数类型不匹配错误，并保留动态实际类型帮助定位重载选择问题。
    private static func mismatch(_ value: Any?, expected: String) -> EvalError {
        EvalError(kind: .argument,
                  message: "参数类型不匹配：期望 \(expected)，收到 \(value.map { String(reflecting: type(of: $0)) } ?? "nil")")
    }

    /// 当调用桩未捕获预期返回寄存器时生成 invocation 错误，避免继续解包未初始化位模式。
    private static func invalidReturn(_ type: String) -> EvalError {
        EvalError(kind: .invocation, message: "没有取得 \(type) 的返回寄存器")
    }

    /// 构造“无成员”或“多个不可消歧符号”错误，并列出 demangle 候选供调用方补充标签。
    private static func ambiguous(typeName: String, member: String,
                                  candidates: [SwiftMachOMethod]) -> EvalError {
        let signatures = candidates.map(\.demangled).joined(separator: "；")
        return EvalError(kind: candidates.isEmpty ? .unknownMember : .unsupported,
                         message: candidates.isEmpty
                            ? "\(typeName) 上找不到可动态调用的 \(member)"
                            : "\(typeName).\(member) 存在多个无法消歧的 Swift 符号",
                         suggestion: signatures.isEmpty ? nil : signatures)
    }
}
