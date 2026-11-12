//
//  MemoryGraphCore.swift
//  MemoryGraphTool
//
//  运行时内存图核心（不依赖源码、不依赖符号表）：
//
//  1. 通过 malloc_get_all_zones + zone introspection enumerator 枚举当前进程
//     所有 malloc zone 中「在用」的堆块（与 leaks / Xcode Memory Graph 同思路）；
//  2. 读取堆块首字（isa），解码后与已注册类表比对，筛出目标类名前缀的
//     实例作为图的节点；isa 的 weakly_referenced 位（实测 bit2）作为
//     「该对象被 weak 引用（或曾引用）」的节点级标记；
//  3. 对每个对象按 ivar 偏移扫描指针字，把指向其他已识别对象的字记为
//     一条强引用边；weak / unowned ivar 自动排除出强引用图：Swift 定义的类
//     经 swift_reflectionMirror_* 反射元数据的 isStrong 标记识别
//     （Optional 非强字段统一按 weak 处理，非 Optional 按 unowned 处理），
//     ObjC 定义的类经 ivarLayout 识别；--weak-ivar 仅作为兜底手段；
//     对指向「非对象容器块」（Swift Array/Dictionary 缓冲区、未被过滤进
//     图中的 NSArray 等）的字做一层透传扫描，保证容器内元素的引用不丢失；
//  4. Tarjan 算法求强连通分量，size > 1 或存在自环的分量即循环引用。
//
//  说明：
//  - 这是诊断用保守启发式（与 leaks 一致），指针误判可能带来少量误报边，
//    已通过「两端类名前缀过滤 + 容器仅透传一层」控制噪音；
//  - 纯 Swift 类（非 NSObject 子类）同样支持：Swift 类在运行时也是真实注册的
//    ObjC 类（出现在 objc_copyClassList 中，class_getName 返回 "模块名.类名"），
//    且存储属性会注册为 ivar，按偏移扫描可拿到属性名；已实测验证。
//  - 堆枚举 API 在 iOS 同样可用（FBAllocationTracker 同款做法），适合在
//    Debug 菜单中集成；上架版本不建议包含。
//  - 本文件为独立命令行工具，输出走 stdout，不适用 App 内 LogUtil 约定。
//

import Foundation
import Darwin
import ObjectiveC.runtime

// swiftlint:disable force_unwrapping

// MARK: - C 函数类型（堆枚举）

/// memory_reader_t：跨进程读取回调；本进程内地址即可直接访问，原样返回
typealias MemoryReaderC = @convention(c) (task_t, vm_address_t, vm_size_t, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> kern_return_t
/// vm_range_recorder_t：枚举结果回调
typealias RangeRecorderC = @convention(c) (task_t, UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<vm_range_t>?, UInt32) -> Void

/// 注意：malloc_introspection_t 的函数指针在 arm64 上带 __ptrauth（PAC 签名），
/// 必须经由导入的结构体字段访问，让编译器生成认证指令；手动按裸指针 load
/// 出来再调用会跳到未认证地址，直接崩溃。

/// MALLOC_PTR_IN_USE_RANGE_TYPE：已分配且在用的指针
private let mallocPtrInUseRangeType: UInt32 = 1

/// 本进程 reader：远程地址即本地地址
private let inProcessReader: MemoryReaderC = { _, remoteAddress, _, localMemory in
    localMemory?.pointee = UnsafeMutableRawPointer(bitPattern: UInt(remoteAddress))
    return KERN_SUCCESS
}

/// 收集各 zone 回报的在用堆块区间
private final class HeapScanContext {
    var blockRanges: [Range<UInt>] = []
}

private let inProcessRecorder: RangeRecorderC = { _, context, type, ranges, count in
    guard type == mallocPtrInUseRangeType, count > 0, let ranges = ranges, let context = context else { return }
    let scanContext = Unmanaged<HeapScanContext>.fromOpaque(context).takeUnretainedValue()
    for index in 0..<Int(count) {
        let range = ranges[index]
        let start = UInt(range.address)
        scanContext.blockRanges.append(start ..< start &+ UInt(range.size))
    }
}

/// malloc_get_all_zones 未在 Swift 侧桥接，手动声明（C ABI 签名与 malloc.h 一致）
@_silgen_name("malloc_get_all_zones")
private func malloc_get_all_zones(
    _ task: task_t,
    _ reader: MemoryReaderC?,
    _ addresses: UnsafeMutablePointer<UnsafeMutablePointer<vm_address_t>?>,
    _ count: UnsafeMutablePointer<UInt32>
) -> kern_return_t

/// libobjc 导出的 isa 解码掩码：指针型 isa 上约为 ~0x7，arm64 非指针型 isa 上为
/// 0x0000007ffffffff8；isaWord & 掩码即类指针（leaks / malloc 工具同款做法）。
/// 不直接调用 object_getClass：对任意堆块调用它会在 isa 认证失败时触发运行时断言。
private let isaClassMask: UInt = {
    guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "objc_debug_isa_class_mask") else { return ~UInt(7) }
    return symbol.assumingMemoryBound(to: UInt.self).pointee
}()

/// tagged pointer 判定掩码：命中即不是堆块（arm64 上 tagged 位在高位，
/// 而非指针 isa 的 bit0 恒为 1，不能用低位判断）
private let taggedPointerMask: UInt = {
    guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "objc_debug_taggedpointer_mask") else { return 0 }
    return symbol.assumingMemoryBound(to: UInt.self).pointee
}()

/// Swift 函数值的代码指针通常是 mangled symbol。运行时的 swift_demangle 能在
/// 不依赖外部命令的情况下还原为 `closure #N in ...`，用于标明具体闭包来源。
private typealias SwiftDemangleC = @convention(c) (
    UnsafePointer<CChar>?, Int,
    UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
) -> UnsafeMutablePointer<CChar>?

private let swiftDemangle: SwiftDemangleC? = {
    guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "swift_demangle") else { return nil }
    return unsafeBitCast(symbol, to: SwiftDemangleC.self)
}()

// MARK: - Swift 反射元数据（weak / unowned 自动识别）

/// 与运行时 `_FieldReflectionMetadata` 相同的 C ABI 布局：
/// name 8 字节 + name free callback 8 字节 + isStrong 1 字节 +
/// isVar 1 字节 + 6 字节填充。字段类型是反射函数的返回值，
/// 不在这个结构体内；名称用完后必须调用 freeFunc 释放。
/// isStrong = false 即 weak / unowned / 间接枚举等非强持有——Swift 类可据此
/// 排除非强字段（ObjC 定义的类无此元数据，走 ivarLayout 路径）。
private typealias ReflectionNameFreeC = @convention(c) (UnsafePointer<CChar>?) -> Void

private struct SwiftFieldReflectionMetadata {
    var name: UnsafePointer<CChar>?
    var freeFunc: ReflectionNameFreeC?
    var isStrong: Bool
    var isVar: Bool
}

@_silgen_name("swift_reflectionMirror_recursiveCount")
private func swiftRecursiveChildCount(_ type: Any.Type) -> Int

@_silgen_name("swift_reflectionMirror_recursiveChildMetadata")
private func swiftRecursiveChildMetadata(
    _ type: Any.Type,
    index: Int,
    fieldMetadata: UnsafeMutablePointer<SwiftFieldReflectionMetadata>
) -> Any.Type

@_silgen_name("swift_reflectionMirror_recursiveChildOffset")
private func swiftRecursiveChildOffset(_ type: Any.Type, index: Int) -> Int

@_silgen_name("swift_getMetadataKind")
private func swiftMetadataKind(_ type: Any.Type) -> UInt

/// Swift ABI MetadataKind::Function。只有函数字段需要补扫第二个字的
/// context 指针，不能把所有多字字段都当成闭包。
private let swiftFunctionMetadataKind: UInt = 0x302

/// ObjC ARC layout 串的起点不是固定的 isa 后 8 字节，而是当前类
/// `word_align(instanceStart)`。使用 ObjC runtime 自身的 SPI 取值，
/// 与 runtime 处理 strong / weak layout 时的逻辑保持一致。
private typealias ObjCClassInstanceStartC = @convention(c) (AnyClass) -> UInt32

private let objcClassInstanceStart: ObjCClassInstanceStartC? = {
    guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "_class_getInstanceStart") else { return nil }
    return unsafeBitCast(symbol, to: ObjCClassInstanceStartC.self)
}()

