import Foundation
import ObjectiveC

// MARK: - 错误与返回值

/// eval 的错误分类；`suggestion` 用于把「为什么不能自动调用」和可行处理方式写清楚。
public struct EvalError: Error, CustomStringConvertible {
    /// 错误发生的阶段；供 HTTP/UI 使用稳定分类，而非依赖可读错误文案。
    public enum Kind: String {
        case syntax
        case unknownType
        case unknownMember
        case arity
        case argument
        case invocation
        case unsupported
    }

    /// 机器可判断的错误类别。
    public let kind: Kind
    /// 描述发生位置和直接原因的可读文案。
    public let message: String
    /// 可选修复提示，例如已发现的类型、成员或受支持参数范围。
    public let suggestion: String?

    /// 创建结构化错误；`suggestion` 为空时不会写入最终展示文本。
    public init(kind: Kind, message: String, suggestion: String? = nil) {
        self.kind = kind
        self.message = message
        self.suggestion = suggestion
    }

    /// 合并类别、原因与建议的最终错误文本，用于日志和 `EvalResult.displayText`。
    public var description: String {
        var text = "[\(kind.rawValue)] \(message)"
        if let suggestion = suggestion, !suggestion.isEmpty {
            text += "（\(suggestion)）"
        }
        return text
    }
}

/// 方法返回值：`.void` 与 `.value(nil)` 必须区分，否则「无返回值的方法」和「返回 nil 的方法」无法分辨。
public enum EvalReturn {
    /// Objective-C `void` 或 Swift `Void` 调用结果；不能等同于 `value(nil)`。
    case void
    /// 有返回槽位的调用结果，内部 `nil` 代表 Optional.none / ObjC nil。
    case value(Any?)
}

/// 动态方法调用的实参集合，支持按下标或按 Swift 参数标签取值。
public struct EvalArguments {

    public struct Item {
        /// 调用点提供的外部参数标签；位置参数为 `nil`。
        public let label: String?
        /// 已被统一装箱的参数值，延后至目标签名明确后才转换。
        public let value: EvalValue
    }

    /// 按源代码顺序保存的参数；顺序不能丢失，因为 Swift 的 `_` 标签仍参与重载匹配。
    public let items: [Item]

    /// 用已求值的参数项创建参数集合；通常仅由解释器调用。
    public init(_ items: [Item]) {
        self.items = items
    }

    /// 实参数量，用于在实际取值前快速进行签名匹配。
    public var count: Int { items.count }

    /// 保留位置参数的占位，避免 `foo(1, bar: 2)` 被压缩成 `["bar"]` 后与
    /// 方法签名的第一个 `_` 标签错位。
    public var labels: [String] { items.map { $0.label ?? "_" } }

    public func item(at index: Int) throws -> Item {
        guard index >= 0, index < items.count else {
            throw EvalError(kind: .arity, message: "缺少第 \(index) 个实参，实际只有 \(items.count) 个")
        }
        return items[index]
    }

    /// 按外部标签查找第一个实参；缺失时使用 `.argument` 而非 `.arity`，以区分调用方错误。
    public func item(labeled label: String) throws -> Item {
        guard let found = items.first(where: { $0.label == label }) else {
            throw EvalError(kind: .argument, message: "缺少标签为 \(label) 的实参")
        }
        return found
    }

    /// 返回指定位置的统一值模型，越界时抛出 `.arity`。
    public func value(at index: Int) throws -> EvalValue { try item(at: index).value }
    public func string(at index: Int) throws -> String { try item(at: index).value.asString() }
    public func int(at index: Int) throws -> Int { try item(at: index).value.asInt() }
    /// 读取并按 EvalValue 规则转换第 index 个实参为 Double。
    public func double(at index: Int) throws -> Double { try item(at: index).value.asDouble() }
    /// 读取并按 EvalValue 规则转换第 index 个实参为 Bool。
    public func bool(at index: Int) throws -> Bool { try item(at: index).value.asBool() }
    /// 读取并按 EvalValue 规则转换第 index 个实参为递归值数组。
    public func array(at index: Int) throws -> [EvalValue] { try item(at: index).value.asArray() }
    /// 读取并按 EvalValue 规则转换第 index 个实参为 String 键字典。
    public func dictionary(at index: Int) throws -> [String: EvalValue] { try item(at: index).value.asDictionary() }

