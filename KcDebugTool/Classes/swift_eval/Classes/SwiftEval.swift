import Foundation

/// 一次 eval 的完整结果。返回值同时保留三种形态：
/// `rawValue` 原始值（可继续参与链式调用 / 由调用方自己处理）、
/// `displayText` 给人看的缩进文本、`jsonObject` 给网页 / 日志用的结构化数据。
public struct EvalResult {

    /// 原始输入去除首尾空白后的表达式；用于让调用方把结果和实际执行内容精确关联。
    public let expression: String
    /// 求值是否完整成功；为 `false` 时请读取 `error`，其余字段仍提供稳定的错误展示结构。
    public let isSuccess: Bool
    /// 区分「调用成功但返回 Void」与「调用成功并返回 Optional.none」。
    public let hasReturnValue: Bool
    /// `rawValue` 被 `EvalValue` 装箱后得到的动态短类型名，失败时固定为 `Error`。
    public let typeName: String
    /// 未序列化的原始 Swift / Objective-C 返回值；仅适合当前进程内继续使用，不可跨进程传输。
    public let rawValue: Any?
    /// 面向日志和调试页的安全、有限深度文本表示。
    public let displayText: String
    /// 面向 JSON 消费者的安全树；对象会被镜像为有限深度的属性树而非直接编码。
    public let jsonObject: Any
    /// 从开始解析到结果装箱的墙钟耗时，单位为秒。
    public let duration: TimeInterval
    /// 语法、查找、参数或 ABI 调用错误；`isSuccess == true` 时为 `nil`。
    public let error: EvalError?

    /// 将结果统一投影为 HTTP/日志可使用的字典，并把秒级耗时转换为毫秒。
    public var dictionary: [String: Any] {
        var result: [String: Any] = [
            "expression": expression,
            "ok": isSuccess,
            "hasReturnValue": hasReturnValue,
            "type": typeName,
            "display": displayText,
            "value": jsonObject,
            "durationMs": Int(duration * 1000)
        ]
        if let error = error {
            result["error"] = error.description
            result["errorKind"] = error.kind.rawValue
            result["suggestion"] = error.suggestion ?? NSNull()
        }
        return result
    }

