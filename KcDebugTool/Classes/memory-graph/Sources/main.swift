//
//  main.swift
//  MemoryGraphTool
//
//  命令行入口。
//
//  用法：
//    mgtool --filter <类名前缀1,前缀2> --out <输出目录> [--template <viewer.template.html 路径>] [--demo]
//
//  - --filter      只保留类名以这些前缀开头的对象，多个用逗号分隔；不传则保留堆上全部对象（图规模很大）
//  - --out         输出目录，生成 graph.json 与 memory_graph.html（默认 ./output）
//  - --weak-ivar   兜底手动标注 weak 属性名（weak/unowned 通常已自动识别）
//  - --demo        先构造一组带多处循环引用的演示对象再扫描，便于直接验证效果
//
//  接入 iOS App 时：在 Debug 菜单里调用 MemoryGraphScanner(classPrefixes:).scan()；
//  classPrefixes 传空数组可保留堆上全部对象（不推荐，噪音极大）
//  并导出 JSON/HTML，通过 AirDrop / 文件分享带出；详见 README.md。
//

import Foundation
import ObjectiveC

// swiftlint:disable force_unwrapping

// MARK: - 演示对象图（--demo）

/// 演示用的泄漏场景：4 组引用关系 + 4 处循环引用
final class MGDemoAppCoordinator: NSObject {
    var currentSession: MGDemoSession?
    var observers: [MGDemoObserver] = []
    var cache: MGDemoImageCache?
    /// unowned 反向引用验证载体
    var reporters: [MGDemoReporter] = []
    /// 闭包 / block 捕获验证载体
    var callbackOwner: MGDemoCallbackOwner?
    /// weak 属性验证载体：反射元数据应识别为 weak，且不建强引用边
    weak var weakDelegate: MGDemoObserver?
}

/// 闭包 / block 引用验证：
/// - objcBlock：@convention(block) 使闭包成为真实 ObjC block（堆块 isa 为
///   __NSMallocBlock__ 注册类，偏移 32 起为捕获变量指针）；
/// - swiftClosure：Swift 原生闭包上下文也是堆块，但首字是元数据指针而非类 isa，
///   按匿名容器透传。
/// 注意：闭包体必须真正使用捕获值（`_ = token` 会被编译器优化为不捕获）。
final class MGDemoCallbackOwner: NSObject {
    var objcBlock: (@convention(block) () -> Void)?
    var swiftClosure: (() -> Void)?
}

final class MGDemoSession: NSObject {
    var config: MGDemoConfig?
    var coordinator: MGDemoAppCoordinator?
}

final class MGDemoConfig: NSObject {
    var session: MGDemoSession?
    var options: [String] = ["enableLog", "region=KSA"]
}

final class MGDemoObserver: NSObject {
    weak var subject: NSObject?
    var token: MGDemoToken?
}

final class MGDemoToken: NSObject {
    var owner: MGDemoObserver?
}

final class MGDemoImageCache: NSObject {
    var entries: [MGDemoCacheEntry] = []
}

/// unowned 识别验证：coordinator 经 observers 数组强持有 reporter，
/// reporter 对 coordinator 只有 unowned 反向引用——若 unowned 未被识别，
/// 会误报一组 coordinator <-> reporter 的假循环
final class MGDemoReporter: NSObject {
    unowned let subject: MGDemoAppCoordinator
    init(subject: MGDemoAppCoordinator) {
        self.subject = subject
        super.init()
    }
}

final class MGDemoCacheEntry: NSObject {
    var key = ""
    var owner: MGDemoImageCache?
}

/// 纯 Swift 类（非 NSObject 子类）：验证运行时能否识别与建边
final class MGPureSession {
    var config: MGPureConfig?
    var tags: [String] = ["pure-swift"]
}

final class MGPureConfig {
    var session: MGPureSession?
    var owner: MGPureRoot?
}

final class MGPureRoot {
    var session: MGPureSession?
}

/// 动态类实例保活：扫描时需在堆上存活
private var dynamicDemoKeepAlive: NSObject?

/// 运行时动态创建的类（objc_allocateClassPair）：元数据位于堆上且没有 Swift 元数据描述符，
/// 回归验证反射调用对这类类的安全性（真机曾在此处 EXC_BAD_ACCESS）
private func registerDemoDynamicClass() {
    guard let dynamicClass = objc_allocateClassPair(NSObject.self, "MGDemoDynamicClass", 0) else { return }
    class_addIvar(dynamicClass, "dynamicRef", MemoryLayout<UnsafeRawPointer>.size, 3, "@id")
    objc_registerClassPair(dynamicClass)
    if let cls = dynamicClass as? NSObject.Type {
        dynamicDemoKeepAlive = cls.init()
    }
}