/// 枚举当前进程全部在用堆块区间（块起始地址为 malloc 返回地址，即对象首地址）
func enumerateHeapBlockRanges() -> [Range<UInt>] {
    var zoneList: UnsafeMutablePointer<vm_address_t>? = nil
    var zoneCount: UInt32 = 0
    guard malloc_get_all_zones(mach_task_self_, nil, &zoneList, &zoneCount) == KERN_SUCCESS, zoneCount > 0 else { return [] }
    let scanContext = HeapScanContext()
    let contextPointer = Unmanaged.passRetained(scanContext).toOpaque()
    defer { Unmanaged.passRetained(scanContext).release() }
    for index in 0..<Int(zoneCount) {
        let zoneAddress = zoneList![index]
        guard let zonePointer = UnsafeRawPointer(bitPattern: UInt(zoneAddress)) else { continue }
        let zone = zonePointer.assumingMemoryBound(to: malloc_zone_t.self)
        guard let introspection = zone.pointee.introspect, let enumerator = introspection.pointee.enumerator else { continue }
        _ = enumerator(mach_task_self_, contextPointer, mallocPtrInUseRangeType, zoneAddress, inProcessReader, inProcessRecorder)
    }
    return scanContext.blockRanges
}

// MARK: - 图模型

struct HeapObject {
    let address: UInt
    let size: Int
    let classPointer: UInt
    let className: String
    /// true 表示这是 ObjC block（__NSMallocBlock__ 等 Block 类实例），
    /// 偏移 32 起的字是捕获的变量指针
    let isBlock: Bool
    /// isa 的 weakly_referenced 位（实测当前 arm64 运行时为 bit2）：
    /// true 只表示该对象被某处 weak 引用过（对象级 sticky 标记），
    /// 不指向任何具体边，不能用于判断某条边的强弱
    let weaklyReferenced: Bool
}

/// 一条引用边的持有语义。
/// 只有「运行时确实有元数据」时才给出确切结论；无法判定的一律标 unknown，
/// 不把未知伪装成 strong。
enum ReferenceOwnership: String, Codable {
    /// 明确强持有：Swift 反射 isStrong / ObjC ivarLayout / block layout STRONG
    case strong
    /// 明确归类为 weak（Swift Optional 非强字段 / ObjC weak ivar / ObjC block weak capture）
    case weak
    /// Swift unowned / unowned(unsafe)（isStrong=false 且字段类型非 Optional）
    case unowned
    /// 只确认不是 strong：ObjC ivarLayout 之外的 @ ivar，无法继续区分
    /// weak / __unsafe_unretained
    case nonStrong
    /// Swift 闭包捕获槽 / 桥接 block：运行时无 ownership 元数据，
    /// strong 与 weak 捕获槽位完全相同，无法判定
    case unknown

    /// 是否作为潜在强引用边展示；unknown 仍需展示，避免丢失可能的引用关系。
    var isStrongEdge: Bool { self == .strong || self == .unknown }

    /// 循环引用必须全部由已确认的 strong 边构成，unknown 不参与。
    var participatesInCycleDetection: Bool { self == .strong }

    var label: String {
        switch self {
        case .strong: return "strong"
        case .weak: return "weak"
        case .unowned: return "unowned"
        case .nonStrong: return "非强（weak/unsafe）"
        case .unknown: return "未知（捕获无元数据）"
        }
    }
}

struct ReferenceEdge {
    let from: UInt
    let to: UInt
    /// 通过 class_copyIvarList 解析出的属性名；容器透传边为容器属性名
    let ivarName: String?
    /// true 表示经由数组 / 字典等容器缓冲区透传得到的边
    let isIndirect: Bool
    /// 该边的持有语义；默认 strong 兼容既有构造点
    let ownership: ReferenceOwnership
}

// MARK: - 扫描器

final class MemoryGraphScanner {

    /// 只保留类名匹配任一前缀的对象，控制图规模与噪音；空数组表示不过滤，保留堆上全部对象
    let classPrefixes: [String]
    /// 兜底用：额外视作 weak、不参与强引用图与循环检测的 ivar 名。
    /// weak / unowned 已通过反射元数据（Swift 类）与 ivarLayout（ObjC 类）自动识别，
    /// 此列表仅在个别字段无法自动判定时手动补充。
    let weakIvarNames: Set<String>

    /// classPrefixes 传空数组（或不传）时不过滤，保留堆上全部对象；
    /// 全量扫描节点 / 边规模很大，仅建议排查疑难问题时使用
    init(classPrefixes: [String] = [], weakIvarNames: Set<String> = []) {
        self.classPrefixes = classPrefixes
        self.weakIvarNames = weakIvarNames
    }

    private(set) var objects: [HeapObject] = []
    /// 已确认 strong 与 unknown 边：共同参与引用图渲染；循环检测只使用 strong
    private(set) var edges: [ReferenceEdge] = []
    /// 非强引用边（weak / unowned / nonStrong）：单独展示，不参与强引用图与找环
    private(set) var nonStrongEdges: [ReferenceEdge] = []
    /// 循环引用：每个元素是一个环上的地址组（强连通分量）
    private(set) var cycles: [[UInt]] = []

    /// 地址 -> objects 下标
    private var objectIndexByAddress: [UInt: Int] = [:]
    /// 非对象容器块地址 -> 块大小（透传扫描用）
    private var containerSizeByAddress: [UInt: Int] = [:]
    /// 类指针 -> [ivar 偏移: 属性名]
    private var ivarNameMaps: [UInt: [Int: String]] = [:]
    /// 类指针 -> Swift 闭包 / 函数字段的 context 指针偏移。
    /// 仅对 MetadataKind::Function 补扫，避免把 struct / existential 内部字
    /// 误当成 strong 引用。
    private var swiftFunctionContextOffsets: [UInt: Set<Int>] = [:]
    /// 类指针 -> weak ivar 偏移集合（ivarLayout 自动识别；Swift 类为空集）
    /// 类指针 -> 非强字段偏移及运行时可确定的持有语义
    private var nonStrongIvarOffsetMaps: [UInt: [Int: ReferenceOwnership]] = [:]
    /// 容器块地址 -> 持有者（incoming 反查扫描时建立）
    private var containerOwnerByAddress: [UInt: (owner: UInt, ivarName: String?)] = [:]
    /// 容器块地址 -> 展示标签：incoming 反查中「无持有者容器」（如仅被 GCD 持有的
    /// block / Swift 闭包上下文）捕获对象时，以容器自身作为伪来源展示
    private var containerLabelByAddress: [UInt: String] = [:]
    /// block 类判定缓存
    private var blockClassCache: [UInt: Bool] = [:]
    /// 被类名前缀过滤、作为容器透传的 ObjC block 地址
    private var blockContainerAddresses = Set<UInt>()
    /// 代码地址 -> 精简后的符号名；未命中的地址单独缓存，避免全堆反查反复 dladdr
    private var closureSymbolByAddress: [UInt: String] = [:]
    private var unresolvedClosureSymbolAddresses = Set<UInt>()
    /// 主可执行文件名（basename）：仅对 App 自身二进制内的类做 Swift 反射。
    /// Xcode 16+ Debug 构建可能把业务代码放进 `<executable>.debug.dylib`，它与
    /// 主可执行文件同属可信 App 代码，也必须纳入；否则所有 Swift weak 字段会
    /// 因反射被跳过而退化为 unknown。
    private let mainExecutableName = Bundle.main.executablePath?.split(separator: "/").last.map(String.init)

    /// 执行完整扫描：分类节点 -> 解析边 -> 找环。
    /// 全量边解析在大堆上耗时分钟级，排查单对象请改用 identifyObjects() + referenceReport(of:)
    func scan() {
        identifyObjects()
        buildEdges()
        detectCycles()
    }

    // MARK: 按需引用查询（快速路径）

    /// 一条经过目标对象的循环引用链：edges 首尾相接（last.to == first.from），
    /// 每条边带属性名与「经容器透传」标记，可直接展开成可读链路
    struct CycleChain {
        let edges: [ReferenceEdge]
        /// 链上节点地址 -> 类名（含 block 标记）
        let classNameByAddress: [UInt: String]
    }

    /// 单对象引用关系报告
    struct ReferenceReport {
        let address: UInt
        let className: String
        let size: Int
        /// 该对象直接强引用的对象（含经容器透传的间接引用）
        let outgoing: [ReferenceEdge]
        /// 该对象的非强引用（weak / unowned / nonStrong），单独列出，不参与强引用图
        let nonStrongOutgoing: [ReferenceEdge]
        /// 目标对象的非强字段（字段名 -> 语义）。来自字段元数据，
        /// 即使 unowned 槽位不指向对象地址（无法成边）也能准确列出
        let nonStrongFields: [String: ReferenceOwnership]
        /// 强引用该对象的对象（逐层反查；weak / unowned 自动排除）
        let incoming: [ReferenceEdge]
        /// 来源对象地址 -> 反查层级（1 起）
        let incomingLevel: [UInt: Int]
        /// 报告中出现的地址 -> 类名（展示用）
        let classNameByAddress: [UInt: String]
        /// 经过该对象的循环引用链（定向 DFS 找出，最多 5 条）
        let cycles: [CycleChain]
    }