    /// 序列化 `dictionary`；异常对象等不可 JSON 化内容已在 `EvalValue` 阶段降级处理。
    public func jsonData() -> Data {
        if let data = try? JSONSerialization.data(withJSONObject: dictionary,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            return data
        }
        return Data(#"{"ok":false,"error":"结果无法序列化"}"#.utf8)
    }

    /// `jsonData()` 的 UTF-8 便捷形式；极端编码失败时返回固定错误 JSON，保证 HTTP 响应可写出。
    public func jsonString() -> String {
        String(data: jsonData(), encoding: .utf8) ?? "{\"ok\":false}"
    }
}

/// 运行时受限 Swift 表达式求值（调试工具）。
///
/// ## 全部功能、表达式场景与原理
///
/// iOS 不允许在进程内 JIT 编译任意 Swift 源码，因此本工具是**受限解释器**而非通用 `eval`：
/// 词法器先把字符拆为 token，语法器只接受标识符、成员访问、构造、字面量、数组/字典和分号
/// 程序，再生成 AST；解释器按从左到右顺序逐节点求值。每个中间结果始终保留原始 Swift 值，
/// 直到最终 `EvalValue` 展示/JSON 化，故 `a.make().next()` 不会因中途转字符串丢失对象类型。
///
/// ### 可写的表达式与实际路径
///
/// - `root`：先查 `register(root:_:)` 注册表；getter 在每次引用时才执行。未注册时才将 root
///   当作类型名查找，因此根变量可覆盖同名类型。
/// - `name(args)`（手动注册方法）：用 `register(method:_:)` / `register(voidMethod:_:)` 暴露
///   任意闭包，是自动发现之外的显式入口，不要求符号可见或 `@objc`。语法层与 `Type(...)`
///   同为 construct 节点，故**优先于**同名类型构造；实参按源码顺序求值并保留外部标签，
///   闭包通过 `EvalArguments` 取标量 / 标签参数 / 原始值 / `0x...` 还原后的对象。注册方法是
///   全局入口而非类型或实例成员，写成 `obj.name()` 或省略括号都无效（错误里会给出提示）。
///   带括号调用时 `register(method:)` 的 `nil` 是 `.value(nil)`，`register(voidMethod:)`
///   才是 `.void`，与自动发现方法一致。
/// - `Module.Type` / `Type`：依次查完整 ObjC runtime 类名、短名、`moduleNames`、主模块前缀、
///   runtime 类表短名，以及 Swift metadata。短名在多个模块不唯一时拒绝猜测。
/// - `Type()` / `Type(arg:)`：若无同名注册方法，NSObject 类无参构造优先走 `init`；纯 Swift
///   类型从 Mach-O 符号找唯一初始化器。无参调用还会尝试编译器生成的默认参数 thunk；
///   找不到或不唯一即报错。
/// - `Type.method(arg:)`：先以 ObjC 元类 selector 查类方法，再以 Swift Mach-O 符号查
///   `static`/`class` 方法。ObjC 使用 `NSInvocation` 和真实 type encoding；Swift 使用 demangle
///   后的标签、参数数和类型 metadata 匹配，调用 arm64 ABI 调用桩。
/// - `object.method(arg:)` / `0x140df8e00.method(arg:)`：对象地址先用 `mach_vm_read` 和 isa
///   校验其仍是当前 runtime 已知类，才创建**非持有**引用；随后先沿实际 isa（含 KVO/Aspects
///   动态子类）调用 ObjC selector，找不到再沿该继承链对应的 Swift 符号调用实例方法。地址已
///   释放或正被并发释放时不能保证安全，应只传入当前仍被业务强持有的对象。
/// - `0x140df8e00.item`（存储属性）：地址解析后先识别内置属性；再通过 `Mirror` 遍历该对象与
///   父类的存储字段，字段读取不调用 getter。lazy 属性的 `$__lazy_storage_$_item` 会还原为
///   `item` 并解开 Optional 存储包装。字段不存在时才继续走计算属性路径。
/// - `0x140df8e00.computeValue`（Swift 计算属性）：`Mirror` 看不到它，解释器从对应类型的
///   Mach-O 中寻找 `.getter` 符号，确认零参数且返回布局可直接取得后，以对象地址作 Swift self
///   上下文执行 getter。它**会执行业务 getter**，可能有副作用；符号被 Strip、重载歧义、
///   返回值需要间接缓冲区或 ABI 不受支持时会拒绝调用而不是猜测。
/// - `0x140df8e00.item`（ObjC 声明的 @property）：Mirror 与 Swift 符号都找不到时，例如
///   `UIViewController.view`，才按 runtime 继承链确认它是声明过的 @property 后走 KVC
///   `value(forKey:)`。**会执行 getter**（访问 view 会触发 view 加载）；普通零参数方法没有
///   property 元数据，不会被当成属性 getter 执行。
/// - `object.item()`：带括号一律按方法处理；对 NSObject/@objc 成员通过 selector 调用，因此
///   ObjC 的普通零参数方法（含未声明为 @property 的 getter）必须写为 `item()`。无括号形式
///   只按上述规则读取声明属性，避免任意方法的副作用被误触发。
/// - `value.typeName`、`.description`、`.debugDescription`、`.json`、`.fields`，以及集合的
///   `.count` / `.isEmpty`：是解释器虚拟属性，不访问业务成员；其中 fields/json 仍受展示预算
///   和环检测限制。`Type.typeName`、`Type.members` 是对应的类型虚拟属性。
/// - `[1, "x"]` / `["key": 1]`：集合仅允许字面量及嵌套字面量，不允许在容器中嵌入方法调用；
///   `true`、`false`、`nil`、整数、浮点、字符串和 `0x...` 都会保留对应 `EvalValue` 语义。
/// - `a.b().c; d`：分号按顺序运行多条表达式，最终结果为最后一条；任意步骤返回 Void 后继续
///   取成员会报错，接收者为 nil 则采用安全链语义，后续访问继续返回 nil。
///
/// ### ABI、安全与结果边界
///
/// 原生 Swift 路径扫描当前进程已加载 Mach-O 的 Swift 函数符号，调用 `swift_demangle` 还原
/// 声明，再把标量/对象写入 arm64 的 x0...x7、d0...d7，并把 self/metatype 写入 x20。返回只
/// 支持 Void、基础标量、对象和可确认不超过三个机器字的直接返回值；结构体、union、裸指针、
/// block、未知泛型布局和间接返回一律拒绝，避免错误 ABI 破坏内存。ObjC 路径同样拒绝不安全
/// 参数布局，并由 `NSInvocation` 根据 encoding 负责标量宽度和返回装箱。
///
/// 类型详情由 ObjC runtime、Swift 符号、`__swift5_fieldmd` 所有权元数据与 `Mirror` 合并，
/// 不实例化目标。最终展示递归限制深度和每层数量，以对象身份检测循环引用；HTTP 服务只是将
/// evaluate/catalog/describe 暴露为局域网单线程入口，缺少认证和资源隔离，只可在 DEBUG 与受信任
/// 网络使用，绝不可暴露公网。
///
/// 仅建议 DEBUG 包接入；HTTP 入口不要暴露到公网。
public enum SwiftEval {