    /// 返回上一步调用的原始值，用于链式调用中传递对象。
    public func raw(at index: Int) throws -> Any? { try item(at: index).value.anyValue }

    /// 以 Swift 真实类型提取原始参数，不做字符串/数值宽松转换，适合自定义桥接实现。
    public func cast<T>(at index: Int, as type: T.Type) throws -> T {
        guard let value = try raw(at: index) as? T else {
            throw EvalError(kind: .argument, message: "第 \(index) 个实参无法转成 \(T.self)")
        }
        return value
    }

    // MARK: - 按标签取参

    // 手动注册方法没有编译期签名，调用方通常按表达式里写的标签取值；
    // 这组方法与上面的「按下标取参」一一对应，缺失标签统一抛 `.argument`。

    /// 按外部标签取统一值模型；不带标签的位置参数用 `_` 无法命中，改按下标取值。
    public func value(labeled label: String) throws -> EvalValue { try item(labeled: label).value }
    /// 按外部标签取 String，转换规则与 string(at:) 相同。
    public func string(labeled label: String) throws -> String { try item(labeled: label).value.asString() }
    /// 按外部标签取 Int，转换规则与 int(at:) 相同。
    public func int(labeled label: String) throws -> Int { try item(labeled: label).value.asInt() }
    /// 按外部标签取 Double，转换规则与 double(at:) 相同。
    public func double(labeled label: String) throws -> Double { try item(labeled: label).value.asDouble() }
    /// 按外部标签取 Bool，转换规则与 bool(at:) 相同。
    public func bool(labeled label: String) throws -> Bool { try item(labeled: label).value.asBool() }
    /// 按外部标签取原始 Swift 值，适合对象、数组、字典等需要保留真实类型的参数。
    public func raw(labeled label: String) throws -> Any? { try item(labeled: label).value.anyValue }

    // MARK: - 对象实参

    /// 把第 index 个实参还原成当前进程内的真实对象，供手动注册方法直接操作已有实例。
    /// 两种可接受的形态：
    /// - `0x...` 地址字面量 → 走与链式调用相同的 `mach_vm_read` + isa 校验，拒绝野指针；
    /// - 已是对象的实参（根变量、上一步返回值）→ 原样返回，不做地址解析。
    /// 标量 / `nil` 会抛 `.argument`，避免把普通整数误当成对象地址。
    public func object(at index: Int) throws -> AnyObject {
        let value = try value(at: index)
        if case .address(let address) = value {
            return try ObjectiveCEvalBridge.object(at: address).value
        }
        // 只接受真实的类实例：Any 直接转 AnyObject 会把 struct / 标量自动装箱成
        // NSNumber、_SwiftValue 等桥接对象，那不是调用方想操作的业务对象。
        // 已由 type(of:) 确认是类实例，as AnyObject 只是类型擦除，返回同一引用。
        if case .object(let object) = value, type(of: object) is AnyClass {
            return object as AnyObject
        }
        throw EvalError(kind: .argument,
                        message: "第 \(index) 个实参不是对象或对象地址（标量可用 raw(at:) 读取）")
    }

    /// object(at:) 的标签版：先按标签定位下标，再复用同一套地址校验与类型转换。
    public func object(labeled label: String) throws -> AnyObject {
        guard let index = items.firstIndex(where: { $0.label == label }) else {
            throw EvalError(kind: .argument, message: "缺少标签为 \(label) 的实参")
        }
        return try object(at: index)
    }
}

// MARK: - 根变量与手动注册方法

/// 手动注册方法的处理闭包：接收按源码顺序求值、保留外部标签的实参，返回 `EvalReturn`。
/// 用 `EvalReturn` 而不是 `Any?`，是为了保留本库一贯的 `.void` / `.value(nil)` 区分；
/// 一般调用 `SwiftEval.register(method:)` / `register(voidMethod:)` 即可，无需手写此类型。
public typealias SwiftEvalMethodHandler = (EvalArguments) throws -> EvalReturn

/// 保存两类「由调用方显式提供」的入口：
/// - 根变量：把已存在的对象暴露成表达式里的裸标识符；
/// - 手动注册方法：把任意闭包暴露成 `name(args)` 形式的调用。
/// 两者都优先于 Mach-O / ObjC runtime 的自动发现，且都不要求目标类型被导出或保留符号。
/// 自动发现的方法调用仍统一走 SwiftMachOInvoker / ObjectiveCEvalBridge，不经过这里。
public final class SwiftEvalRegistry {