    /// 快速识别堆上对象：仅堆枚举 + isa 解码 + 前缀过滤，秒级完成。
    /// 之后可用 referenceReport(of:) 按需查询单对象引用关系
    @discardableResult
    func identifyObjects() -> [HeapObject] {
        buildNodes(blockRanges: enumerateHeapBlockRanges())
        return objects
    }

    /// 查询指定对象的引用关系。
    /// outgoing 直接解析对象内存（廉价）；incoming 逐层反查，
    /// 每层一次全堆定向扫描（对象 ivar + 容器元素），maxDepth 层即 maxDepth 次扫描。
    /// - Parameter address: 对象堆地址（HeapObject.address / ObjectIdentifier.rawValue）
    func referenceReport(of address: UInt, maxDepth: Int = 1) -> ReferenceReport? {
        guard let index = objectIndexByAddress[address] else { return nil }
        let target = objects[index]
        let references = directReferences(from: target)
        let outgoing = references.strong

        var allIncoming: [ReferenceEdge] = []
        var incomingLevel: [UInt: Int] = [:]
        var visited: Set<UInt> = [address]
        var currentTargets: Set<UInt> = [address]
        for level in 1...max(1, maxDepth) {
            let levelEdges = incomingSweep(targets: currentTargets)
            let newSources = Set(levelEdges.map { $0.from }).subtracting(visited)
            // 已访问来源（含目标自身经反向路径）的边不重复收录，每个来源只在首次发现层出现
            allIncoming.append(contentsOf: levelEdges.filter { newSources.contains($0.from) })
            for source in newSources { incomingLevel[source] = level }
            visited.formUnion(newSources)
            guard !newSources.isEmpty else { break }
            currentTargets = newSources
        }
        var classNameByAddress: [UInt: String] = [address: target.className]
        for edge in outgoing + references.nonStrong {
            if let targetIndex = objectIndexByAddress[edge.to] {
                classNameByAddress[edge.to] = Self.displayName(of: objects[targetIndex])
            }
        }
        for edge in allIncoming {
            if let sourceIndex = objectIndexByAddress[edge.from] {
                classNameByAddress[edge.from] = Self.displayName(of: objects[sourceIndex])
            } else if let label = containerLabelByAddress[edge.from] {
                // incoming 伪来源：无持有者的闭包 / block 堆块
                classNameByAddress[edge.from] = label
            }
        }
        let targetNameMap = ivarNameMap(for: target.classPointer)
        var nonStrongFields: [String: ReferenceOwnership] = [:]
        for (offset, ownership) in nonStrongIvarOwnership(for: target.classPointer) {
            if let name = fieldName(at: offset, in: targetNameMap) { nonStrongFields[name] = ownership }
        }
        let cycles = cycleChains(through: address)
        for cycle in cycles {
            classNameByAddress.merge(cycle.classNameByAddress) { current, _ in current }
        }
        return ReferenceReport(address: address,
                               className: target.className,
                               size: target.size,
                               outgoing: outgoing,
                               nonStrongOutgoing: references.nonStrong,
                               nonStrongFields: nonStrongFields,
                               incoming: allIncoming,
                               incomingLevel: incomingLevel,
                               classNameByAddress: classNameByAddress,
                               cycles: cycles)
    }

    /// 定向查找经过 address 的循环引用链：沿强引用边 DFS，只保留能回到目标的闭合路径。
    /// 与全图 Tarjan 不同，这里不构建全堆边表，只展开目标可达对象——保持按需查询的秒级性能。
    /// - Parameters:
    ///   - maxDepth: 链最大边数（含回到目标的那条），默认 6
    ///   - maxChains: 最多返回几条链，默认 5
    ///   - maxObjects: DFS 展开对象总数上限，默认 200，防止大图退化成全量扫描
    func cycleChains(through address: UInt,
                     maxDepth: Int = 6,
                     maxChains: Int = 5,
                     maxObjects: Int = 200) -> [CycleChain] {
        guard objectIndexByAddress[address] != nil else { return [] }
        var chains: [CycleChain] = []
        var seenChains = Set<String>()
        var visitedCount = 0
        var path: [ReferenceEdge] = []
        var onPath: Set<UInt> = [address]

        func nameOf(_ node: UInt) -> String {
            guard let index = objectIndexByAddress[node] else { return Self.hex(node) }
            return Self.displayName(of: objects[index])
        }

        func visit(_ current: UInt, _ depth: Int) {
            guard chains.count < maxChains, visitedCount < maxObjects, depth <= maxDepth,
                  let index = objectIndexByAddress[current] else { return }
            visitedCount += 1
            for edge in directCycleReferences(from: objects[index]) {
                guard chains.count < maxChains else { return }
                if edge.to == address {
                    // 闭合：path 中每个节点唯一（onPath 保证），构成简单环
                    let chain = path + [edge]
                    let key = chain.map { String($0.from) }.joined(separator: ">")
                    guard seenChains.insert(key).inserted else { continue }
                    var names: [UInt: String] = [:]
                    for link in chain {
                        names[link.from] = nameOf(link.from)
                        names[link.to] = nameOf(link.to)
                    }
                    chains.append(CycleChain(edges: chain, classNameByAddress: names))
                } else if depth < maxDepth, !onPath.contains(edge.to),
                          objectIndexByAddress[edge.to] != nil {
                    onPath.insert(edge.to)
                    path.append(edge)
                    visit(edge.to, depth + 1)
                    path.removeLast()
                    onPath.remove(edge.to)
                }
            }
        }
        visit(address, 1)
        return chains
    }

    /// 某个对象的「偏移 -> ownership」：类级元数据（属性三分） + 该 block 实例的
    /// extended layout（捕获槽），后者覆盖前者
    private func ownershipMap(for object: HeapObject) -> [Int: ReferenceOwnership] {
        nonStrongIvarOwnership(for: object.classPointer)
            .merging(blockCaptureOwnership(for: object)) { _, blockLayout in blockLayout }
    }

    /// 源对象直接引用：ivar 直指对象 / 经容器缓冲透传。
    /// 返回强边（参与图与找环）与非强边（weak/unowned/非强，单独展示，不参与找环）
    private func directReferences(from object: HeapObject) -> (strong: [ReferenceEdge], nonStrong: [ReferenceEdge]) {
        guard let base = UnsafeRawPointer(bitPattern: object.address) else { return ([], []) }
        let usableSize = min(Int(malloc_size(base)), object.size)
        guard usableSize >= 16 else { return ([], []) }
        let nameMap = ivarNameMap(for: object.classPointer)
        var strong: [ReferenceEdge] = []
        var nonStrong: [ReferenceEdge] = []
        var seen = Set<String>()
        for (offset, ownership) in scanOffsets(nameMap: nameMap, usableSize: usableSize,
                                               classPointer: object.classPointer,
                                               ownershipByOffset: ownershipMap(for: object)) {
            var edgeOwnership = ownership
            if let ivarName = fieldName(at: offset, in: nameMap), weakIvarNames.contains(ivarName) {
                edgeOwnership = .nonStrong // 手动白名单只能确认非强，无法二分 weak/unowned
            }
            let word = base.load(fromByteOffset: offset, as: UInt.self)
            guard word != 0, word & 1 == 0 else { continue }
            let ivarName = referenceLabel(for: object, at: offset, base: base, nameMap: nameMap)
            if let targetIndex = objectIndexByAddress[word] {
                let edge = ReferenceEdge(from: object.address,
                                         to: objects[targetIndex].address,
                                         ivarName: ivarName,
                                         isIndirect: false,
                                         ownership: edgeOwnership)
                if edgeOwnership.isStrongEdge {
                    appendEdge(edge, seen: &seen, into: &strong)
                } else {
                    appendEdge(edge, seen: &seen, into: &nonStrong)
                }
            } else if edgeOwnership.isStrongEdge,
                      let containerSize = containerSizeByAddress[word],
                      let containerBase = UnsafeRawPointer(bitPattern: word) {
                updateClosureContainerLabel(at: word, ownerLabel: ivarName,
                                            classPointer: object.classPointer, offset: offset)
                scanContainer(from: object.address,
                              ivarName: ivarName,
                              ownership: edgeOwnership,
                              containerBase: containerBase,
                              containerSize: min(containerSize, Int(malloc_size(containerBase))),
                              seen: &seen, into: &strong)
            }
        }
        return (strong, nonStrong)
    }