    /// 全局根变量注册表；表达式中的裸标识符会优先在这里解析。
    public static var registry: SwiftEvalRegistry { SwiftEvalRegistry.shared }

    /// 返回值展示的最大深度 / 元素数，扫描类方法返回大数组时可调小。
    public static var maxDepth: Int {
        get { EvalValue.maxDepth }
        set { EvalValue.maxDepth = newValue }
    }

    /// 单层集合/属性树最多输出的元素数；限制只影响展示，不影响被调用方法本身。
    public static var maxItems: Int {
        get { EvalValue.maxItems }
        set { EvalValue.maxItems = newValue }
    }

    /// 很多调试类方法会碰 UI / 单例状态，默认在当前线程执行；
    /// 置 true 后 HTTP 请求会在主线程同步求值（调用方需避免主线程长时间阻塞）。
    public static var dispatchOnMainThread: Bool = true

    /// 求值入口：`maxDepth` 仅影响本次结果展示，范围会被约束到 1...10。
    /// 不抛错，语法 / 查找 / 调用失败都写进 `EvalResult.error`。
    public static func evaluate(_ source: String, maxDepth: Int? = nil) -> EvalResult {
        let outputDepth = min(max(maxDepth ?? EvalValue.maxDepth, 1),
                              EvalValue.maximumDisplayDepth)
        if dispatchOnMainThread, !Thread.isMainThread {
            // 非主线程调用时同步切回主线程求值，避免触碰 UIKit 等主线程约束的元数据。
            var result: EvalResult?
            DispatchQueue.main.sync { result = evaluateOnCurrentThread(source, maxDepth: outputDepth) }
            if let result = result { return result }
        }
        return evaluateOnCurrentThread(source, maxDepth: outputDepth)
    }

    /// 需要错误语义时用这个版本。
    public static func evaluateThrowing(_ source: String) throws -> EvalResult {
        // 复用普通求值；若结果带错误则按错误语义抛出，让上层用 do/catch 处理。
        let result = evaluate(source)
        if let error = result.error { throw error }
        return result
    }

    /// 直接拿 JSON 字符串，供 HTTP / 日志一行输出。
    public static func evaluateJSON(_ source: String) -> String {
        evaluate(source).jsonString()
    }

    // MARK: - 可选根变量

    /// 注册惰性根变量。每次表达式引用该名称都会执行 getter，因此可暴露当前页面等动态对象。
    public static func register(root name: String, _ getter: @escaping () throws -> Any?) {
        registry.register(root: name, getter)
    }

    /// 注册固定对象根变量；闭包会强持有对象，适合单例，不适合需自动释放的页面实例。
    public static func register(root name: String, object: AnyObject) {
        registry.register(root: name, object: object)
    }

    // MARK: - 手动注册方法

    /// 注册一个可由表达式 `name(args)` 调用的方法（有返回值版）。
    ///
    /// 这是 Mach-O / ObjC runtime 自动发现之外的显式入口：闭包里可以写任意调试逻辑，
    /// 不要求目标类型导出符号、不要求 `@objc`，也不需要实例化对象。典型用法是暴露
    /// 一段运行时检查、开关切换或数据导出动作给调试页：
    ///
    /// ```swift
    /// SwiftEval.register(method: "add") { args in
    ///     try args.int(at: 0) + args.int(labeled: "to")
    /// }
    /// // 表达式：add(1, to: 2)
    ///
    /// SwiftEval.register(method: "inspect") { args in
    ///     let object = try args.object(labeled: "target")  // 支持 0x... 地址与根变量
    ///     return String(describing: object)
    /// }
    /// // 表达式：inspect(target: 0x10481a800) / inspect(target: currentVC)
    /// ```
    ///
    /// - 参数按源码顺序求值，保留外部标签；可用 `EvalArguments` 的下标 / 标签取参、
    ///   类型转换（`int/string/bool/double/array/dictionary`）、`raw`/`cast` 取原始值，
    ///   以及 `object(at:)` / `object(labeled:)` 把 `0x...` 地址经 isa 校验还原成真实对象。
    /// - 返回 `nil` 会装箱成 `.value(nil)`（有返回值但为 Optional.none）；若要表达
    ///   「没有返回值」请用 `register(voidMethod:_:)`，二者在 `hasReturnValue` 上不同。
    /// - 闭包可 `throw EvalError` 向调试页返回结构化错误；其它 Error 会被包装成
    ///   `.invocation` 并附带方法名与调用位置。
    /// - 闭包在表达式求值线程执行，因此同样受 `dispatchOnMainThread` 约束；
    ///   需要操作 UI 时保持默认主线程派发即可。
    /// - `name` 必须是表达式可写的单个标识符（不带模块前缀、不含点）；同名重复注册
    ///   以最后一次为准。注册方法与类型同名时，`name(args)` 优先命中注册方法。
    public static func register(method name: String,
                                _ handler: @escaping (EvalArguments) throws -> Any?) {
        // 统一转成 EvalReturn，让注册表只存一种闭包类型；.value(nil) 保留「有返回值」语义。
        registry.register(method: name) { arguments in
            let value = try handler(arguments)
            return .value(value)
        }
    }