    /// 默认全局注册表；`SwiftEval.registry` 直接返回此实例。
    public static let shared = SwiftEvalRegistry()

    private let lock = NSLock()
    private var roots: [String: () throws -> Any?] = [:]
    /// 方法名按原样保存、精确匹配，不做 `key()` 的模块前缀归一化：
    /// 方法不是类型，`Module.foo()` 不应误命中注册为 `foo` 的方法。
    private var methods: [String: SwiftEvalMethodHandler] = [:]

    /// 创建独立注册表，便于测试或多套调试入口隔离根变量与注册方法。
    public init() {}

    /// 额外尝试的模块前缀，用于「Swift 类名带模块前缀」的短名查找。
    /// 额外的 Swift 模块名前缀。短类名查询会依次组合这些前缀来调用 `NSClassFromString`。
    public var moduleNames: [String] = []

    /// 注册根变量，例如 `SwiftEval.register(root: "app") { UIApplication.shared }`。
    public func register(root name: String, _ getter: @escaping () throws -> Any?) {
        lock.lock()
        roots[Self.key(name)] = getter
        lock.unlock()
    }

    /// 注册常驻单例根变量（工具会持有它）。
    public func register(root name: String, object: AnyObject) {
        register(root: name) { object }
    }

    /// 查找并执行根变量 getter；未注册返回 `nil`，getter 自己抛出的错误原样向上传播。
    public func root(named name: String) throws -> Any? {
        lock.lock()
        let getter = roots[Self.key(name)]
        lock.unlock()
        guard let getter = getter else { return nil }
        return try getter()
    }

    /// 判断标准化后的名称是否存在，不执行 getter，因此不会产生业务副作用。
    public func hasRoot(named name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return roots[Self.key(name)] != nil
    }

    /// 返回已注册短名称的排序快照，供目录页展示；不会泄露闭包或对象本身。
    public func registeredRoots() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return roots.keys.sorted()
    }

    // MARK: - 手动注册方法

    /// 注册（或同名覆盖）一个可由表达式 `name(args)` 调用的方法。
    /// 同名重复注册以最后一次为准，便于调试期间热替换闭包，无需先注销。
    /// - Parameters:
    ///   - name: 方法名，必须是词法器可识别的单个标识符（字母/下划线开头，可含数字）；
    ///           按原样精确匹配，不写模块前缀。与类型名同名时注册方法优先。
    ///   - handler: 求值到该表达式时才执行的闭包；实参已按源码顺序求值并保留标签。
    ///              闭包可 `throw EvalError` 向调试页返回可读错误，其它 Error 由求值器包装。
    public func register(method name: String, _ handler: @escaping SwiftEvalMethodHandler) {
        lock.lock()
        methods[name] = handler
        lock.unlock()
    }

    /// 注销已注册方法；未注册的名字是空操作。
    public func unregister(method name: String) {
        lock.lock()
        methods.removeValue(forKey: name)
        lock.unlock()
    }

    /// 取出处理闭包但**不执行**它：闭包必须在锁外调用，否则闭包内再次注册/求值会与
    /// 同一把非递归 `NSLock` 死锁。返回 nil 表示未注册，由求值器继续查类型构造入口。
    public func method(named name: String) -> SwiftEvalMethodHandler? {
        lock.lock()
        defer { lock.unlock() }
        return methods[name]
    }

    /// 只判断名字是否存在，不执行闭包，避免目录查询产生业务副作用。
    public func hasMethod(named name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return methods[name] != nil
    }

    /// 已注册方法名的排序快照，供 `/api/catalog` 与调试页提示；不泄露闭包本身。
    public func registeredMethods() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return methods.keys.sorted()
    }

    /// 仅供自检 / 热重载使用；同时清空根变量与注册方法，避免两套入口残留不一致。
    public func clear() {
        lock.lock()
        roots.removeAll()
        methods.removeAll()
        lock.unlock()
    }

    /// 类型名统一按最后一段比对，兼容 `Sawa.MemoryGraphScanner` 与 `MemoryGraphScanner`。
    static func key(_ name: String) -> String {
        name.split(separator: ".").last.map(String.init) ?? name
    }
}

// MARK: - ObjC 运行时零注册分派

