//
//  SwiftEval 自检（macOS 命令行，无需 Xcode 工程）：
//  由 README 的 Swift / ObjC / arm64 汇编混编命令构建并运行。
//
//  覆盖：Mach-O 类方法 / 实例方法 / 类型属性 / Mirror 实例属性 / 带标签实参 /
//  无返回值 / 自动实例化 / ObjC runtime 零注册类方法 / 链式调用 / JSON 输出 /
//  ObjC 声明属性的 KVC 回退与「普通方法不被当 getter 执行」的副作用边界 /
//  手动注册方法（位置 / 标签 / 对象地址实参、void、nil、错误、注销、优先级、catalog）/
//  类与对象地址的属性方法清单（含父类、Swift + ObjC）/api/describe。
//

import Foundation
import Darwin

struct HeapObject {
    let address: UInt
    let className: String
}

@propertyWrapper
struct LayoutModeProjection {
    var wrappedValue: String
    var projectedValue: String { "projected:\(wrappedValue)" }
}

final class ProjectedMemberProbe {
    @LayoutModeProjection var layoutMode = "grid"
}

class ScannerBase {
    let inheritedName = "scanner-base"
}

/// 只用于成员清单所有权验证：清单只读 Mach-O 元数据，不会实例化或读取属性值，
/// 因此可安全声明 unowned 引用；也不注册根变量，避免 Mirror 求值链路碰到它。
final class OwnershipProbe {
    var strongRef: NSObject? = NSObject()
    weak var weakRef: NSObject? = nil
    unowned var unownedRef: NSObject
    unowned(unsafe) var unsafeRef: NSObject? = nil
    lazy var lazyRef: NSObject = NSObject()
    init() { unownedRef = NSObject() }
}

class MemoryGraphScanner: ScannerBase {
    private let objects: [HeapObject]

    static let defaultDepth = 2
    class var scannerKind: String { "memory-graph" }
    let objectCount: Int
    lazy var lazyName = "lazy-scanner"

    override init() {
        let initialObjects = [
            HeapObject(address: 0x1000, className: "Demo.RootVC"),
            HeapObject(address: 0x2000, className: "Demo.ChildVC"),
            HeapObject(address: 0x3000, className: "Demo.RoomManager")
        ]
        objects = initialObjects
        objectCount = initialObjects.count
        super.init()
    }

    /// 实例方法：用户示例里的 `MemoryGraphScanner.identifyObjects()` 会走自动实例化。
    func identifyObjects() -> [HeapObject] { objects }

    func referenceReport(of address: UInt, maxDepth: Int) -> [String: Any] {
        ["address": "0x" + String(address, radix: 16), "maxDepth": maxDepth, "cycles": []]
    }

    static func version() -> String { "1.0.0" }
    static func reset() {}
    static func ping(_ text: String) -> String { "pong:" + text }
    static func className() -> String { "MemoryGraphScanner" }
    static func selectTabLike(_ tabNumber: Int, gameRoomsSubTypeId: Int?) -> Bool {
        tabNumber == 0 && gameRoomsSubTypeId == nil
    }
    static func acceptsObject(in object: NSObject) -> Bool { object is ObjcDebugTool }

    private func privateMessage() -> String { "private" }

    func keepPrivateMessageLinked() -> String { privateMessage() }
}

@objcMembers
final class ObjcDebugTool: NSObject {
    static var computedGetterCalls = 0
    class var toolName: String { "objc-debug" }
    var objectValue = 7
    var computedValue: String {
        Self.computedGetterCalls += 1
        return "computed"
    }
    class func hello() -> String { "hello" }
    class func echo(_ text: String) -> String { text }
    class func answer() -> Int { 42 }
    class func add(_ lhs: Int, to rhs: Int) -> Int { lhs + rhs }
    class func noop() {}
    func instanceEcho(_ text: String) -> String { "instance:" + text }
    func acceptsObject(in object: NSObject) -> Bool { object === self }
}

final class ReferenceNode {
    let name: String
    var next: ReferenceNode?

    init(name: String) {
        self.name = name
    }
}

@objcMembers
class RuntimeBaseTool: NSObject {
    var inheritedCallCount = 0

    func inheritedNoop() {
        inheritedCallCount += 1
    }
}

class RuntimeSwiftBaseTool: NSObject {
    var inheritedCallCount = 0

    func swiftOnlyInheritedNoop() {
        inheritedCallCount += 1
    }
}