    /// 注册一个无返回值的手动方法，表达式结果 `hasReturnValue == false`（与 void 方法一致）。
    /// 参数取用与 `register(method:_:)` 完全相同；适用于重置、清缓存、触发刷新等副作用命令。
    ///
    /// ```swift
    /// SwiftEval.register(voidMethod: "setFlag") { args in
    ///     DebugFlags.verbose = try args.bool(labeled: "enabled")
    /// }
    /// // 表达式：setFlag(enabled: true)
    /// ```
    public static func register(voidMethod name: String,
                                _ handler: @escaping (EvalArguments) throws -> Void) {
        registry.register(method: name) { arguments in
            try handler(arguments)
            return .void
        }
    }

    /// 注销已注册的手动方法；未注册的名字是空操作。注销后同名类型构造恢复可用。
    public static func unregister(method name: String) {
        registry.unregister(method: name)
    }

    /// 已注册方法名的排序快照，不会执行任何闭包。
    public static func registeredMethods() -> [String] {
        registry.registeredMethods()
    }

    /// 已发现的类型 / 成员、可选根变量与手动注册方法清单，调试页用它做提示。
    /// 返回 `types`（类型→成员）、`roots`（根变量名）、`methods`（注册方法名）三段。
    public static func catalog() -> [String: Any] {
        // 汇总自动发现的类型、根变量与显式注册方法，供调试页做自动提示。
        let types: [String: Any] = SwiftMachOInvoker.catalog()
        return ["types": types,
                "roots": registry.registeredRoots(),
                "methods": registry.registeredMethods()]
    }

    // MARK: - 求值

    /// 当前线程实际执行的完整流水线：裁剪输入→词法/语法→顺序解释→按预算装箱结果；所有错误收敛为结果。
    private static func evaluateOnCurrentThread(_ source: String, maxDepth: Int) -> EvalResult {
        let start = Date()
        let expression = source.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // 词法 + 语法生成 AST（前者已校验语法错误）。
            var parser = try EvalParser(source: expression)
            let program = try parser.parseProgram()
            guard !program.isEmpty else {
                throw EvalError(kind: .syntax, message: "表达式为空")
            }
            // 按分号分隔的多条表达式顺序解释，最终结果取最后一条。
            var box = EvalBox.void
            for node in program { box = try interpret(node) }
            return makeResult(expression: expression, box: box, start: start,
                              maxDepth: maxDepth, error: nil)
        } catch let error as EvalError {
            return makeResult(expression: expression, box: .void, start: start,
                              maxDepth: maxDepth, error: error)
        } catch {
            let wrapped = EvalError(kind: .invocation, message: "调用抛出异常：\(error)")
            return makeResult(expression: expression, box: .void, start: start,
                              maxDepth: maxDepth, error: wrapped)
        }
    }

    /// 求值器内部值：`.type` 表示「类型对象」（下一步走类方法），
    /// `.value` 表示实例 / 字面量 / 返回值，`.void` 表示上一步没有返回值。
    private enum EvalBox {
        case type(String)
        case value(Any?)
        case void
    }

    /// 递归解释 AST。只有此处会把语法标识符解析为运行时类型、根变量或真实成员调用。
    private static func interpret(_ node: EvalNode) throws -> EvalBox {
        switch node {
        case .literal(let value, _):
            return .value(value.anyValue)
        case .identifier(let name, let offset):
            return try resolveRoot(name, offset: offset)
        case .construct(let name, let arguments, let offset):
            return try construct(name, arguments: arguments, offset: offset)
        case .assignment(let target, let source, let offset):
            guard case .member(let base, let name, isCall: false, _, _) = target else {
                throw EvalError(kind: .syntax, message: "第 \(offset) 个字符：赋值目标必须是实例属性")
            }
            // 先求接收者，再求右值；目标不提供 setter 时不会对 Mirror 字段直接写内存。
            let receiver = try interpret(base)
            let assigned = try interpret(source)
            guard case .value(let raw) = assigned else {
                throw EvalError(kind: .argument, message: "第 \(offset) 个字符：赋值右侧必须返回值")
            }
            try assign(receiver, property: name, value: raw, offset: offset)
            return .value(raw)
        case .member(let base, let name, let isCall, let arguments, let offset):
            // `Module.Type.member` 的内层节点是 `Module.Type`。只有它确实对应运行时类型时
            // 才折叠成带命名空间的类型，避免把普通对象属性误判为类型名。
            if case .identifier(let namespace, _) = base {
                let qualifiedName = namespace + "." + name
                let isKnownType = SwiftMachOInvoker.hasType(named: qualifiedName) ||
                    ObjectiveCEvalBridge.findClass(named: qualifiedName) != nil
                if isKnownType {
                    if isCall {
                        return try construct(qualifiedName, arguments: arguments, offset: offset)
                    }
                    return .type(qualifiedName)
                }
            }
            let receiver = try interpret(base)
            return try invokeMember(receiver, name: name, isCall: isCall,
                                    arguments: arguments, offset: offset)
        }
    }