/// 构造演示图并返回根对象；根对象存活即整图存活，模拟「忘了释放」的场景
private func buildDemoGraph() -> AnyObject {
    let coordinator = MGDemoAppCoordinator()
    let session = MGDemoSession()
    let config = MGDemoConfig()

    coordinator.currentSession = session
    session.config = config
    config.session = session           // 循环 1：session <-> config
    session.coordinator = coordinator  // 循环 2：coordinator <-> session

    for _ in 0..<3 {
        let observer = MGDemoObserver()
        observer.subject = coordinator // weak 引用，不应出现在强引用图中
        let token = MGDemoToken()
        token.owner = observer         // 循环 3：observer <-> token
        observer.token = token
        coordinator.observers.append(observer)
    }

    let cache = MGDemoImageCache()
    for index in 0..<4 {
        let entry = MGDemoCacheEntry()
        entry.key = "image_\(index)"
        entry.owner = cache            // 循环 4：cache <-> entry
        cache.entries.append(entry)
    }
    coordinator.cache = cache

    // unowned 反向引用：不构成循环，识别失败时会成为假循环
    coordinator.reporters.append(MGDemoReporter(subject: coordinator))

    // 闭包 / block 捕获：block 与 Swift 闭包都强捕获同一个 token
    let callbackOwner = MGDemoCallbackOwner()
    let blockToken = MGDemoToken()
    callbackOwner.objcBlock = { blockToken.owner = nil }   // ObjC block 强捕获
    callbackOwner.swiftClosure = { blockToken.owner = nil } // Swift 闭包上下文强捕获
    coordinator.callbackOwner = callbackOwner

    // 纯 Swift 类子图：root -> session -> config -> session 是一个循环
    let pureRoot = MGPureRoot()
    let pureSession = MGPureSession()
    let pureConfig = MGPureConfig()
    pureRoot.session = pureSession
    pureSession.config = pureConfig
    pureConfig.session = pureSession   // 循环 5：pureSession <-> pureConfig
    pureConfig.owner = pureRoot
    // 纯 Swift 子图自身成环（root->session->config->session），泄漏状态下会一直
    // 存活在堆上，正好模拟真实泄漏场景；demo 根仍返回 coordinator
    registerDemoDynamicClass()
    return coordinator
}

// MARK: - 参数解析与执行

private func argumentValue(_ arguments: [String], _ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let arguments = CommandLine.arguments
let shouldRunDemo = arguments.contains("--demo")

// --filter 不传时保留堆上全部对象；demo 模式为保证效果默认仍用 MGDemo 前缀
let classPrefixes: [String]
if let filterArgument = argumentValue(arguments, "--filter") {
    classPrefixes = filterArgument.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
} else if shouldRunDemo {
    classPrefixes = ["MGDemo"]
} else {
    FileHandle.standardError.write("提示：未传 --filter，将保留堆上全部对象，图规模可能非常大\n".data(using: .utf8)!)
    classPrefixes = []
}

let outputDirectory = argumentValue(arguments, "--out") ?? "output"
let templatePath = argumentValue(arguments, "--template") ?? "Templates/viewer.template.html"
// 已知 weak 属性名列表：这些 ivar 不参与强引用图与循环检测
let weakIvarNames = Set((argumentValue(arguments, "--weak-ivar") ?? "")
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty })

if shouldRunDemo {
    // 根对象存活到扫描结束，模拟忘记释放
    let demoRoot: AnyObject = buildDemoGraph()
    withExtendedLifetime(demoRoot) {
        runScanAndExport(classPrefixes: classPrefixes,
                         weakIvarNames: weakIvarNames,
                         outputDirectory: outputDirectory,
                         templatePath: templatePath)
        runReferenceQueryDemo(of: demoRoot,
                              weakIvarNames: weakIvarNames)
    }
} else {
    runScanAndExport(classPrefixes: classPrefixes,
                     weakIvarNames: weakIvarNames,
                     outputDirectory: outputDirectory,
                     templatePath: templatePath)
}