// 名称刻意与自检产物的 module name 同前缀，用于覆盖 Swift mangling substitution。
// swiftlint:disable:next type_name
final class swift_eval_selftestCompressedType {
    static func compressedLookupMarker() {}
}

// MARK: - 断言

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        NSLog("[PASS] %@", message)
    } else {
        failures += 1
        NSLog("[FAIL] %@", message)
    }
}

func evaluate(_ source: String) -> EvalResult {
    let result = SwiftEval.evaluate(source)
    if let error = result.error {
        NSLog("       expr=%@ error=%@", source, error.description)
    }
    return result
}

// 根变量仅用于验证“已有对象 + 动态方法”链路，方法本身没有注册。
let scannerObject = MemoryGraphScanner()
_ = scannerObject.lazyName
let projectedMemberProbe = ProjectedMemberProbe()
let objcToolObject = ObjcDebugTool()
let cyclicNode = ReferenceNode(name: "root")
cyclicNode.next = cyclicNode
let dynamicClassName = "RuntimeBaseTool_Aspects_"
let dynamicClass = objc_allocateClassPair(RuntimeBaseTool.self, dynamicClassName, 0)
if let dynamicClass = dynamicClass {
    objc_registerClassPair(dynamicClass)
}
let dynamicTool = (dynamicClass as? NSObject.Type)?.init() as? RuntimeBaseTool
let dynamicSwiftClassName = "RuntimeSwiftBaseTool_Aspects_"
let dynamicSwiftClass = objc_allocateClassPair(
    RuntimeSwiftBaseTool.self, dynamicSwiftClassName, 0)
if let dynamicSwiftClass = dynamicSwiftClass {
    objc_registerClassPair(dynamicSwiftClass)
}
let dynamicSwiftTool = (dynamicSwiftClass as? NSObject.Type)?.init() as? RuntimeSwiftBaseTool
swift_eval_selftestCompressedType.compressedLookupMarker()
SwiftEval.register(root: "scanner", object: scannerObject)
SwiftEval.register(root: "objcTool", object: objcToolObject)
SwiftEval.register(root: "cyclicNode", object: cyclicNode)
if let dynamicTool = dynamicTool {
    SwiftEval.register(root: "dynamicTool", object: dynamicTool)
}
if let dynamicSwiftTool = dynamicSwiftTool {
    SwiftEval.register(root: "dynamicSwiftTool", object: dynamicSwiftTool)
}

func addressExpression(of object: AnyObject) -> String {
    let address = UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())
    return "0x" + String(address, radix: 16)
}

// MARK: - 类方法 / 返回值

let version = evaluate("MemoryGraphScanner.version()")
check(version.isSuccess && version.hasReturnValue && version.displayText == "\"1.0.0\"",
      "类方法返回 String")

let ping = evaluate("MemoryGraphScanner.ping(\"ok\")")
check(ping.isSuccess && ping.displayText == "\"pong:ok\"", "类方法带字面量实参")

let reset = evaluate("MemoryGraphScanner.reset()")
check(reset.isSuccess && !reset.hasReturnValue && reset.typeName == "Void",
      "无返回值方法与返回 nil 区分")

check(evaluate("MemoryGraphScanner.defaultDepth").displayText == "2", "Swift static 属性")
check(evaluate("MemoryGraphScanner.scannerKind").displayText == "\"memory-graph\"", "Swift class 属性")
check(evaluate("MemoryGraphScanner().objectCount").displayText == "3", "Swift 对象属性")
check(evaluate("scanner.objectCount").displayText == "3", "Swift 已有对象属性")
check(evaluate("scanner.privateMessage()").displayText == "\"private\"",
      "private extension 风格 discriminator 方法可按原始成员名调用")
check(evaluate("scanner.inheritedName").displayText == "\"scanner-base\"", "Mirror 读取父类属性")
check(evaluate("scanner.lazyName").displayText == "\"lazy-scanner\"", "Mirror 读取 lazy 属性")
let scannerFields = evaluate("scanner").jsonObject as? [String: Any]
check(scannerFields?["inheritedName"] as? String == "scanner-base" &&
      scannerFields?["lazyName"] as? String == "lazy-scanner" &&
      scannerFields?["$__lazy_storage_$_lazyName"] == nil,
      "对象输出包含父类属性并还原 lazy 属性名")