    /// 实例属性赋值只走真实 setter；ObjC 通过 selector 的参数编码转换，Swift 通过符号与 ABI 校验。
    private static func assign(_ receiver: EvalBox, property name: String,
                               value: Any?, offset: Int) throws {
        guard case .value(let rawReceiver) = receiver, let rawReceiver = rawReceiver else {
            throw EvalError(kind: .argument, message: "第 \(offset) 个字符：赋值接收者必须是非 nil 实例")
        }
        let object: Any
        if let address = rawReceiver as? EvalObjectAddress {
            object = try ObjectiveCEvalBridge.object(at: address.rawValue).value
        } else {
            object = rawReceiver
        }
        guard Mirror(reflecting: object).displayStyle == .class else {
            throw EvalError(kind: .unsupported, message: "第 \(offset) 个字符：仅支持引用类型实例的属性赋值")
        }
        let item = EvalArguments.Item(label: nil, value: EvalValue(any: value))
        if let nsObject = object as? NSObject,
           ObjectiveCEvalBridge.hasDeclaredProperty(object: nsObject, named: name) {
            let setterName = "set" + name.prefix(1).uppercased() + name.dropFirst()
            if try ObjectiveCEvalBridge.callInstanceMethod(object: nsObject, name: setterName,
                                                         labels: ["_"], arguments: [item]) != nil {
                return
            }
        }
        for typeName in ObjectiveCEvalBridge.runtimeTypeNames(of: object as AnyObject) {
            if try SwiftMachOInvoker.writeInstanceProperty(object: object, typeName: typeName,
                                                          name: name, value: item) {
                return
            }
        }
        throw EvalError(kind: .unsupported,
                        message: "第 \(offset) 个字符：属性 .\(name) 没有可安全调用的 setter")
    }

    /// 将顶层标识符解析为已注册根变量或可发现类型；失败时附带目录快照，便于远程调试纠正输入。
    private static func resolveRoot(_ name: String, offset: Int) throws -> EvalBox {
        // 优先解析为已注册根变量，每次引用都会执行 getter（可暴露当前页面等动态对象）。
        if registry.hasRoot(named: name) {
            return .value(try registry.root(named: name))
        }
        // 再尝试解析为可发现类型（Swift 元数据或 ObjC runtime 类名），作为类型接收者。
        if SwiftMachOInvoker.hasType(named: name) || ObjectiveCEvalBridge.findClass(named: name) != nil {
            return .type(name)
        }
        // 注册方法必须带括号调用；不带括号写名字时给出可操作的提示，而不是笼统的 unknownType。
        if registry.hasMethod(named: name) {
            throw EvalError(kind: .syntax,
                            message: "第 \(offset) 个字符：「\(name)」是手动注册的方法，调用需写成 \(name)(...)")
        }
        // 都找不到时，把已发现类型、根变量与注册方法拼成提示，方便远程调试纠正输入。
        let known = (Array(SwiftMachOInvoker.catalog().keys) + registry.registeredRoots()).sorted()
        var hints: [String] = [known.isEmpty ? "当前没有已发现类型或根变量" : "已知入口：\(known.joined(separator: ", "))"]
        let methods = registry.registeredMethods()
        if !methods.isEmpty {
            hints.append("已注册方法（需加括号）：\(methods.joined(separator: ", "))")
        }
        throw EvalError(kind: .unknownType, message: "第 \(offset) 个字符：找不到类型或根变量「\(name)」",
                        suggestion: hints.joined(separator: "；"))
    }