/// 对 `@objcMembers` / `@objc` 暴露的 NSObject 子类，直接从运行时找类方法并调用，无需注册。
///
/// 对象与整数、浮点、Bool 标量通过 NSInvocation 按真实 ObjC type encoding 调用。
/// 结构体、union、block 和裸指针仍明确拒绝，避免错误 ABI 静默破坏内存。
enum ObjectiveCEvalBridge {

    /// 地址先由 ObjC 层以 mach_vm_read 校验，再构造非持有引用；调用期间 Swift 局部变量
    /// 会保持对象存活。地址若来自已释放对象，校验只能拒绝已失效的 isa，无法消除并发释放竞态。
    static func object(at address: UInt) throws -> (value: AnyObject, typeName: String) {
        let info: [String: Any]
        do {
            // 先用 mach_vm_read 校验地址仍属当前 runtime 类表，避免把野指针当对象。
            info = try SEMachOSymbolResolver.objectInfo(atAddress: address)
        } catch {
            throw EvalError(kind: .argument,
                            message: "对象地址 0x\(String(address, radix: 16)) 无效：\(error.localizedDescription)",
                            suggestion: "请传入当前进程内仍存活的 Swift/ObjC 类实例地址")
        }
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else {
            throw EvalError(kind: .argument, message: "对象地址不能为 0")
        }
        // 由裸指针构造非持有引用；调用期间由上层 Swift 局部变量保持对象存活。
        let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
        // 优先用符号表解析出的类名，缺失时退化为 Swift 反射类型名。
        let typeName = info["className"] as? String ?? EvalValue.shortTypeName(of: object)
        return (object, typeName)
    }

    /// 依次按全名、短名、配置模块前缀和 runtime 类表查找类；多候选短名不猜测，返回 nil 促使调用方给全名。
    static func findClass(named name: String) -> AnyClass? {
        // 先按完整名 / 短名查 ObjC runtime 名字表。
        if let cls = NSClassFromString(name) { return cls }
        let short = SwiftEvalRegistry.key(name)
        if short != name, let cls = NSClassFromString(short) { return cls }
        // 主可执行名常作为纯 Swift 类的模块前缀；额外模块由调用方配置。
        let executable = Bundle.main.object(forInfoDictionaryKey: kCFBundleExecutableKey as String) as? String
        let prefixes = SwiftEvalRegistry.shared.moduleNames + [executable].compactMap { $0 }
        for prefix in prefixes where !prefix.isEmpty {
            // 依次组合各模块前缀拼成「Module.Short」再查一次。
            if let cls = NSClassFromString("\(prefix).\(short)") { return cls }
        }
        // 短类名兜底：在 runtime 类表里按「模块名.」之后的最后一段精确匹配。
        // 例如用户输入 `RoomViewController`，而 runtime 里只注册为 `SawaLudoCommon.RoomViewController`，
        // 纯 Swift 类在 NSClassFromString("短名") 恒为 nil，这里补上这层解析。
        if let cls = classByShortName(short) { return cls }
        // 更宽松的尾串兜底，覆盖早期 mangled 前缀（_TtC...）等非常规命名。
        return uniqueClass(matchingSuffix: short)
    }