/// 按需引用查询验证：对 coordinator 反查 incoming。
/// 预期 L1 = MGDemoSession（直接）+ 3 个 MGDemoObserver（经 observers 数组间接），
/// weak 的 subject 与 unowned 的 reporter 不出现在来源中；L2 追加 config 与 token
private func runReferenceQueryDemo(of root: AnyObject, weakIvarNames: Set<String>) {
    let scanner = MemoryGraphScanner(classPrefixes: ["MGDemo"], weakIvarNames: weakIvarNames)
    print("按需查询：识别堆对象...")
    scanner.identifyObjects()
    guard let report = scanner.referenceReport(of: unsafeBitCast(root, to: UInt.self), maxDepth: 2) else {
        print("按需查询：未找到目标对象（前缀过滤后不存在）")
        return
    }
    let nameByAddress = report.classNameByAddress
    func name(_ address: UInt) -> String {
        let className = nameByAddress[address] ?? "?"
        return "\(className)(0x\(String(address, radix: 16)))"
    }
    print("== 引用查询：\(name(report.address))，大小 \(report.size) 字节 ==")
    print("outgoing（它引用了谁）:")
    for edge in report.outgoing {
        print("  -> \(name(edge.to))\(edge.isIndirect ? " [经容器]" : "")（\(edge.ivarName ?? "?")）[\(edge.ownership.label)]")
    }
    if !report.nonStrongOutgoing.isEmpty {
        print("非强引用（不参与强引用图 / 找环）:")
        for edge in report.nonStrongOutgoing {
            print("  -> \(name(edge.to))（\(edge.ivarName ?? "?")）[\(edge.ownership.label)]")
        }
    }
    if !report.nonStrongFields.isEmpty {
        print("非强字段（字段元数据，即使槽位不指向对象也可判定）:")
        for (field, ownership) in report.nonStrongFields.sorted(by: { $0.key < $1.key }) {
            print("  \(field) [\(ownership.label)]")
        }
    }
    print("incoming（谁强引用了它）:")
    for edge in report.incoming {
        let level = report.incomingLevel[edge.from] ?? 0
        print("  L\(level) <- \(name(edge.from))\(edge.isIndirect ? " [经容器]" : "")（\(edge.ivarName ?? "?")）[\(edge.ownership.label)]")
    }
    print("循环引用链（经过该对象）:")
    if report.cycles.isEmpty {
        print("  无（该对象不在任何强引用环中）")
    } else {
        for (index, chain) in report.cycles.enumerated() {
            var line = "  [\(index)] "
            for link in chain.edges {
                let fromName = chain.classNameByAddress[link.from] ?? name(link.from)
                line += "\(fromName) --\(link.ivarName ?? "?")--> "
            }
            line += "↩︎ \(chain.classNameByAddress[report.address] ?? name(report.address))（\(chain.edges.count) 条边）"
            print(line)
        }
    }
}

private func runScanAndExport(classPrefixes: [String], weakIvarNames: Set<String>, outputDirectory: String, templatePath: String) {
    do {
        // 输出目录初始化
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

        print("开始扫描堆（类名前缀：\(classPrefixes.joined(separator: ", "))）...")
        let scanner = MemoryGraphScanner(classPrefixes: classPrefixes, weakIvarNames: weakIvarNames)
        scanner.scan()

        // 导出 graph.json
        let jsonData = try scanner.exportJSONData()
        let jsonPath = (outputDirectory as NSString).appendingPathComponent("graph.json")
        try jsonData.write(to: URL(fileURLWithPath: jsonPath))

        // 用模板生成 memory_graph.html（注入 JSON 数据）
        let htmlPath = (outputDirectory as NSString).appendingPathComponent("memory_graph.html")
        let template = try String(contentsOfFile: templatePath, encoding: .utf8)
        let htmlData = try scanner.exportHTMLData(template: template)
        try htmlData.write(to: URL(fileURLWithPath: htmlPath))

        // 摘要输出
        print("扫描完成：\(scanner.objects.count) 个对象，\(scanner.edges.count) 条强引用边")
        print("发现 \(scanner.cycles.count) 组循环引用：")
        let addressToClass = Dictionary(uniqueKeysWithValues: scanner.objects.map { ($0.address, $0.className) })
        for (index, cycle) in scanner.cycles.enumerated() {
            let names = cycle.map { addressToClass[$0] ?? "?" }
            print("  [\(index)] " + zip(cycle, names).map { "\($1)(0x\(String($0, radix: 16)))" }.joined(separator: " -> "))
        }

        // weakly_referenced 是对象级标记：只说明该对象被某处 weak 引用过，
        // 不指向任何具体边，也不能用来判断闭包 / block 捕获边的强弱
        let weakMarked = scanner.weaklyReferencedObjects()
        if !weakMarked.isEmpty {
            print("提示：\(weakMarked.count) 个对象带有 weakly_referenced 标记（被 weak 引用过）：")
            for object in weakMarked {
                print("  \(object.className)(0x\(String(object.address, radix: 16)))")
            }
        }
        print("输出：\(jsonPath)")
        print("输出：\(htmlPath)")
    } catch {
        FileHandle.standardError.write("执行失败：\(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// swiftlint:enable force_unwrapping