    /// 执行 `name(...)`：手动注册方法优先，其次 NSObject 的 `init`，最后纯 Swift 类型的 Mach-O 初始化器。
    /// 语法层把顶层 `foo(...)` 与 `Type(...)` 都归为 construct 节点，因此注册方法与类型构造共用此入口；
    /// 显式注册优先于自动发现，也让注册方法名可以与类型同名而不必改名。
    private static func construct(_ name: String, arguments: [EvalCallArgument],
                                  offset: Int) throws -> EvalBox {
        // 先查手动注册方法。method(named:) 只在锁内取闭包、在锁外返回，因此闭包内再次
        // 注册 / 注销 / 调用 evaluate 都不会与注册表锁死锁。
        if let handler = registry.method(named: name) {
            // 复用统一实参求值：按源码顺序解释、保留外部标签并装箱为 EvalArguments，
            // 注册方法因此与自动发现的方法享有完全相同的参数能力（含 0x... 地址实参）。
            let evaluated = try evaluateArguments(arguments)
            do {
                return apply(try handler(evaluated))
            } catch let error as EvalError {
                // 注册方主动抛出的结构化错误原样透传，保留 kind / suggestion 给调试页。
                throw error
            } catch {
                throw EvalError(kind: .invocation,
                                message: "第 \(offset) 个字符：注册方法 \(name) 调用失败：\(error)")
            }
        }
        // 先走 ObjC 构造（alloc/init），这是最安全的路径。
        if let cls = ObjectiveCEvalBridge.findClass(named: name),
           let instance = try ObjectiveCEvalBridge.instantiate(cls: cls) {
            return .value(instance)
        }
        // 纯 Swift 类型：先统一装箱实参，再按 Mach-O 找到的初始化器动态调用。
        let evaluated = try evaluateArguments(arguments)
        if SwiftMachOInvoker.hasType(named: name) {
            return .value(try SwiftMachOInvoker.instantiate(typeName: name, arguments: evaluated.items))
        }
        throw EvalError(kind: .unknownType, message: "第 \(offset) 个字符：\(name) 没有可用的构造入口",
                        suggestion: "需要可从 Mach-O 找到的 Swift 初始化方法、NSObject 的 init，或已注册的同名方法")
    }

    /// 成员调用主分派。类型接收者先查类方法，找不到同名静态入口时，
    /// 会通过 Mach-O 中的初始化方法创建实例再调用——这样 `MemoryGraphScanner.identifyObjects()`
    /// 这种「写成类名调用、实际是实例方法」的表达式也能跑通。
    private static func invokeMember(_ box: EvalBox, name: String, isCall: Bool,
                                     arguments: [EvalCallArgument], offset: Int) throws -> EvalBox {
        let evaluated = try evaluateArguments(arguments)
        switch box {
        case .type(let typeName):
            // 类型接收者走类方法/类型属性分派。
            return try invokeOnType(typeName, name: name, isCall: isCall,
                                    arguments: evaluated, offset: offset)
        case .value(let value):
            // 值接收者走实例属性/实例方法分派。
            return try invokeOnValue(value, name: name, isCall: isCall,
                                     arguments: evaluated, offset: offset)
        case .void:
            throw EvalError(kind: .unknownMember, message: "第 \(offset) 个字符：上一步没有返回值，不能继续调用 .\(name)")
        }
    }

    /// 按源码顺序解释实参并保留标签；顺序保证副作用与普通 Swift 调用一致，结果随后才做目标类型转换。
    private static func evaluateArguments(_ arguments: [EvalCallArgument]) throws -> EvalArguments {
        var items: [EvalArguments.Item] = []
        for argument in arguments {
            let box = try interpret(argument.value)
            let raw: Any?
            switch box {
            case .value(let value): raw = value
            case .type(let name): raw = name
            case .void: raw = nil
            }
            items.append(EvalArguments.Item(label: argument.label, value: EvalValue(any: raw)))
        }
        return EvalArguments(items)
    }

    /// 在类型接收者上分派类方法/静态方法或类型属性：ObjC runtime 优先，随后才尝试 Swift Mach-O 符号。
    private static func invokeOnType(_ typeName: String, name: String, isCall: Bool,
                                     arguments: EvalArguments, offset: Int) throws -> EvalBox {
        if let cls = ObjectiveCEvalBridge.findClass(named: typeName),
           let result = try ObjectiveCEvalBridge.callClassMethod(
            cls: cls, name: name, labels: arguments.labels, arguments: arguments.items) {
            // ObjC 类方法优先走 NSInvocation 分派。
            return apply(result)
        }
        if isCall {
            // 调用形态：尝试 Swift Mach-O 静态/类方法分派。
            if let result = try SwiftMachOInvoker.callTypeMethod(
                typeName: typeName, name: name, labels: arguments.labels, arguments: arguments.items) {
                return apply(result)
            }
        } else {
            // 取属性形态：先读 Swift 类型属性，再退到虚拟类型属性（typeName/members）。
            if let result = try SwiftMachOInvoker.readTypeProperty(typeName: typeName, name: name) {
                return apply(result)
            }
            if let info = typeProperty(typeName, name: name) { return .value(info) }
        }
        throw memberNotFound(typeName: typeName, name: name, offset: offset)
    }