    private func directCycleReferences(from object: HeapObject) -> [ReferenceEdge] {
        directReferences(from: object).strong.filter(\.ownership.participatesInCycleDetection)
    }

    /// 一次全堆定向扫描：找出强引用 targets 中任一地址的对象。
    /// 对象 ivar 直指 → 直接边；ivar 指向容器且容器元素命中 → 记在容器持有者头上的间接边。
    /// 扫描中顺带建立「容器 -> 持有者」映射，后续层级反查复用
    private func incomingSweep(targets: Set<UInt>) -> [ReferenceEdge] {
        var result: [ReferenceEdge] = []
        var seen = Set<String>()
        for object in objects {
            guard let base = UnsafeRawPointer(bitPattern: object.address) else { continue }
            let usableSize = min(Int(malloc_size(base)), object.size)
            guard usableSize >= 16 else { continue }
            let nameMap = ivarNameMap(for: object.classPointer)
            for (offset, ownership) in scanOffsets(nameMap: nameMap, usableSize: usableSize,
                                                   classPointer: object.classPointer,
                                                   ownershipByOffset: ownershipMap(for: object)) {
                guard ownership.isStrongEdge else { continue }
                if let ivarName = fieldName(at: offset, in: nameMap), weakIvarNames.contains(ivarName) { continue }
                let word = base.load(fromByteOffset: offset, as: UInt.self)
                guard word != 0, word & 1 == 0 else { continue }
                let referenceLabel = referenceLabel(for: object, at: offset, base: base, nameMap: nameMap)
                if targets.contains(word) {
                    appendEdge(ReferenceEdge(from: object.address,
                                             to: word,
                                             ivarName: referenceLabel,
                                             isIndirect: false,
                                             ownership: ownership),
                               seen: &seen, into: &result)
                } else if containerSizeByAddress[word] != nil, containerOwnerByAddress[word] == nil {
                    updateClosureContainerLabel(at: word, ownerLabel: referenceLabel,
                                                classPointer: object.classPointer, offset: offset)
                    containerOwnerByAddress[word] = (object.address, referenceLabel)
                }
            }
        }
        for (containerAddress, _) in containerSizeByAddress {
            if let owner = containerOwnerByAddress[containerAddress] {
                sweepContainer(from: owner.owner,
                               ivarName: owner.ivarName,
                               containerAddress: containerAddress,
                               targets: targets,
                               seen: &seen, into: &result)
            } else {
                // 无持有者：仅被 GCD / timer 等系统设施持有的 block / Swift 闭包上下文，
                // 以容器自身地址作为伪来源报告「闭包捕获了目标」。
                // 噪音过滤（实测 GCD arena 等大型 OS 内部块会产生大量垃圾边）：
                // 闭包上下文 / block 都是小块（≤ 4KB），首字是静态元数据指针
                // （block 类 isa / Swift 闭包元数据位于二进制或 shared cache，
                // 不归属 malloc zone）；大型块与首字指向堆内的块一律跳过。
                // 代价：元数据在堆上的泛型闭包上下文会被漏掉
                guard let base = UnsafeRawPointer(bitPattern: containerAddress),
                      (containerSizeByAddress[containerAddress] ?? 0) <= 4096 else { continue }
                let meta = base.load(as: UInt.self)
                guard meta & 1 == 0, meta & 7 == 0,
                      let metaPointer = UnsafeRawPointer(bitPattern: meta),
                      malloc_zone_from_ptr(metaPointer) == nil else { continue }
                let captureLabel = blockContainerAddresses.contains(containerAddress)
                    ? "block 捕获（\(containerLabelByAddress[containerAddress] ?? "未知 block")）"
                    : "Swift 匿名闭包捕获（无可用代码指针）"
                sweepContainer(from: containerAddress,
                               ivarName: captureLabel,
                               containerAddress: containerAddress,
                               targets: targets,
                               ownership: .unknown,
                               seen: &seen, into: &result)
            }
        }
        return result
    }

    /// 反查方向的容器扫描：命中 targets 中任一地址即建边（from = source）。
    /// 嵌套容器递归（ObjC block 桥接 Swift 闭包时为 block -> Swift 上下文 ->
    /// 捕获值两级链），depth 限制递归层数防止失控
    private func sweepContainer(from source: UInt, ivarName: String?, containerAddress: UInt,
                                targets: Set<UInt>, ownership: ReferenceOwnership = .strong,
                                depth: Int = 3, seen: inout Set<String>, into: inout [ReferenceEdge]) {
        guard depth >= 1, containerAddress != source,
              let base = UnsafeRawPointer(bitPattern: containerAddress) else { return }
        let context = containerContext(base)
        let effective: ReferenceOwnership = context == .buffer ? ownership : .unknown
        let size = min(containerSizeByAddress[containerAddress] ?? 0, Int(malloc_size(base)))
        var offset = 8
        while offset + 8 <= size {
            let word = base.load(fromByteOffset: offset, as: UInt.self)
            if word != 0, word & 1 == 0 {
                if targets.contains(word) {
                    appendEdge(ReferenceEdge(from: source,
                                             to: word,
                                             ivarName: ivarName,
                                             isIndirect: true,
                                             ownership: effective),
                               seen: &seen, into: &into)
                } else if depth > 1, word != source, containerSizeByAddress[word] != nil {
                    sweepContainer(from: source,
                                   ivarName: ivarName,
                                   containerAddress: word,
                                   targets: targets,
                                   ownership: effective,
                                   depth: depth - 1,
                                   seen: &seen, into: &into)
                }
            }
            offset += 8
        }
    }

    /// 展示用类名：block 补充标记，与普通对象区分
    private static func displayName(of object: HeapObject) -> String {
        object.isBlock ? object.className + "（block）" : object.className
    }

    /// 引用边展示名：普通字段沿用属性名；Swift 函数字段的 context 字补充
    /// `closure #N in ...`；ObjC block 捕获槽补充 invoke symbol 与槽位编号。
    /// 符号化失败时仍保留属性名 / 捕获槽位，不影响引用关系与 ownership 判定。
    private func referenceLabel(for object: HeapObject, at offset: Int,
                                base: UnsafeRawPointer, nameMap: [Int: String]) -> String? {
        let field = fieldName(at: offset, in: nameMap)
        if swiftFunctionContextOffsets[object.classPointer]?.contains(offset) == true,
           offset >= MemoryLayout<UInt>.size {
            let functionAddress = base.load(fromByteOffset: offset - MemoryLayout<UInt>.size,
                                            as: UInt.self)
            if let symbol = closureSymbol(at: functionAddress) {
                return "\(field ?? "Swift 闭包") · \(symbol)"
            }
            return field.map { "\($0) · Swift 闭包" } ?? "Swift 闭包"
        }
        if object.isBlock, offset >= 32 {
            let capture = "block 捕获[\((offset - 32) / MemoryLayout<UInt>.size)]"
            let invokeAddress = base.load(fromByteOffset: 16, as: UInt.self)
            if let symbol = closureSymbol(at: invokeAddress) {
                return "\(capture) · \(symbol)"
            }
            return capture
        }
        return field
    }

    /// 闭包 context 本身没有 isa；当它来自具名函数字段时，把符号化结果同步到
    /// 伪节点标签，使后续 incoming 反查也能看到闭包身份。
    private func updateClosureContainerLabel(at address: UInt, ownerLabel: String?,
                                             classPointer: UInt, offset: Int) {
        guard swiftFunctionContextOffsets[classPointer]?.contains(offset) == true else { return }
        containerLabelByAddress[address] = ownerLabel.map { "Swift 闭包（\($0)）" } ?? "Swift 闭包"
    }