let qualifiedScannerName = NSStringFromClass(MemoryGraphScanner.self)
check(evaluate(qualifiedScannerName + ".version()").displayText == "\"1.0.0\"",
      "Swift 完整命名空间调用")

// MARK: - 用户示例：类名调用实例方法（自动创建默认实例）

let objects = evaluate("MemoryGraphScanner.identifyObjects()")
check(objects.isSuccess && objects.hasReturnValue, "MemoryGraphScanner.identifyObjects() 调用成功")
check(objects.displayText.contains("Demo.RootVC") && objects.displayText.contains("Demo.RoomManager"),
      "自定义 struct 数组返回值可读展示")
check((objects.jsonObject as? [Any])?.count == 3, "返回值 JSON 化为 3 元素数组")

let rawObjects = objects.rawValue as? [HeapObject]
check(rawObjects?.count == 3, "rawValue 保留原始 Swift 类型")

let explicit = evaluate("MemoryGraphScanner().identifyObjects()")
check(explicit.isSuccess && (explicit.rawValue as? [HeapObject])?.count == 3,
      "Type() 显式构造实例再调实例方法")

// MARK: - 参数标签 / 十六进制 / 链式

let report = evaluate("MemoryGraphScanner.referenceReport(of: 0x1000, maxDepth: 2)")
check(report.isSuccess && report.displayText.contains("0x1000") && report.displayText.contains("2"),
      "带标签参数 + 十六进制整数字面量")
let optionalArgument = evaluate(
    "MemoryGraphScanner.selectTabLike(0, gameRoomsSubTypeId: nil)")
check(optionalArgument.isSuccess && optionalArgument.displayText == "true",
      "首个位置参数与 Int? nil 参数按 Swift ABI 正确调用")

let chained = evaluate("MemoryGraphScanner.identifyObjects().count")
check(chained.isSuccess && chained.displayText == "3", "链式调用 .count")

let chainedJSON = evaluate("MemoryGraphScanner.identifyObjects().json")
check(chainedJSON.isSuccess && chainedJSON.displayText.contains("Demo.ChildVC"), "链式调用 .json")

let rootChained = evaluate("scanner.identifyObjects().count")
check(rootChained.isSuccess && rootChained.displayText == "3", "实例链式调用")

let scannerAddress = addressExpression(of: scannerObject)
check(evaluate(scannerAddress + ".identifyObjects().count").displayText == "3",
      "十六进制地址调用 Swift 对象方法")
check(evaluate(scannerAddress + ".objectCount").displayText == "3",
      "十六进制地址读取 Swift 对象属性")

// MARK: - ObjC runtime 零注册类方法

let hello = evaluate("ObjcDebugTool.hello()")
check(hello.isSuccess && hello.displayText == "\"hello\"", "ObjC 零注册类方法（零参数，返回对象）")

let echo = evaluate("ObjcDebugTool.echo(\"hi\")")
check(echo.isSuccess && echo.displayText == "\"hi\"", "ObjC 零注册类方法（一个对象参数）")

let answer = evaluate("ObjcDebugTool.answer()")
check(answer.isSuccess && answer.displayText == "42", "ObjC 零注册类方法（标量返回值）")

let sum = evaluate("ObjcDebugTool.add(20, to: 22)")
check(sum.isSuccess && sum.displayText == "42", "ObjC 零注册类方法（标量参数与返回值）")

let noop = evaluate("ObjcDebugTool.noop()")
check(noop.isSuccess && !noop.hasReturnValue, "ObjC 零注册 void 类方法")

check(evaluate("ObjcDebugTool.toolName").displayText == "\"objc-debug\"", "ObjC 类属性")
check(evaluate("objcTool.objectValue").displayText == "7", "ObjC 对象属性")

let objcToolAddress = addressExpression(of: objcToolObject)
check(evaluate(objcToolAddress + ".instanceEcho(\"ok\")").displayText == "\"instance:ok\"",
      "十六进制地址调用 ObjC 对象方法")
check(evaluate(objcToolAddress + ".objectValue").displayText == "7",
      "十六进制地址读取 ObjC 对象属性")
check(evaluate("MemoryGraphScanner.acceptsObject(in: " + objcToolAddress + ")").displayText == "true",
      "Swift 方法支持带外部标签的对象地址参数")
check(evaluate("objcTool.acceptsObject(in: " + objcToolAddress + ")").displayText == "true",
      "ObjC 方法支持带外部标签的对象地址参数")