    /// 在值接收者上分派通用属性、Mirror 字段、Swift getter、ObjC selector 和 Swift 实例方法。
    /// 对 nil 采用安全链语义；对对象地址先经 isa 验证后再形成临时非持有引用。
    private static func invokeOnValue(_ value: Any?, name: String, isCall: Bool,
                                      arguments: EvalArguments, offset: Int) throws -> EvalBox {
        guard let value = unwrappedOptional(value) else {
            // 可选链语义：对 nil 取成员不报错，继续得到 nil，便于把结果 JSON 化
            return .value(nil)
        }
        let resolvedValue: Any
        let typeName: String
        if let address = value as? EvalObjectAddress {
            let resolved = try ObjectiveCEvalBridge.object(at: address.rawValue)
            resolvedValue = resolved.value
            // 地址接收者从 isa 取得完整 runtime 名（Module.Type），用于跨模块同名类型消歧。
            typeName = resolved.typeName
        } else {
            resolvedValue = value
            typeName = EvalValue.shortTypeName(of: value)
        }
        let isClassInstance = Mirror(reflecting: resolvedValue).displayStyle == .class
        if !isCall, let property = commonProperty(of: resolvedValue, name: name) {
            return .value(property)
        }
        if !isCall, let property = SwiftMachOInvoker.readInstanceProperty(
            object: resolvedValue, name: name) {
            return apply(property)
        }
        // 计算属性（及存储属性的 getter）不会出现在 Mirror 反射结果里，这里改用 Mach-O 中的
        // getter 符号直接调用，使 `instance.prop`（无括号）也能取到值。`try?` 遇到同名方法 /
        // 属性歧义时静默放过，继续走后续分支。
        if !isCall {
            let candidateTypeNames = isClassInstance
                ? ObjectiveCEvalBridge.runtimeTypeNames(of: resolvedValue as AnyObject)
                : [typeName]
            for candidateTypeName in candidateTypeNames {
                if let result = SwiftMachOInvoker.readComputedInstanceProperty(
                    object: resolvedValue, typeName: candidateTypeName, name: name) {
                    return apply(result)
                }
            }
        }
        // ObjC 声明的 @property（如 UIViewController.view）既不出现在 Swift 反射里，
        // 也未必有 Swift mangled getter 符号；仅当上述 Swift 路径都没命中时，经 KVC
        // value(forKey:) 读取。先用 hasDeclaredProperty 沿继承链确认它确实是声明过的属性，
        // 否则普通零参数方法（如 reload）会被 responds(to:) 命中并被 KVC 当 getter 执行。
        // responds(to:) 再挡一次未实现 getter 的 key，避免 NSUnknownKeyException 崩溃。
        // 注意：读取 ObjC 计算属性会触发 getter 副作用（如访问 view 触发 view 加载），
        // 与显式「读取属性」意图一致；不希望执行 getter 时应改用 Mirror 可见的存储属性。
        if !isCall, let nsObject = resolvedValue as? NSObject,
           ObjectiveCEvalBridge.hasDeclaredProperty(object: nsObject, named: name),
           nsObject.responds(to: NSSelectorFromString(name)) {
            return .value(ObjectiveCEvalBridge.property(object: nsObject, name: name))
        }
        if isCall, isClassInstance {
            let object = resolvedValue as AnyObject
            if let result = try ObjectiveCEvalBridge.callInstanceMethod(
                object: object, name: name, labels: arguments.labels, arguments: arguments.items) {
                return apply(result)
            }
        }
        if isCall {
            let candidateTypeNames = isClassInstance
                ? ObjectiveCEvalBridge.runtimeTypeNames(of: resolvedValue as AnyObject)
                : [typeName]
            for candidateTypeName in candidateTypeNames {
                if let result = try SwiftMachOInvoker.callInstanceMethod(
                    object: resolvedValue, typeName: candidateTypeName, name: name,
                    labels: arguments.labels, arguments: arguments.items) {
                    return apply(result)
                }
            }
        }
        throw memberNotFound(typeName: typeName, name: name, offset: offset)
    }

    /// Mirror 的存储字段会以 Any 保留 Optional 包装；链式访问前需逐层解开。
    private static func unwrappedOptional(_ value: Any?) -> Any? {
        var current = value
        while let wrapped = current {
            let mirror = Mirror(reflecting: wrapped)
            guard mirror.displayStyle == .optional else { return wrapped }
            current = mirror.children.first?.value
        }
        return nil
    }