    /// 短类名兜底：用户输入不带模块前缀的类名（如 `RoomViewController`）时，
    /// 在 runtime 类表里按「最后一段」精确匹配（`Module.RoomViewController` 的最后一段正是
    /// `RoomViewController`）。纯 Swift 类只在类表里以 `Module.Class` 形式出现，
    /// `NSClassFromString("短名")` 恒为 nil，这里补上这层解析。
    /// 同一短名跨多个模块出现时，优先选 Mach-O 符号表里能解析到类型元数据的那一个；
    /// 仍不唯一则视为歧义返回 nil，由调用方提示写完整 Module.Class。
    /// 类表按裸字读取，避免把未 realize 的类当 AnyClass 下标访问触发消息转发（iOS 上会崩）。
    private static func classByShortName(_ short: String) -> AnyClass? {
        var count: UInt32 = 0
        guard let list = objc_copyClassList(&count) else { return nil }
        // macOS 上返回 AutoreleasingUnsafeMutablePointer、iOS 上返回裸指针；
        // 两者都是单指针大小的 trivial 值，统一按地址取出后再逐字读，不做 AnyClass 下标访问。
        let base = UnsafeRawPointer(list)
        defer { free(UnsafeMutableRawPointer(mutating: base)) }
        let raw = base.assumingMemoryBound(to: UInt.self)
        var candidates: [AnyClass] = []
        for index in 0..<Int(count) {
            let word = raw.advanced(by: index).pointee
            guard word > 0x1000, word & 7 == 0 else { continue }
            let cls: AnyClass = unsafeBitCast(word, to: AnyClass.self)
            let fullName = String(cString: class_getName(cls))
            let last = fullName.components(separatedBy: ".").last ?? fullName
            if last == short { candidates.append(cls) }
        }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates.first }
        // 歧义：优先选 Mach-O 符号表里存在类型元数据的那个（更能沿继承链列出 Swift 成员）。
        let resolvable = candidates.filter {
            SwiftMachOInvoker.hasType(named: String(cString: class_getName($0)))
        }
        return resolvable.first ?? nil
    }

    /// 极宽松尾串兜底：覆盖早期 mangled 前缀（`_TtC18DebugHelperManager19...`）等非常规命名。
    /// 类表按裸字读取，避免把未 realize 的类当 AnyClass 下标访问触发消息转发（iOS 上会崩）。
    private static func uniqueClass(matchingSuffix suffix: String) -> AnyClass? {
        var count: UInt32 = 0
        guard let list = objc_copyClassList(&count) else { return nil }
        // macOS 上返回 AutoreleasingUnsafeMutablePointer、iOS 上返回裸指针；
        // 两者都是单指针大小的 trivial 值，统一按地址取出后再逐字读，不做 AnyClass 下标访问。
        let base = UnsafeRawPointer(list)
        defer { free(UnsafeMutableRawPointer(mutating: base)) }
        let raw = base.assumingMemoryBound(to: UInt.self)
        var matched: UInt?
        for index in 0..<Int(count) {
            let word = raw.advanced(by: index).pointee
            guard word > 0x1000, word & 7 == 0 else { continue }
            let cls: AnyClass = unsafeBitCast(word, to: AnyClass.self)
            let name = String(cString: class_getName(cls))
            guard name.hasSuffix(suffix) else { continue }
            // 多个类同名后缀时不猜，要求用户写完整类名
            if matched != nil, matched != word { return nil }
            matched = word
        }
        return matched.map { unsafeBitCast($0, to: AnyClass.self) }
    }

    /// 类方法调用；找不到匹配的 selector 时返回 nil，交给求值器继续查 Swift Mach-O 符号。
    static func callClassMethod(cls: AnyClass, name: String, labels: [String],
                                arguments: [EvalArguments.Item]) throws -> EvalReturn? {
        guard let metaClass = object_getClass(cls) else { return nil }
        // AnyClass 不是可安全重解释为 AnyObject 的内存布局；直接 bitcast 会令 ARC 尝试
        // retain 错误地址。通过 as AnyObject 取得 Objective-C 的类对象后再交给 NSInvocation。
        return try call(target: cls as AnyObject, methodsIn: metaClass,
                        name: name, labels: labels, arguments: arguments)
    }

    /// 在对象实际 isa（含 KVO/Aspects 动态子类）及其父类链中查找并调用匹配的 ObjC 实例方法。
    static func callInstanceMethod(object: AnyObject, name: String, labels: [String],
                                   arguments: [EvalArguments.Item]) throws -> EvalReturn? {
        guard let cls = object_getClass(object) else { return nil }
        return try call(target: object, methodsIn: cls,
                        name: name, labels: labels, arguments: arguments)
    }

    /// Aspects / KVO 会把对象的 isa 指向动态子类。Swift 符号仍归属于原始类，
    /// 因此 Mach-O 分派需要按 runtime 继承链逐级尝试类型名。
    static func runtimeTypeNames(of object: AnyObject) -> [String] {
        var result: [String] = []
        var currentClass = object_getClass(object)
        while let cls = currentClass {
            result.append(String(cString: class_getName(cls)))
            currentClass = class_getSuperclass(cls)
        }
        return result
    }

    /// 将已装箱参数按 selector 编码转换后交给 NSInvocation；对象地址只有目标参数是对象时才解引用，
    /// 因而不会把普通整数地址错误转换为对象。未找到方法返回 nil，与“调用返回 nil”由 EvalReturn 区分。
    private static func call(target: AnyObject, methodsIn cls: AnyClass, name: String,
                             labels: [String], arguments: [EvalArguments.Item]) throws -> EvalReturn? {
        guard let method = findMethod(in: cls, name: name, labels: labels, argumentCount: arguments.count) else {
            return nil
        }
        let selector = method_getName(method)
        let values: [Any] = try arguments.enumerated().map { index, item in
            // 仅当目标参数确为对象/Class 时，才把地址参数解引用为对象，避免把整数地址误当对象。
            if case .address(let address) = item.value,
               methodExpectsObject(method, argumentIndex: index) {
                return try object(at: address).value
            }
            // 其余按 EvalValue 规则装箱成 NSInvocation 可接收的对象参数。
            return item.value.objcObject ?? NSNull()
        }
        do {
            // 交给 ObjC 层完成 NSInvocation 调用，并按 isVoid 区分无返回值与返回 nil。
            let output = try SEMachOSymbolResolver.invokeObjectiveCTarget(
                target, selectorName: NSStringFromSelector(selector), arguments: values)
            if (output["isVoid"] as? Bool) == true { return .void }
            let value = output["value"]
            return .value(value is NSNull ? nil : value)
        } catch {
            throw EvalError(kind: .unsupported, message: "ObjC 方法 \(name) 调用失败：\(error.localizedDescription)")
        }
    }

    /// 仅供 ObjC alloc/init 兜底使用；普通 ObjC 方法统一走 NSInvocation。
    private static func impPointer(_ imp: IMP) -> UnsafeRawPointer {
        unsafeBitCast(imp, to: UnsafeRawPointer.self)
    }

    /// 为固定四参 C 函数签名补齐可选对象位；超过四个参数的 alloc/init 兜底不会走此路径。
    private static func argument(_ objects: [AnyObject?], _ index: Int) -> AnyObject? {
        index < objects.count ? objects[index] : nil
    }

    /// 仅用于 `alloc`/`init` 的小型 IMP 直调。普通方法使用 NSInvocation，以避开多参数和非对象 ABI 风险。
    private static func invokeObject(_ imp: IMP, target: AnyObject, selector: Selector,
                                     objects: [AnyObject?]) -> AnyObject? {
        typealias Function = @convention(c) (AnyObject?, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> AnyObject?
        let function = unsafeBitCast(impPointer(imp), to: Function.self)
        return function(target, selector, argument(objects, 0), argument(objects, 1),
                        argument(objects, 2), argument(objects, 3))
    }

    /// 沿继承链查找参数数、名称和标签均兼容的 ObjC Method；精确 selector 优先，多个宽松候选视为歧义。
    private static func findMethod(in cls: AnyClass, name: String, labels: [String],
                                   argumentCount: Int) -> Method? {
        // class_copyMethodList 只返回当前类直接声明的方法。Aspects / KVO 生成的动态
        // 子类通常不复制原类方法，因此必须逐级查询 superclass；按层返回可保持 ObjC
        // 的 override 优先级，不能把父类同名实现提前选中。
        var currentClass: AnyClass? = cls
        while let candidateClass = currentClass {
            var count: UInt32 = 0
            if let list = class_copyMethodList(candidateClass, &count) {
                defer { free(list) }
                var fallback: Method?
                var hasAmbiguousFallback = false
                for index in 0..<Int(count) {
                    let method = list.advanced(by: index).pointee
                    let selector = NSStringFromSelector(method_getName(method))
                    guard method_getNumberOfArguments(method) - 2 == argumentCount else { continue }
                    guard matches(selector: selector, base: name, labels: labels) else { continue }
                    if isExact(selector: selector, base: name, labels: labels) { return method }
                    if fallback != nil {
                        hasAmbiguousFallback = true
                    } else {
                        fallback = method
                    }
                }
                if hasAmbiguousFallback { return nil }
                if let fallback = fallback { return fallback }
            }
            currentClass = class_getSuperclass(candidateClass)
        }
        return nil
    }

    /// selector 片段拼起来忽略大小写应与「方法名 + 参数标签」一致；Swift 自动生成的
    /// selector 常把首个标签拼成 `With<Label>`，因此再比较一次去掉 with 的版本。
    private static func matches(selector: String, base: String, labels: [String]) -> Bool {
        // 参数个数已由 method_getNumberOfArguments 校验，这里只比对「方法名 + 标签」
        let parts = selector.split(separator: ":").map(String.init)
        let joined = parts.joined().lowercased()
        let bare = base.lowercased()
        guard joined.hasPrefix(bare) else { return false }
        let expected = bare + effectiveObjectiveCLabels(labels).joined().lowercased()
        return stripWith(joined) == stripWith(expected)
    }

    /// 判断 selector 是否与调用点拼出的标签完全一致，用于在宽松匹配候选中保持重载选择确定性。
    private static func isExact(selector: String, base: String, labels: [String]) -> Bool {
        let parts = selector.split(separator: ":").map(String.init)
        let bare = base.lowercased()
        let expected = bare + effectiveObjectiveCLabels(labels).joined().lowercased()
        return parts.joined().lowercased() == expected
    }

    /// 去掉 Swift 位置参数占位 `_`，得到参与 ObjC selector 拼接的真实外部标签。
    private static func effectiveObjectiveCLabels(_ labels: [String]) -> [String] {
        labels.filter { !$0.isEmpty && $0 != "_" }
    }

    /// 读取第 N 个显式参数的 ObjC encoding，并跳过修饰符后判断是否为对象/Class，决定地址参数能否解引用。
    private static func methodExpectsObject(_ method: Method, argumentIndex: Int) -> Bool {
        guard let rawType = method_copyArgumentType(method, UInt32(argumentIndex + 2)) else {
            return false
        }
        defer { free(rawType) }
        var type = UnsafePointer(rawType)
        let qualifiers: Set<CChar> = [114, 110, 78, 111, 79, 82, 86]
        while qualifiers.contains(type.pointee) {
            type = type.advanced(by: 1)
        }
        return type.pointee == 64 || type.pointee == 35 // '@' / '#'
    }

    /// 移除 Swift→ObjC 自动 selector 中常见的 `With` 连接词，使调用点标签可与原生 ObjC selector 对齐。
    private static func stripWith(_ text: String) -> String {
        text.replacingOccurrences(of: "with", with: "")
    }

    /// `Type()` 构造 NSObject 子类实例，供实例方法链式调用。
    static func instantiate(cls: AnyClass) throws -> Any? {
        // 交给 Swift 的构造器调用，ARC 才能正确处理 alloc/init 的 +1 返回语义
        if let type = cls as? NSObject.Type {
            return type.init()
        }
        let alloc = NSSelectorFromString("alloc")
        let initialize = NSSelectorFromString("init")
        guard let allocMethod = class_getClassMethod(cls, alloc),
              let initMethod = class_getInstanceMethod(cls, initialize) else { return nil }
        // 分两次 IMP 直调完成 alloc，再在创建出的对象上完成 init。
        let created = invokeObject(method_getImplementation(allocMethod),
                                   // 与类方法分派相同，必须走正常桥接，不能把 metatype bitcast 为对象。
                                   target: cls as AnyObject,
                                   selector: alloc, objects: [])
        guard let created = created else { return nil }
        return invokeObject(method_getImplementation(initMethod), target: created,
                            selector: initialize, objects: [])
    }

    /// 沿实际 isa 的继承链判断目标是否是「ObjC runtime 明确声明的 @property」。
    /// class_getProperty 只查当前类直接声明的属性，UIViewController.view 这类父类属性必须逐级上溯；
    /// 从 object_getClass 出发也覆盖 KVO/Aspects 动态子类。普通零参数方法（如 reload）没有
    /// property 元数据，据此可把 KVC 回退限定在真正的属性上，避免把任意方法当 getter 执行。
    static func hasDeclaredProperty(object: AnyObject, named name: String) -> Bool {
        var currentClass: AnyClass? = object_getClass(object)
        while let cls = currentClass {
            if class_getProperty(cls, name) != nil { return true }
            currentClass = class_getSuperclass(cls)
        }
        return false
    }

    /// KVC 读属性；先用 responds(to:) 挡掉不存在的 key，避免 NSUnknownKeyException 终止进程。
    /// 通过 KVC 读取已响应 getter 的 NSObject 属性；只作为兼容回退，计算属性优先走 Swift 符号 getter。
    /// 调用方需先用 hasDeclaredProperty 确认它确实是声明过的 @property，避免误触发普通方法的副作用。
    static func property(object: AnyObject, name: String) -> Any? {
        guard let nsObject = object as? NSObject,
              // 先用 responds(to:) 挡掉不存在的 key，避免 NSUnknownKeyException 终止进程。
              nsObject.responds(to: NSSelectorFromString(name)) else { return nil }
        return nsObject.value(forKey: name)
    }
}