let inheritedNoop = evaluate("dynamicTool.inheritedNoop()")
check(inheritedNoop.isSuccess && dynamicTool?.inheritedCallCount == 1,
      "ObjC runtime 可从 Aspects 风格动态子类调用父类方法")
let swiftInheritedNoop = evaluate("dynamicSwiftTool.swiftOnlyInheritedNoop()")
check(swiftInheritedNoop.isSuccess && dynamicSwiftTool?.inheritedCallCount == 1,
      "Mach-O 可从 Aspects 风格动态子类调用父类纯 Swift 方法")
let compressedTypeSymbols = SEMachOSymbolResolver.symbolsContainingType(
    "swift_eval_selftestCompressedType")
check(compressedTypeSymbols.contains(where: {
    ($0["demangled"] as? String)?.contains("compressedLookupMarker") == true
}), "Swift mangling substitution 不会导致类型符号在 demangle 前被过滤")
let metadataRecord = SEMachOSymbolResolver.swiftTypeMetadataRecord(
    named: "swift_eval_selftestCompressedType")
check((metadataRecord?["accessor"] as? NSNumber)?.uintValue != 0,
      "Swift nominal type metadata 直接来自 __swift5_types，不依赖符号表")

// MARK: - ObjC 声明属性 / getter 副作用边界

// 系统类的计算属性 Mirror 看不到、也没有 Swift mangled getter，等价于 UIViewController.view。
// 仅当 runtime 沿继承链能查到同名 @property 时才允许走 KVC 读取。
let objcPropertyURL = NSURL(string: "https://example.com/a/b") ?? NSURL(fileURLWithPath: "/")
let objcPropertyURLAddress = addressExpression(of: objcPropertyURL)
check(evaluate(objcPropertyURLAddress + ".path").displayText == "\"/a/b\"",
      "无括号读取 ObjC 声明的计算属性（等价 UIViewController.view）")
check(evaluate(objcPropertyURLAddress + ".host").displayText == "\"example.com\"",
      "无括号读取父类声明的 ObjC 属性")

// 普通零参数方法没有 property 元数据：无括号访问不能被 KVC 当成 getter 执行，
// 也不会误报成属性；带括号仍按 ObjC selector 正常调用。
let sideEffectProbe = RuntimeBaseTool()
let sideEffectProbeAddress = addressExpression(of: sideEffectProbe)
let noBracketMethod = evaluate(sideEffectProbeAddress + ".inheritedNoop")
check(noBracketMethod.error?.kind == .unknownMember && sideEffectProbe.inheritedCallCount == 0,
      "无括号访问普通方法不会触发 getter 副作用")
check(evaluate(sideEffectProbeAddress + ".inheritedNoop()").isSuccess &&
      sideEffectProbe.inheritedCallCount == 1,
      "带括号仍可调用 ObjC 零参数方法")

// MARK: - 手动注册方法

// 有返回值 + 位置参数 + 标签参数：注册方法复用与自动发现相同的实参求值链路。
// 闭包同时接受 `probeAdd(1, to: 2)` 与 `probeAdd(1, 2)`，演示标签与下标两种取参方式。
SwiftEval.register(method: "probeAdd") { args in
    let lhs = try args.int(at: 0)
    let rhs = args.labels.contains("to") ? try args.int(labeled: "to") : try args.int(at: 1)
    return lhs + rhs
}
check(evaluate("probeAdd(1, to: 2)").displayText == "3", "注册方法带标签参数")
check(evaluate("probeAdd(1, 2)").displayText == "3", "注册方法带位置参数")
check(evaluate("probeAdd(1, to: 2).description").displayText == "\"3\"",
      "注册方法返回值可继续链式访问")
check(evaluate("probeAdd(1)").error?.kind == .arity, "注册方法缺少实参报 arity")
SwiftEval.register(method: "probeLabeled") { args in try args.int(labeled: "to") }
check(evaluate("probeLabeled(nope: 2)").error?.kind == .argument,
      "注册方法缺少标签报 argument")

// 无返回值 / 返回 nil：两者的 hasReturnValue 不同，与自动发现方法语义一致。
var probeVerbose = false
SwiftEval.register(voidMethod: "probeSetVerbose") { args in
    probeVerbose = try args.bool(labeled: "enabled")
}
let voidResult = evaluate("probeSetVerbose(enabled: true)")
check(voidResult.isSuccess && !voidResult.hasReturnValue && probeVerbose,
      "voidMethod 返回 .void 且副作用生效")