    /// 把 ObjC/Swift 桥的 void 与有值结果映射回解释器状态，保留后续链式调用所需的区别。
    private static func apply(_ value: EvalReturn) -> EvalBox {
        switch value {
        case .void: return .void
        case .value(let raw): return .value(raw)
        }
    }

    /// 提供不依赖业务代码的虚拟类型属性，用于查看类型名和可发现成员，而非调用真实 getter。
    private static func typeProperty(_ typeName: String, name: String) -> Any? {
        switch name {
        case "typeName": return typeName
        case "members":
            return SwiftMachOInvoker.memberNames(typeName: typeName)
        default: return nil
        }
    }

    /// 对任意返回值都可用的通用属性，避免为了看一眼数组长度再做专门适配。
    private static func commonProperty(of value: Any, name: String) -> Any? {
        switch name {
        case "typeName": return EvalValue.shortTypeName(of: value)
        case "description", "debugDescription": return String(describing: value)
        case "json": return EvalValue(any: value).displayText
        case "fields": return EvalValue(any: value).jsonObject
        case "count", "isEmpty":
            guard let count = collectionCount(of: value) else { return nil }
            return name == "count" ? count as Any : (count == 0) as Any
        default: return nil
        }
    }

    /// 以 Foundation 快路径或 Mirror 集合样式计算元素数；不枚举对象属性，不会触发 getter。
    private static func collectionCount(of value: Any) -> Int? {
        if let array = value as? [Any] { return array.count }
        if let dictionary = value as? [String: Any] { return dictionary.count }
        if let text = value as? String { return text.count }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .collection?, .set?, .dictionary?, .tuple?: return mirror.children.count
        default: return nil
        }
    }

    /// 构造带候选成员列表的统一“成员不存在”错误；符号被裁剪时会明确提示该限制。
    private static func memberNotFound(typeName: String, name: String, offset: Int) -> EvalError {
        let known = SwiftMachOInvoker.memberNames(typeName: typeName)
        let hint = known.isEmpty
            ? "类型 metadata 可能仍可见，但 Swift method descriptor 不保存成员名和完整签名；" +
                "未在 ObjC runtime 或当前进程 Mach-O 符号表中找到该成员。" +
                "Release 裁剪后请用 SwiftEval.register(method:) 注册入口，或将成员暴露给 ObjC runtime"
            : "可调用成员：\(known.joined(separator: ", "))"
        // 手动注册方法是全局入口，不挂在类型或实例上；写成 obj.name() 时提示正确形式。
        let methodHint = registry.hasMethod(named: name)
            ? "；「\(name)」是手动注册的方法，请写成 \(name)(...) 直接调用"
            : ""
        return EvalError(kind: .unknownMember,
                         message: "第 \(offset) 个字符：\(typeName) 上找不到「\(name)」",
                         suggestion: hint + methodHint)
    }

    // MARK: - 结果组装

    /// 将内部盒子转换为公开结果。成功值只在此处递归展示/JSON 化，避免中间链路过早丢失原始类型。
    private static func makeResult(expression: String, box: EvalBox, start: Date,
                                   maxDepth: Int, error: EvalError?) -> EvalResult {
        let duration = Date().timeIntervalSince(start)
        let hasReturnValue: Bool
        let typeName: String
        let rawValue: Any?
        let displayText: String
        let jsonObject: Any

        switch box {
        case .void:
            hasReturnValue = false
            typeName = "Void"
            rawValue = nil
            displayText = error?.description ?? "(无返回值)"
            jsonObject = NSNull()
        case .type(let name):
            hasReturnValue = false
            typeName = "\(name).Type"
            rawValue = nil
            displayText = error?.description ?? "<\(name).Type>"
            jsonObject = NSNull()
        case .value(let raw):
            // 成功值在此处才装箱为 EvalValue，统一取类型名、展示文本和 JSON 树。
            let value = EvalValue(any: raw)
            hasReturnValue = true
            typeName = value.typeName
            rawValue = raw
            displayText = value.displayText(maxDepth: maxDepth, maxItems: EvalValue.maxItems)
            jsonObject = value.jsonObject(maxDepth: maxDepth, maxItems: EvalValue.maxItems)
        }
        if let error = error {
            return EvalResult(expression: expression, isSuccess: false, hasReturnValue: false,
                              typeName: "Error", rawValue: nil, displayText: error.description,
                              jsonObject: NSNull(), duration: duration, error: error)
        }
        return EvalResult(expression: expression, isSuccess: true, hasReturnValue: hasReturnValue,
                          typeName: typeName, rawValue: rawValue, displayText: displayText,
                          jsonObject: jsonObject, duration: duration, error: nil)
    }
}