    /// dladdr 只做代码地址到符号的映射，不解引用目标地址；Swift 符号再经
    /// swift_demangle 还原。这里只精简 thunk 前缀并限制长度，保留闭包序号与
    /// 所在函数，避免多个 closure #1 脱离上下文后重名。
    private func closureSymbol(at address: UInt) -> String? {
        guard address != 0 else { return nil }
        if let cached = closureSymbolByAddress[address] { return cached }
        if unresolvedClosureSymbolAddresses.contains(address) { return nil }
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: address),
              dladdr(pointer, &info) != 0,
              let symbolPointer = info.dli_sname else {
            unresolvedClosureSymbolAddresses.insert(address)
            return nil
        }
        let mangled = String(cString: symbolPointer)
        let demangled = demangle(mangled) ?? mangled
        var concise = demangled
        if let closureRange = concise.range(of: "closure #") {
            concise = String(concise[closureRange.lowerBound...])
        } else {
            concise = concise.replacingOccurrences(of: "partial apply forwarder for ", with: "")
        }
        if concise.count > 220 {
            concise = String(concise.prefix(217)) + "..."
        }
        closureSymbolByAddress[address] = concise
        return concise
    }

    private func demangle(_ symbol: String) -> String? {
        guard let swiftDemangle else { return nil }
        return symbol.withCString { pointer -> String? in
            guard let output = swiftDemangle(pointer, symbol.utf8.count, nil, nil, 0) else { return nil }
            defer { free(output) }
            return String(cString: output)
        }
    }

    // MARK: 节点识别

    private func buildNodes(blockRanges: [Range<UInt>]) {
        // 已注册 ObjC 类指针集合：isa 解码结果不在此集合中的堆块不是有效对象
        var classCount: UInt32 = 0
        guard let classList = objc_copyClassList(&classCount) else { return }
        // 注意：这里不能通过 AutoreleasingUnsafeMutablePointer<AnyClass> 的下标读取，
        // 该访问路径会触发 ObjC 消息转发导致崩溃；按裸内存逐字读类指针即可
        let classListBase = UnsafeRawPointer(classList)
        var registeredClasses = Set<UInt>(minimumCapacity: Int(classCount))
        for index in 0..<Int(classCount) {
            registeredClasses.insert(classListBase.load(fromByteOffset: index * 8, as: UInt.self))
        }
        for range in blockRanges {
            // NSObject 至少 16 字节（isa + 一个指针位）
            guard range.count >= 16, let base = UnsafeRawPointer(bitPattern: range.lowerBound) else { continue }
            let isaWord = base.load(as: UInt.self)
            guard isaWord != 0, isaWord & taggedPointerMask == 0 else { continue }
            let classPointer = isaWord & isaClassMask
            guard registeredClasses.contains(classPointer) else {
                // 无有效 isa 的块：Swift 闭包上下文（首字是元数据指针而非类 isa）、
                // Swift Array/Dictionary 缓冲区等容器。捕获单个对象的 Swift 闭包
                // 上下文仅 16 字节（元数据 8 + 捕获 8），阈值不能高于 16
                if range.count >= 16 {
                    containerSizeByAddress[range.lowerBound] = Int(range.count)
                    containerLabelByAddress[range.lowerBound] = "匿名堆块（Swift 闭包/缓冲区）"
                }
                continue
            }
            let anyClass: AnyClass = unsafeBitCast(classPointer, to: AnyClass.self)
            // Swift 类的 class_getName 返回 "模块名.类名"，取最后一段做前缀匹配
            let className = String(cString: class_getName(anyClass))
            let bareClassName = className.split(separator: ".").last.map(String.init) ?? className
            if classPrefixes.isEmpty || classPrefixes.contains(where: { bareClassName.hasPrefix($0) || className.hasPrefix($0) }) {
                objectIndexByAddress[range.lowerBound] = objects.count
                objects.append(HeapObject(address: range.lowerBound,
                                          size: Int(range.count),
                                          classPointer: classPointer,
                                          className: className,
                                          isBlock: isBlockClass(classPointer, className: className),
                                          weaklyReferenced: isaWord & 0x4 != 0))
            } else {
                // 被前缀过滤掉的正常对象（如 NSArray、NSString、__NSMallocBlock__），
                // 同样作为容器透传，使 [MGObserver] 存进 NSArray / 闭包捕获的场景不丢边
                containerSizeByAddress[range.lowerBound] = Int(range.count)
                if isBlockClass(classPointer, className: className) {
                    blockContainerAddresses.insert(range.lowerBound)
                    let invokeAddress = range.count >= 24 ? base.load(fromByteOffset: 16, as: UInt.self) : 0
                    if let symbol = closureSymbol(at: invokeAddress) {
                        containerLabelByAddress[range.lowerBound] = "\(className)（block：\(symbol)）"
                    } else {
                        containerLabelByAddress[range.lowerBound] = "\(className)（block）"
                    }
                } else {
                    containerLabelByAddress[range.lowerBound] = className
                }
            }
        }
    }

    /// 是否为 ObjC block 类（__NSMallocBlock__ / __NSGlobalBlock__ 等，均继承 NSBlock）。
    /// block 堆块是注册类、可被正常识别为对象；其偏移 32 起（isa + flags/invoke/descriptor
    /// 共 32 字节头部）的字是捕获变量指针，走无 ivar 信息的全字扫描自然建出捕获边
    private func isBlockClass(_ classPointer: UInt, className: String) -> Bool {
        if let cached = blockClassCache[classPointer] { return cached }
        var result = false
        if className.hasPrefix("__NS"), className.hasSuffix("Block__") {
            result = true
        } else if let nsBlock = NSClassFromString("NSBlock") {
            // 名称兜底失败时沿继承链查 NSBlock 基类
            var current: AnyClass? = unsafeBitCast(classPointer, to: AnyClass.self)
            while let cls = current {
                if cls == nsBlock { result = true; break }
                current = class_getSuperclass(cls)
            }
        }
        blockClassCache[classPointer] = result
        return result
    }

    /// 解析 ObjC BlockDescriptor 的 extended layout，返回「捕获槽偏移 -> ownership」。
    /// libclosure 公开 ABI（Block_private.h）：
    /// - 仅当 flags 带 BLOCK_HAS_EXTENDED_LAYOUT(1<<31) 时有效；
    /// - layout 值 < 0x1000 为紧凑编码 0xXYZ：X 个 strong、Y 个 byref、Z 个 weak 指针；
    /// - layout 值 >= 0x1000 时指向字节串，每字节 0xPN，P=操作码：
    ///   1 非对象字节 / 2 非对象字 / 3 strong / 4 byref / 5 weak / 6 unretained，
    ///   N 为数量，0x00 终止；
    /// - 捕获区从偏移 32 起（isa/flags/reserved/invoke/descriptor 头部）。
    /// Swift 桥接的 @convention(block) 不带 extended layout（实测 flags=0x43000002），
    /// 返回空字典：其 weak/unowned 捕获语义在 Swift 闭包上下文层，那里没有元数据可判。
    private func blockCaptureOwnership(for object: HeapObject) -> [Int: ReferenceOwnership] {
        guard object.isBlock, let base = UnsafeRawPointer(bitPattern: object.address) else { return [:] }
        let usableSize = min(Int(malloc_size(base)), object.size)
        guard usableSize >= 40 else { return [:] }
        let flags = base.load(fromByteOffset: 8, as: UInt32.self)
        guard flags & (1 << 31) != 0 else { return [:] } // BLOCK_HAS_EXTENDED_LAYOUT
        let descriptor = base.load(fromByteOffset: 24, as: UInt.self)
        var index = 2 // reserved + size
        if flags & (1 << 25) != 0 { index += 2 } // BLOCK_HAS_COPY_DISPOSE
        if flags & (1 << 30) != 0 { index += 1 } // BLOCK_HAS_SIGNATURE
        guard let layout = safeReadUInt(descriptor + UInt(index * 8)) else { return [:] }
        var result: [Int: ReferenceOwnership] = [:]
        var offset = 32
        func assign(_ count: Int, _ ownership: ReferenceOwnership) {
            for _ in 0..<min(count, 64) where offset + 8 <= usableSize {
                result[offset] = ownership
                offset += 8
            }
        }
        if layout < 0x1000 {
            assign(Int((layout >> 8) & 0xF), .strong)
            assign(Int((layout >> 4) & 0xF), .unknown) // byref 槽指向 __block 结构
            assign(Int(layout & 0xF), .weak)
        } else {
            for position in 0..<128 {
                guard let byte = safeReadByte(layout + UInt(position)) else { break }
                if byte == 0 { break }
                let op = byte >> 4, count = Int(byte & 0xF)
                switch op {
                case 1: offset += count                         // 非对象字节
                case 2: offset += count * 8                     // 非对象字
                case 3: assign(count, .strong)
                case 4: assign(count, .unknown)                  // byref
                case 5: assign(count, .weak)
                case 6: assign(count, .unowned)                  // __unsafe_unretained ≈ unowned
                default: break
                }
            }
        }
        return result
    }

    /// Swift 闭包上下文判定：首字指向 HeapLocalVariableMetadata（kind = 0x400）。
    /// 这类容器里的捕获槽没有 ownership 元数据，透传边必须标 unknown；
    /// 数组 / 字典等普通缓冲区的元素仍是 strong。
    /// 安全读取任意地址的 8 字节：走 Mach vm_read_overwrite，无效地址返回 nil
    /// 而不是 EXC_BAD_ACCESS。dladdr 只确认「地址落在某个 image 范围内」，
    /// 不保证可读——真机实测容器首字为垃圾值 0x10d010101030110 时，
    /// dladdr 后继续解引用会崩在 swift::initializeWithCopy。
    private func safeReadUInt(_ address: UInt) -> UInt? {
        guard address != 0 else { return nil }
        var value: UInt = 0
        var outSize: vm_size_t = 0
        let result = withUnsafeMutableBytes(of: &value) { buffer -> kern_return_t in
            vm_read_overwrite(mach_task_self_,
                              vm_address_t(address),
                              vm_size_t(MemoryLayout<UInt>.size),
                              vm_address_t(UInt(bitPattern: buffer.baseAddress)),
                              &outSize)
        }
        guard result == KERN_SUCCESS, outSize == MemoryLayout<UInt>.size else { return nil }
        return value
    }

    /// 安全读取 1 字节（block extended layout 的字节串可能跨页 / 落在不可读段）
    private func safeReadByte(_ address: UInt) -> UInt8? {
        guard address != 0 else { return nil }
        var value: UInt8 = 0
        var outSize: vm_size_t = 0
        let result = withUnsafeMutableBytes(of: &value) { buffer -> kern_return_t in
            vm_read_overwrite(mach_task_self_,
                              vm_address_t(address),
                              vm_size_t(1),
                              vm_address_t(UInt(bitPattern: buffer.baseAddress)),
                              &outSize)
        }
        guard result == KERN_SUCCESS, outSize == 1 else { return nil }
        return value
    }

    /// 容器上下文判定三态：Swift 闭包上下文 / 普通缓冲区 / 元数据读不到。
    /// 读不到时边标 unknown（保守），绝不冒充 strong。
    private enum ContainerContext {
        case closure
        case buffer
        case unreadable
    }

    private func containerContext(_ containerBase: UnsafeRawPointer) -> ContainerContext {
        let meta = containerBase.load(as: UInt.self) // 容器块自身是有效堆内存
        guard meta != 0, meta % 8 == 0,
              let metaPointer = UnsafeRawPointer(bitPattern: meta),
              malloc_zone_from_ptr(metaPointer) == nil else { return .buffer }
        guard let kind = safeReadUInt(meta) else { return .unreadable }
        return (kind & 0xfff) == 0x400 ? .closure : .buffer // MetadataKind::HeapLocalVariable
    }

    // MARK: 引用边解析

    /// ObjC ivarLayout 解析：每字节高 4 位是跳过的字数，低 4 位是连续引用字数。
    /// strong 与 weak 布局编码格式相同，分别由 class_getIvarLayout /
    /// class_getWeakIvarLayout 返回。布局从当前类的 aligned instanceStart 起计数，
    /// 继承链上每个类的起点都不同。
    private func ivarLayoutOffsets(_ layout: UnsafePointer<UInt8>?, baseOffset: Int) -> Set<Int> {
        guard let layout else { return [] }
        let base = UInt(bitPattern: layout)
        var offsets = Set<Int>()
        var offset = baseOffset
        var position = 0
        while position < 64 {
            guard let byte = safeReadByte(base + UInt(position)) else { break }
            position += 1
            if byte == 0 { break }
            offset += Int(byte >> 4) * 8
            for _ in 0..<(byte & 0x0F) {
                offsets.insert(offset)
                offset += 8
                if offset > 1 << 20 { return offsets } // 防御：布局异常时不失控
            }
        }
        return offsets
    }

    /// `_class_getInstanceStart` 在 Apple runtime 可用；若未导出，回退到
    /// 父类 instance size 的字对齐值。这个回退覆盖常规 ObjC 布局，
    /// 但无法完整复制 runtime 的 ivar sliding，因此优先使用 SPI。
    private func ivarLayoutBaseOffset(for anyClass: AnyClass) -> Int {
        if let objcClassInstanceStart {
            return Int(objcClassInstanceStart(anyClass))
        }
        guard let superclass = class_getSuperclass(anyClass) else { return 0 }
        let wordSize = MemoryLayout<UInt>.size
        let superclassSize = class_getInstanceSize(superclass)
        return (superclassSize + wordSize - 1) & ~(wordSize - 1)
    }

    private func ivarNameMap(for classPointer: UInt) -> [Int: String] {
        if let cached = ivarNameMaps[classPointer] { return cached }
        var map: [Int: String] = [:]
        var encodings: [Int: String] = [:]
        var strongOffsets = Set<Int>()
        var weakLayoutOffsets = Set<Int>()
        var currentClass: AnyClass? = unsafeBitCast(classPointer, to: AnyClass.self)
        while let anyClass = currentClass {
            var ivarCount: UInt32 = 0
            if let ivars = class_copyIvarList(anyClass, &ivarCount) {
                for index in 0..<Int(ivarCount) {
                    let ivar = ivars[index]
                    guard let namePointer = ivar_getName(ivar) else { continue }
                    let name = String(cString: namePointer)
                    let offset = Int(ivar_getOffset(ivar))
                    if map[offset] == nil {
                        map[offset] = name
                        encodings[offset] = ivar_getTypeEncoding(ivar).map { String(cString: $0) }
                    }
                }
            }
            let layoutBaseOffset = ivarLayoutBaseOffset(for: anyClass)
            strongOffsets.formUnion(ivarLayoutOffsets(class_getIvarLayout(anyClass),
                                                       baseOffset: layoutBaseOffset))
            weakLayoutOffsets.formUnion(ivarLayoutOffsets(class_getWeakIvarLayout(anyClass),
                                                           baseOffset: layoutBaseOffset))
            if anyClass == NSObject.self { break }
            currentClass = class_getSuperclass(anyClass)
        }
        // 关键事实（实测）：Swift 类的 ivar 用 ivar_getTypeEncoding 得到空字符串，
        // 且 class_getIvarLayout / class_getWeakIvarLayout 都返回 nil。
        // 因此 Swift 类一旦拿不到反射元数据，就既没有 isStrong 也没有 ivarLayout，
        // 若默认 strong 会把 weak 属性误标成 strong（真机报告里的实际错误）。
        // 处理：ObjC 类用两份布局精确标注；Swift 类反射不可用时标 unknown 而非 strong。
        let hasSwiftIvarSignature = encodings.values.contains { $0.isEmpty }
        var ownershipByOffset: [Int: ReferenceOwnership] = [:]
        for (offset, encoding) in encodings where offset > 0 {
            if encoding.hasPrefix("@") {
                if weakLayoutOffsets.contains(offset) {
                    ownershipByOffset[offset] = .weak
                } else if !strongOffsets.contains(offset) {
                    // ObjC 里 __weak 与 __unsafe_unretained 编码相同，无 weak 布局时无法二分
                    ownershipByOffset[offset] = .nonStrong
                }
            } else if encoding.isEmpty {
                ownershipByOffset[offset] = .unknown
            }
        }
        // 反射调用安全守卫（真机 EXC_BAD_ACCESS 崩在 ClassImpl::recursiveCount，
        // 崩溃类指针均落在堆地址区间）：
        // 1) Aspects / KVO 等运行时动态子类的 metadata 位于 malloc 堆，不能直接
        //    反射；向上找到最近的静态 App 父类，使用父类字段元数据和绝对偏移。
        // 2) 仅对主可执行文件及同名 debug dylib 内的静态类做反射：预编译 Pod /
        //    系统动态库存在元数据兼容性风险。
        // 注意：不能因为 class_getName 无模块点号就跳过反射——@objc(自定义名)
        // 的 Swift 类同样无点号，跳过会让它的 weak 属性失去唯一可用的 isStrong
        // 来源。用「ivar 类型编码为空」识别 Swift 类，对它们也尝试反射；
        // 纯 ObjC 类（编码为 '@' 等）反射返回 0 字段，本就不尝试，零风险。
        let runtimeClass: AnyClass = unsafeBitCast(classPointer, to: AnyClass.self)
        guard let reflectionClass = safeReflectionClass(startingAt: runtimeClass) else {
            // 反射不可用：Swift 字段保持 unknown（不冒充 strong），ObjC 字段走布局结论
            ivarNameMaps[classPointer] = map
            nonStrongIvarOffsetMaps[classPointer] = ownershipByOffset
            return map
        }
        let reflectionClassName = String(cString: class_getName(reflectionClass))
        guard reflectionClassName.contains(".") || hasSwiftIvarSignature else {
            ivarNameMaps[classPointer] = map
            nonStrongIvarOffsetMaps[classPointer] = ownershipByOffset
            return map
        }
        // Swift 定义类的反射元数据逐字段给出 isStrong：weak 与 unowned 均为 false。
        // 本工具按字段形态统一归类：Optional 非强字段标 weak，非 Optional 标 unowned；
        // `unowned var value: T?` 也按 weak 展示，不再单列 nonStrong。
        // 反射偏移是实例绝对偏移、与 ivar_getOffset 对齐，且自动含父类字段。
        let reflectionType: Any.Type = reflectionClass
        let fieldCount = swiftRecursiveChildCount(reflectionType)
        var functionContextOffsets = Set<Int>()
        if fieldCount > 0, fieldCount <= 256 {
            for index in 0..<fieldCount {
                var info = SwiftFieldReflectionMetadata(name: nil,
                                                        freeFunc: nil,
                                                        isStrong: true,
                                                        isVar: false)
                let fieldType = swiftRecursiveChildMetadata(reflectionType, index: index, fieldMetadata: &info)
                let reflectionOffset = swiftRecursiveChildOffset(reflectionType, index: index)
                // 反射偏移与 ivar 偏移在属性包装器 / 继承字段等场景可能不一致；
                // 用字段名反查 ivar 偏移，两个偏移都写入，避免 weak 字段漏标
                let fieldName = info.name.map { String(cString: $0) }
                info.freeFunc?(info.name)
                let matchedIvarOffset: Int? = fieldName.flatMap { name in
                    self.ivarOffset(forReflectionFieldName: name, in: map)
                }
                var offsets: Set<Int> = [reflectionOffset]
                if let matchedIvarOffset { offsets.insert(matchedIvarOffset) }
                let isOptional = "\(fieldType)".hasPrefix("Optional<")
                let isFunction = swiftMetadataKind(fieldType) == swiftFunctionMetadataKind
                for offset in offsets {
                    if info.isStrong {
                        ownershipByOffset.removeValue(forKey: offset)
                    } else {
                        ownershipByOffset[offset] = isOptional ? .weak : .unowned
                    }
                    if isFunction {
                        functionContextOffsets.insert(offset + MemoryLayout<UInt>.size)
                    }
                }
            }
        }
        swiftFunctionContextOffsets[classPointer] = functionContextOffsets
        ivarNameMaps[classPointer] = map
        nonStrongIvarOffsetMaps[classPointer] = ownershipByOffset
        return map
    }

    /// 指定类的非强字段偏移 -> 确切语义
    private func nonStrongIvarOwnership(for classPointer: UInt) -> [Int: ReferenceOwnership] {
        _ = ivarNameMap(for: classPointer) // 顺带填充缓存
        return nonStrongIvarOffsetMaps[classPointer] ?? [:]
    }

    /// Swift 字段描述通常使用源码名 `delegate`，ObjC runtime 在部分继承 / 暴露
    /// 场景会把同一存储字段命名为 `_delegate`。反射偏移理论上可直接使用，但
    /// ObjC heritage 的类会从 ivar 表取偏移；把 ownership 同步写入实际 ivar
    /// 偏移，避免 weak 字段在最终扫描时因命名差异回退成 strong。
    private func ivarOffset(forReflectionFieldName fieldName: String,
                            in nameMap: [Int: String]) -> Int? {
        if let exact = nameMap.first(where: { $0.value == fieldName })?.key { return exact }
        let normalizedFieldName = normalizedStorageName(fieldName)
        let matches = nameMap.filter { normalizedStorageName($0.value) == normalizedFieldName }
        return matches.count == 1 ? matches.first?.key : nil
    }

    private func normalizedStorageName(_ name: String) -> String {
        let lazyStoragePrefix = "$__lazy_storage_$_"
        var result = name.hasPrefix(lazyStoragePrefix)
            ? String(name.dropFirst(lazyStoragePrefix.count))
            : name
        while result.hasPrefix("_") { result.removeFirst() }
        return result
    }

    /// 类元数据是否位于 malloc 管理的堆内存（动态创建的类、泛型特化注册等）。
    /// 类指针可能不在堆块起始处（类与元类同块分配），不能用块起始地址集合判断；
    /// malloc_zone_from_ptr 对任意 malloc 内存（含块内偏移）都返回归属 zone，
    /// 静态元数据在二进制数据段 / shared cache，不归属任何 zone。
    private func isHeapResidentMetadata(_ classPointer: UInt) -> Bool {
        guard let pointer = UnsafeRawPointer(bitPattern: classPointer) else { return true }
        return malloc_zone_from_ptr(pointer) != nil
    }

    /// Aspects / KVO 通过 objc_allocateClassPair 创建的动态子类没有可反射的 Swift
    /// 类型描述符，但其继承字段仍沿用静态父类的绝对偏移。向上寻找最近的 App 静态类，
    /// 既避开堆 metadata 崩溃，也能恢复动态子类继承属性的 strong / weak 信息。
    private func safeReflectionClass(startingAt runtimeClass: AnyClass) -> AnyClass? {
        var currentClass: AnyClass? = runtimeClass
        while let anyClass = currentClass {
            let pointer = UInt(bitPattern: unsafeBitCast(anyClass, to: UnsafeRawPointer.self))
            if !isHeapResidentMetadata(pointer), isAppReflectionImage(anyClass) {
                return anyClass
            }
            if anyClass == NSObject.self { break }
            currentClass = class_getSuperclass(anyClass)
        }
        return nil
    }

    /// 类所属镜像路径（主可执行文件 / 各动态库），用于限定反射范围
    private func reflectionImagePath(_ anyClass: AnyClass) -> String? {
        class_getImageName(anyClass).map { String(cString: $0) }
    }

    /// Xcode 的 Debug Dylib Support 会让 `class_getImageName` 返回
    /// `AppName.debug.dylib`，而 `Bundle.main.executablePath` 仍是 `AppName`。
    /// 只按这两个 basename 放行，不扩大到 Pods / 系统动态库，保留反射防崩边界。
    private func isAppReflectionImage(_ anyClass: AnyClass) -> Bool {
        guard let mainExecutableName else { return true }
        guard let imageName = reflectionImagePath(anyClass)?.split(separator: "/").last.map(String.init) else {
            return false
        }
        return imageName == mainExecutableName || imageName == "\(mainExecutableName).debug.dylib"
    }

    private func buildEdges() {
        edges = []
        nonStrongEdges = []
        var seen = Set<String>()
        for object in objects {
            let references = directReferences(from: object)
            for edge in references.strong where seen.insert(Self.edgeKey(edge)).inserted {
                edges.append(edge)
            }
            for edge in references.nonStrong where seen.insert(Self.edgeKey(edge)).inserted {
                nonStrongEdges.append(edge)
            }
        }
    }

    private static func edgeKey(_ edge: ReferenceEdge) -> String {
        "\(edge.from)->\(edge.to)|\(edge.ivarName ?? "-")|\(edge.isIndirect)|\(edge.ownership.rawValue)"
    }

    /// 偏移对应的字段名：字段内部字（如闭包字段的上下文指针字）回退取所属字段起始名
    private func fieldName(at offset: Int, in nameMap: [Int: String]) -> String? {
        if let name = nameMap[offset] { return name }
        guard let fieldStart = nameMap.keys.filter({ $0 > 0 && $0 < offset && $0 % 8 == 0 }).max() else { return nil }
        return nameMap[fieldStart]
    }

    /// 解析扫描字偏移，返回（偏移, 持有语义）：
    /// - 有 ivar 信息时用已知字段偏移（过滤非 8 字节对齐）；
    /// - Swift 反射确认为 function 的字段额外补扫内部字：函数值宽 16 字节
    ///   （函数指针 + 上下文指针），上下文指针位于字段偏移 +8 处，
    ///   仅当该字不属于下一个字段时补扫。ObjC 类不补扫，避免扫进
    ///   struct ivar 内部或填充区产生噪音；
    /// - 无 ivar 信息时回退从 isa 之后的逐字全扫
    private func scanOffsets(nameMap: [Int: String], usableSize: Int, classPointer: UInt,
                             ownershipByOffset: [Int: ReferenceOwnership]) -> [(offset: Int, ownership: ReferenceOwnership)] {
        func ownership(_ offset: Int) -> ReferenceOwnership { ownershipByOffset[offset] ?? .strong }
        var result: [(offset: Int, ownership: ReferenceOwnership)] = []
        // 偏移 0 恒为 isa（block 类会暴露名为 isa 的 ivar），不是引用字段；
        // 过滤后无有效字段（如 __NSMallocBlock__ 仅剩 isa）则回退全字扫描
        let fieldOffsets = nameMap.keys.filter { $0 > 0 && $0 % 8 == 0 && $0 + 8 <= usableSize }.sorted()
        if fieldOffsets.isEmpty {
            for offset in stride(from: 8, to: usableSize - 7, by: 8) {
                result.append((offset, ownership(offset)))
            }
            return result
        }
        let functionContexts = swiftFunctionContextOffsets[classPointer] ?? []
        for offset in fieldOffsets {
            let fieldOwnership = ownership(offset)
            result.append((offset, fieldOwnership))
            let contextOffset = offset + MemoryLayout<UInt>.size
            if functionContexts.contains(contextOffset),
               !nameMap.keys.contains(contextOffset),
               contextOffset + MemoryLayout<UInt>.size <= usableSize {
                result.append((contextOffset, fieldOwnership))
            }
        }
        return result
    }

    /// 透传扫描容器块：跳过 8 字节元数据头，逐字找已识别对象；
    /// 命中嵌套容器（block 内嵌 Swift 闭包上下文等桥接链）时递归，
    /// depth 限制递归层数防止失控
    private func scanContainer(from source: UInt, ivarName: String?, ownership: ReferenceOwnership,
                               containerBase: UnsafeRawPointer, containerSize: Int,
                               seen: inout Set<String>, into: inout [ReferenceEdge], depth: Int = 3) {
        // Swift 闭包上下文（首字指向 HeapLocalVariableMetadata）里的捕获槽没有
        // ownership 元数据：strong 与 weak 捕获槽位完全相同，只能标 unknown。
        // 数组 / 字典等普通缓冲区的元素仍是 strong。
        let context = containerContext(containerBase)
        let effective: ReferenceOwnership = context == .buffer ? ownership : .unknown
        var offset = 8
        while offset + 8 <= containerSize {
            let word = containerBase.load(fromByteOffset: offset, as: UInt.self)
            if word != 0, word & 1 == 0 {
                if let targetIndex = objectIndexByAddress[word] {
                    appendEdge(ReferenceEdge(from: source,
                                             to: objects[targetIndex].address,
                                             ivarName: ivarName,
                                             isIndirect: true,
                                             ownership: effective),
                               seen: &seen, into: &into)
                } else if depth > 1, let nestedSize = containerSizeByAddress[word],
                          let nestedBase = UnsafeRawPointer(bitPattern: word) {
                    scanContainer(from: source,
                                  ivarName: ivarName,
                                  ownership: effective,
                                  containerBase: nestedBase,
                                  containerSize: min(nestedSize, Int(malloc_size(nestedBase))),
                                  seen: &seen, into: &into, depth: depth - 1)
                }
            }
            offset += 8
        }
    }

    private func appendEdge(_ edge: ReferenceEdge, seen: inout Set<String>, into: inout [ReferenceEdge]) {
        let key = Self.edgeKey(edge)
        guard seen.insert(key).inserted else { return }
        into.append(edge)
    }

    // MARK: 循环引用（迭代版 Tarjan）

    private func detectCycles() {
        var adjacency: [UInt: [UInt]] = [:]
        for edge in edges where edge.ownership.participatesInCycleDetection {
            adjacency[edge.from, default: []].append(edge.to)
        }
        var currentIndex = 0
        var indices: [UInt: Int] = [:]
        var lowlinks: [UInt: Int] = [:]
        var onStack = Set<UInt>()
        var tarjanStack: [UInt] = []
        var components: [[UInt]] = []

        for root in objects.map({ $0.address }) where indices[root] == nil {
            var callStack: [(node: UInt, childCursor: Int)] = [(root, 0)]
            indices[root] = currentIndex
            lowlinks[root] = currentIndex
            currentIndex += 1
            tarjanStack.append(root)
            onStack.insert(root)

            while let frame = callStack.last {
                let children = adjacency[frame.node] ?? []
                if frame.childCursor < children.count {
                    callStack[callStack.count - 1].childCursor += 1
                    let child = children[frame.childCursor]
                    if indices[child] == nil {
                        indices[child] = currentIndex
                        lowlinks[child] = currentIndex
                        currentIndex += 1
                        tarjanStack.append(child)
                        onStack.insert(child)
                        callStack.append((child, 0))
                    } else if onStack.contains(child) {
                        lowlinks[frame.node] = min(lowlinks[frame.node]!, indices[child]!)
                    }
                } else {
                    callStack.removeLast()
                    if let parent = callStack.last {
                        lowlinks[parent.node] = min(lowlinks[parent.node]!, lowlinks[frame.node]!)
                    }
                    if lowlinks[frame.node] == indices[frame.node] {
                        var component: [UInt] = []
                        while let top = tarjanStack.last {
                            tarjanStack.removeLast()
                            onStack.remove(top)
                            component.append(top)
                            if top == frame.node { break }
                        }
                        if component.count > 1 {
                            components.append(component)
                        } else if adjacency[component[0]]?.contains(component[0]) == true {
                            // 自环
                            components.append(component)
                        }
                    }
                }
            }
        }
        cycles = components
    }

    // MARK: 导出

    private static func hex(_ address: UInt) -> String {
        String(format: "0x%lx", address)
    }

    /// 节点入度（被多少条强引用边指向）
    func inDegree(of address: UInt) -> Int {
        edges.reduce(0) { $0 + ($1.to == address ? 1 : 0) }
    }

    /// 所有带 weakly_referenced 标记的节点。该位是对象级 sticky 标记，只表示
    /// 「被某处 weak 引用过」，不指向具体入边，也不能判断捕获边的强弱。
    /// 类属性的 weak / unowned 已通过反射元数据 / ivarLayout 自动排除，
    /// 个别反射不可达的字段仍需 --weak-ivar 兜底。
    func weaklyReferencedObjects() -> [HeapObject] {
        objects.filter { $0.weaklyReferenced }
    }

    func exportJSONData() throws -> Data {
        struct NodeJSON: Codable {
            var address: String
            var className: String
            var size: Int
            var inDegree: Int
            var inCycle: Bool
            /// ObjC block（捕获变量从偏移 32 起存储）
            var isBlock: Bool
            /// 被 weak 引用过（对象级 sticky 标记，不指向具体边）
            var weaklyReferenced: Bool
        }
        struct EdgeJSON: Codable {
            var from: String
            var to: String
            var ivar: String?
            var indirect: Bool
            /// strong / weak / unowned / nonStrong / unknown
            var ownership: String
        }
        struct GraphJSON: Codable {
            var generatedAt: String
            var classFilter: String
            var nodeCount: Int
            var nodes: [NodeJSON]
            var edges: [EdgeJSON]
            /// 非强引用边（weak / unowned / nonStrong），不参与强引用图与找环
            var nonStrongEdges: [EdgeJSON]
            var cycles: [[String]]
        }
        func edgeJSON(_ edge: ReferenceEdge) -> EdgeJSON {
            EdgeJSON(from: Self.hex(edge.from),
                     to: Self.hex(edge.to),
                     ivar: edge.ivarName,
                     indirect: edge.isIndirect,
                     ownership: edge.ownership.rawValue)
        }
        let cycleAddresses = Set(cycles.flatMap { $0 })
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let graph = GraphJSON(
            generatedAt: dateFormatter.string(from: Date()),
            classFilter: classPrefixes.joined(separator: ","),
            nodeCount: objects.count,
            nodes: objects
                .sorted { self.inDegree(of: $0.address) > self.inDegree(of: $1.address) }
                .map {
                    NodeJSON(address: Self.hex($0.address),
                             className: $0.className,
                             size: $0.size,
                             inDegree: self.inDegree(of: $0.address),
                             inCycle: cycleAddresses.contains($0.address),
                             isBlock: $0.isBlock,
                             weaklyReferenced: $0.weaklyReferenced)
                },
            edges: edges.map(edgeJSON),
            nonStrongEdges: nonStrongEdges.map(edgeJSON),
            cycles: cycles.map { $0.sorted().map(Self.hex) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(graph)
    }

    /// 用 HTML 模板生成可视化报告数据：模板中的 `__GRAPH_JSON__` 占位符
    /// 替换为 JSON。App 内集成时把 viewer.template.html 加入 bundle，
    /// 传入其字符串内容即可，返回的 Data 直接写成 .html 文件。
    func exportHTMLData(template: String) throws -> Data {
        let jsonPayload = String(data: try exportJSONData(), encoding: .utf8) ?? "{}"
        // JSON 中的 "</" 会提前结束模板里的 <script> 标签，需转义
        let safePayload = jsonPayload.replacingOccurrences(of: "</", with: "<\\/")
        let html = template.replacingOccurrences(of: "__GRAPH_JSON__", with: safePayload)
        return Data(html.utf8)
    }
}

// swiftlint:enable force_unwrapping