SwiftEval.register(method: "probeReturnNil") { _ in nil }
let nilResult = evaluate("probeReturnNil()")
check(nilResult.isSuccess && nilResult.hasReturnValue && nilResult.displayText == "nil",
      "注册方法返回 nil 仍标记为有返回值")

// 对象地址 / 根变量都能作为实参，经 object(labeled:) 还原成真实类实例。
SwiftEval.register(method: "probeInspect") { args in
    let object = try args.object(labeled: "target")
    return (object as? ObjcDebugTool)?.objectValue ?? -1
}
check(evaluate("probeInspect(target: " + objcToolAddress + ")").displayText == "7",
      "注册方法接收 0x... 对象地址实参")
check(evaluate("probeInspect(target: objcTool)").displayText == "7",
      "注册方法接收根变量对象实参")
check(evaluate("probeInspect(target: 123)").error?.kind == .argument,
      "注册方法拒绝把标量当对象")

// 错误传播：EvalError 原样透传，其它 Error 包装成 .invocation 并带方法名。
SwiftEval.register(method: "probeTypedError") { _ in
    throw EvalError(kind: .unsupported, message: "故意失败", suggestion: "换个参数")
}
check(evaluate("probeTypedError()").error?.kind == .unsupported &&
      evaluate("probeTypedError()").error?.suggestion == "换个参数",
      "注册方法抛出的 EvalError 原样透传")
SwiftEval.register(method: "probePlainError") { _ in
    throw NSError(domain: "SwiftEvalSelfTest", code: 7, userInfo: nil)
}
let plainError = evaluate("probePlainError()").error
check(plainError?.kind == .invocation && plainError?.message.contains("probePlainError") == true,
      "注册方法抛出的普通 Error 包装为 invocation 并带方法名")

// 同名覆盖、注销、目录与优先级。
SwiftEval.register(method: "probeOverwrite") { _ in "first" }
check(evaluate("probeOverwrite()").displayText == "\"first\"", "注册方法首次注册")
SwiftEval.register(method: "probeOverwrite") { _ in "second" }
check(evaluate("probeOverwrite()").displayText == "\"second\"", "同名重复注册以最后一次为准")
let registeredNames = SwiftEval.registeredMethods()
check(registeredNames.contains("probeAdd") && registeredNames == registeredNames.sorted(),
      "registeredMethods 返回排序后的方法名")
check((SwiftEval.catalog()["methods"] as? [String])?.contains("probeAdd") == true,
      "catalog 包含 methods 字段")
SwiftEval.register(method: "ObjcDebugTool") { _ in "registered-wins" }
check(evaluate("ObjcDebugTool()").displayText == "\"registered-wins\"",
      "注册方法优先于同名类型构造")
SwiftEval.unregister(method: "ObjcDebugTool")
check(evaluate("ObjcDebugTool.hello()").displayText == "\"hello\"",
      "注销后同名类型的自动发现恢复可用")
check(evaluate("probeAdd").error?.kind == .syntax,
      "注册方法省略括号时提示需写成 name(...)")
check(evaluate("objcTool.probeAdd()").error?.suggestion?.contains("手动注册的方法") == true,
      "把注册方法当成员调用时提示直接调用")
SwiftEval.unregister(method: "probeAdd")
check(evaluate("probeAdd(1, to: 2)").error?.kind == .unknownType,
      "注销后注册方法不再可调用")

// MARK: - 字面量 / 属性 / 多语句

check(evaluate("[1, 2, 3].count").displayText == "3", "数组字面量 + .count")
check(evaluate("[\"a\": 1, \"b\": 2].count").displayText == "2", "字典字面量 + .count")
check(evaluate("\"hello\".count").displayText == "5", "字符串字面量属性")
check(evaluate("MemoryGraphScanner.typeName").displayText == "\"MemoryGraphScanner\"", "类型通用属性")
check(evaluate("MemoryGraphScanner.members").displayText.contains("identifyObjects"),
      "类型成员清单")
check(evaluate("MemoryGraphScanner.version(); ObjcDebugTool.hello()").displayText == "\"hello\"",
      "分号分隔多语句，返回最后一条结果")

// MARK: - 错误路径

check(evaluate("MemoryGraphScanner.unknown()").error?.kind == .unknownMember, "未知成员报错")
check(evaluate("NoSuchType.foo()").error?.kind == .unknownType, "未知类型报错")
check(evaluate("MemoryGraphScanner.version(").error?.kind == .syntax, "语法错误报错")
check(evaluate("").error?.kind == .syntax, "空表达式报错")
check(evaluate("MemoryGraphScanner.ping()").error != nil, "缺少实参时报错")
check(evaluate("0x1.objectValue").error?.kind == .argument, "非法对象地址安全报错")
let projectedMemberAddress = addressExpression(of: projectedMemberProbe)
check(evaluate(projectedMemberAddress + ".$layoutMode").displayText == "\"projected:grid\"",
      "对象地址支持读取 $ 开头的 Swift projected-value 成员")
check(evaluate("$layoutMode").error?.kind == .syntax,
      "$ 只允许用于点号后的成员名")

let cyclicResult = SwiftEval.evaluate("cyclicNode", maxDepth: 10)
check(cyclicResult.isSuccess && cyclicResult.displayText.contains("循环引用"),
      "Mirror 展开对象时识别循环引用")
let objcObjectInfo = SwiftEval.evaluate("objcTool", maxDepth: 4)
check(objcObjectInfo.displayText.contains("<") &&
      objcObjectInfo.displayText.contains("objectValue"),
      "NSObject 以 IDE 格式展示 Mirror 存储属性")
check(ObjcDebugTool.computedGetterCalls == 0,
      "无 backing ivar 的普通 computed property 不会被反射自动调用")
check(SwiftEval.maxDepth == 10, "属性默认展示深度为 10")
SwiftEval.maxDepth = 100
check(SwiftEval.maxDepth == 10, "对象展示深度上限为 10")

let jsonText = evaluate("MemoryGraphScanner.version()").jsonString()
check(jsonText.contains("\"hasReturnValue\"") && jsonText.contains("\"display\""),
      "EvalResult JSON 含返回值信息")

// MARK: - 成员清单：属性 / 方法（含父类，Swift + ObjC）

let objcMembers = EvalTypeDescription.describe(target: "ObjcDebugTool")
check(objcMembers.isSuccess && objcMembers.className.contains("ObjcDebugTool"), "成员清单按类名解析")
check(objcMembers.sections.count >= 2 && objcMembers.displayText.contains("in NSObject:"),
      "成员清单沿继承链包含父类")
check(objcMembers.displayText.contains("Instance Methods:") &&
      objcMembers.displayText.contains("Class Methods:") &&
      objcMembers.displayText.contains("Properties:"),
      "成员清单分组沿用 _methodDescription 风格")
check(objcMembers.displayText.contains("hello() -> id (0x") && objcMembers.displayText.contains("[objc]"),
      "ObjC 类方法改为 Swift 声明式并标记 [objc]")
check(objcMembers.displayText.contains("instanceEcho(_: id) -> id (0x") && objcMembers.displayText.contains("[objc]"),
      "ObjC 实例方法按 type encoding 转 Swift 参数格式")
check(objcMembers.displayText.contains("objectValue() -> long (0x") && objcMembers.displayText.contains("[objc]"),
      "ObjC 标量返回类型展示为可读名称并转 Swift 式")

let pureSwiftMembers = EvalTypeDescription.describe(target: "MemoryGraphScanner")
check(pureSwiftMembers.isSuccess && pureSwiftMembers.displayText.contains("identifyObjects") &&
      pureSwiftMembers.displayText.contains("[swift]"),
      "纯 Swift 方法来自 Mach-O 符号并标记来源")
check(pureSwiftMembers.displayText.contains("ScannerBase") &&
      pureSwiftMembers.displayText.contains("inheritedName"),
      "Swift 父类存储属性随继承链列出")
check(pureSwiftMembers.displayText.contains("@property (ivar, strong) Int objectCount"),
      "Swift 存储属性用同名 getter 还原类型并标注 strong")
check(pureSwiftMembers.displayText.contains("@property (ivar, strong) String lazyName;") &&
      !pureSwiftMembers.displayText.contains("$__lazy_storage_$_"),
      "lazy backing storage 还原业务属性名、补出类型并标注 strong")
check(pureSwiftMembers.displayText.contains("reset() -> Void"),
      "Swift 无参方法以 name() -> ReturnType 声明式输出")
check(pureSwiftMembers.displayText.contains("referenceReport(of: UInt, maxDepth: Int)"),
      "Swift 方法以 name(label: Type, ...) -> ReturnType 声明式输出")

let ownershipMembers = EvalTypeDescription.describe(target: "OwnershipProbe")
check(ownershipMembers.displayText.contains("@property (ivar, weak) ") &&
      ownershipMembers.displayText.contains("weakRef"),
      "Swift weak 存储属性标注 weak")
check(ownershipMembers.displayText.contains("@property (ivar, unowned) ") &&
      ownershipMembers.displayText.contains("unownedRef"),
      "Swift unowned 存储属性标注 unowned")
check(ownershipMembers.displayText.contains("@property (ivar, unowned(unsafe)) ") &&
      ownershipMembers.displayText.contains("unsafeRef"),
      "Swift unowned(unsafe) 存储属性单独标注")
check(ownershipMembers.displayText.contains("@property (ivar, strong) ") &&
      ownershipMembers.displayText.contains("strongRef"),
      "Swift 普通存储属性标注 strong")

let addressMembers = EvalTypeDescription.describe(target: objcToolAddress)
check(addressMembers.isSuccess && addressMembers.isAddress &&
      addressMembers.className.contains("ObjcDebugTool"), "成员清单支持存活对象地址")

// 短类名兼容：不写 Module 也能按最后一段精确匹配（如 RoomViewController → SawaLudoCommon.RoomViewController）。
// 纯 Swift 类只以 Module.Class 形式注册到 runtime，NSClassFromString("短名") 恒为 nil，需要这层兜底。
let shortNamedMembers = EvalTypeDescription.describe(target: "MemoryGraphScanner")
check(shortNamedMembers.isSuccess && shortNamedMembers.className.hasSuffix("MemoryGraphScanner") &&
      shortNamedMembers.displayText.contains("identifyObjects"),
      "成员清单支持不带模块前缀的短类名")

let ownMembersOnly = EvalTypeDescription.describe(target: "ObjcDebugTool", includeSuperclasses: false)
check(ownMembersOnly.sections.count == 1, "关闭父类开关后只保留一层")
let runtimeMembersOnly = EvalTypeDescription.describe(target: "MemoryGraphScanner", includeSwift: false)
check(!runtimeMembersOnly.displayText.contains("[swift]"), "关闭 Swift 开关后不列 Mach-O 成员")
let withoutIvars = EvalTypeDescription.describe(target: "MemoryGraphScanner", includeIvars: false)
check(!withoutIvars.displayText.contains("(ivar"), "关闭 ivar 开关后不列存储属性")
check(!EvalTypeDescription.describe(target: "0x1").isSuccess, "成员清单拒绝非法对象地址")
check(!EvalTypeDescription.describe(target: "NoSuchType123").isSuccess, "成员清单拒绝未知类名")
check((objcMembers.dictionary["memberCount"] as? Int) ?? 0 > 0 &&
      (objcMembers.dictionary["sections"] as? [Any])?.isEmpty == false,
      "成员清单可序列化成结构化 JSON")

// HTTP 入口：临时关掉主线程派发，避免 CLI 主线程被信号量阻塞时死锁。
let savedMainThreadSetting = SwiftEval.dispatchOnMainThread
SwiftEval.dispatchOnMainThread = false
SwiftEvalHTTPServer.shared.start(port: 0)
let boundPort = SwiftEvalHTTPServer.shared.boundPort
if boundPort > 0,
   let describeURL = URL(string: "http://127.0.0.1:\(boundPort)/api/describe?target=ObjcDebugTool&includeSuper=0") {
    let semaphore = DispatchSemaphore(value: 0)
    var payload: [String: Any]?
    let task = URLSession.shared.dataTask(with: describeURL) { data, _, _ in
        if let data = data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = json
        }
        semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 5)
    check(payload?["ok"] as? Bool == true && (payload?["classCount"] as? NSNumber)?.intValue == 1,
          "HTTP /api/describe 返回清单并支持 includeSuper 开关")
} else {
    check(false, "HTTP 调试服务可在本机绑定端口")
}
SwiftEvalHTTPServer.shared.stop()
SwiftEval.dispatchOnMainThread = savedMainThreadSetting

if failures == 0 {
    NSLog("SwiftEval 自检全部通过")
} else {
    NSLog("SwiftEval 自检失败 %d 项", failures)
}
exit(failures == 0 ? 0 : 1)
