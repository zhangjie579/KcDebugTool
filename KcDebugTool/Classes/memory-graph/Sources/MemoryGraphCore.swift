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
//     经 Mach-O __swift5_fieldmd 字段描述符的类型 mangling 尾缀识别
//     （Xw=weak、Xo=unowned、Xu=unowned(unsafe)，无尾缀=strong，
//     已由 IR 与二进制双重验证），ObjC 定义的类经 ivarLayout 识别；
//     --weak-ivar 仅作为兜底手段；
//     关键约束：Swift 类禁止走 class_copyIvarList 等强制 realize 的 ObjC API
//     （真机实测崩在 libobjc safe_ro）；字段名与绝对实例偏移取自受保护的
//     swift_reflectionMirror_recursiveChild*，不读取其 isStrong；Swift 类先用
//     class_data_bits_t 的 FAST_IS_SWIFT 标志分流（vm_read 直读，不触发 realize）；
//     对指向「非对象容器块」（Swift Array/Dictionary 缓冲区、未被过滤进
//     图中的 NSArray 等）的字做一层透传扫描，保证容器内元素的引用不丢失；
//     Swift 闭包上下文（HeapLocalVariable）从首个可定位捕获槽起，经 Mach-O
//     __swift5_capture 的 CaptureDescriptor 判定（同一套 Xw/Xo/Xu 判别式），ObjC block 捕获
//     经 libclosure 的 BlockDescriptor extended layout 判定；强捕获参与循环检测；
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
import MachO

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

/// 把 Swift mangled 类型名 demangle 为可读类名；libobjc 未导出符号或 exotic
/// mangling 时返回 nil。用于把 __swift5_fieldmd 的描述符键与 class_getName 对齐。
private func demangleSwiftType(_ mangled: String) -> String? {
    guard let demangler = swiftDemangle else { return nil }
    return mangled.utf8CString.withUnsafeBytes { raw in
        guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
        guard let output = demangler(base, raw.count - 1, nil, nil, 0) else { return nil }
        defer { free(output) }
        return String(cString: output)
    }
}

// MARK: - Swift 字段所有权（__swift5_fieldmd，唯一可靠来源）

/// Swift 存储属性的「所有权」唯一可靠来源是 Mach-O 的 `__swift5_fieldmd`
/// 字段描述符，而非运行时反射：字段类型 mangling 的尾缀直接给出语义，
/// 已由 IR 与二进制双重验证：Xw=weak、Xo=unowned、Xu=unowned(unsafe)/unmanaged、
/// 无尾缀=strong。相对地，`swift_reflectionMirror_*` 的 isStrong 只能按 Optional 形态
/// 猜测 weak/unowned，无法区分 unowned(unsafe)，且对堆 resident 元数据会崩溃。
/// 下列代码只读 Mach-O 元数据、不触碰任何实例，结果按已加载镜像数缓存重建。

/// 单个字段的 ownership。函数类型由 reflection 返回的 Any.Type 判断，避免对含
/// symbolic reference 的 mangling 做普通 C 字符串解析。
private struct SwiftFieldInfo {
    let ownership: ReferenceOwnership
}

private struct ReflectedSwiftField {
    let name: String
    let offset: Int
    let type: Any.Type
}

/// 单份 FieldDescriptor。类名可能包含 symbolic reference，无法保证能按普通 C 字符串
/// demangle，因此即使 className 解析失败也必须保留 fields，再通过同镜像字段集合匹配。
private struct SwiftFieldDescriptorInfo {
    let className: String?
    let imagePath: String
    let fields: [String: SwiftFieldInfo]
    let normalizedFields: [String: SwiftFieldInfo]
    let normalizedNames: Set<String>
}

private struct SwiftFieldDescriptorCache {
    let descriptors: [SwiftFieldDescriptorInfo]
    let indicesByClassName: [String: [Int]]
    let indicesByImageAndField: [String: [String: [Int]]]
}

/// App bundle 内已加载镜像的 __swift5_fieldmd 解析结果与倒排索引。FieldRecord 不含
/// 实例偏移；名称与偏移由 reflection SPI 获取，ownership 只取这里的 mangling。
private var swiftFieldDescriptorCache: SwiftFieldDescriptorCache?
private var swiftFieldDescriptorImageCount: UInt32 = 0
private let swiftFieldAppBundlePath = Bundle.main.bundlePath
private let swiftFieldDescriptorLock = NSLock()

private func normalizedSwiftStorageName(_ name: String) -> String {
    let lazyStoragePrefix = "$__lazy_storage_$_"
    var result = name.hasPrefix(lazyStoragePrefix)
        ? String(name.dropFirst(lazyStoragePrefix.count))
        : name
    while result.hasPrefix("_") { result.removeFirst() }
    return result
}

/// 懒加载属性的底层 ivar 名形如 `$__lazy_storage_$_viewModel`，展示时单独去掉
/// `$__lazy_storage_$_` 前缀，只保留语义名 `viewModel`，与源码属性名一致。
/// 仅用于展示，不影响字段匹配 / 所有权判定（那些走 normalizedSwiftStorageName）。
private func stripLazyStoragePrefix(forDisplay name: String) -> String {
    let lazyStoragePrefix = "$__lazy_storage_$_"
    return name.hasPrefix(lazyStoragePrefix)
        ? String(name.dropFirst(lazyStoragePrefix.count))
        : name
}

/// 只解析 App bundle 内 dyld 镜像的 __swift5_fieldmd，保留每份字段表并建立索引。
/// 只读 Mach-O 元数据，不反射、不触碰实例；按 _dyld_image_count 缓存重建。
private func ensureSwiftFieldDescriptors() -> SwiftFieldDescriptorCache {
    swiftFieldDescriptorLock.lock()
    defer { swiftFieldDescriptorLock.unlock() }
    let imageCount = _dyld_image_count()
    if let cached = swiftFieldDescriptorCache, swiftFieldDescriptorImageCount == imageCount {
        return cached
    }
    var descriptors: [SwiftFieldDescriptorInfo] = []
    for imageIndex in 0..<imageCount {
        guard let imageName = _dyld_get_image_name(imageIndex) else { continue }
        let imagePath = String(cString: imageName)
        guard imagePath == swiftFieldAppBundlePath
                || imagePath.hasPrefix(swiftFieldAppBundlePath + "/") else { continue }
        guard let headerPointer = _dyld_get_image_header(imageIndex) else { continue }
        let header = UnsafeRawPointer(headerPointer).assumingMemoryBound(to: mach_header_64.self)
        guard header.pointee.magic == MH_MAGIC_64 else { continue }
        let slide = _dyld_get_image_vmaddr_slide(imageIndex)

        // 收集本镜像全部 section 的运行时区间（校验字段描述符相对指针是否落在
        // 已映射段内），并定位 __swift5_fieldmd section。
        var ranges: [(start: UInt, end: UInt)] = []
        var fieldSections: [(address: UInt, size: UInt64)] = []
        var commandAddress = UnsafeRawPointer(headerPointer) + MemoryLayout<mach_header_64>.size
        for _ in 0..<header.pointee.ncmds {
            let command = commandAddress.assumingMemoryBound(to: load_command.self)
            guard command.pointee.cmd == LC_SEGMENT_64 else {
                commandAddress += Int(command.pointee.cmdsize)
                continue
            }
            let segment = commandAddress.assumingMemoryBound(to: segment_command_64.self)
            let sectionsBase = UnsafeRawPointer(segment) + MemoryLayout<segment_command_64>.size
            for sectionIndex in 0..<segment.pointee.nsects {
                let section = (sectionsBase + Int(sectionIndex) * MemoryLayout<section_64>.size)
                    .assumingMemoryBound(to: section_64.self)
                let start = UInt(bitPattern: slide) &+ UInt(section.pointee.addr)
                if section.pointee.size > 0 {
                    ranges.append((start, start &+ UInt(section.pointee.size)))
                }
                if sectionName(section) == "__swift5_fieldmd" {
                    fieldSections.append((start, section.pointee.size))
                }
            }
            commandAddress += Int(command.pointee.cmdsize)
        }

        for fieldSection in fieldSections {
            guard let base = UnsafeRawPointer(bitPattern: fieldSection.address) else { continue }
            let size = fieldSection.size
            var offset: UInt64 = 0
            // FieldDescriptor 头：MangledTypeName(4) Superclass(4) Kind(2)
            // FieldRecordSize(2) NumFields(4)，随后 NumFields 条 FieldRecord。
            while offset + 16 <= size {
                let recordSize: UInt16 = (base + Int(offset + 10)).load(as: UInt16.self)
                let numFields: UInt32 = (base + Int(offset + 12)).load(as: UInt32.self)
                // recordSize / 字段数是 ABI 完整性校验；NumFields==0 是合法空描述符，
                // 必须跳过并继续，否则会漏掉它后面所有类型。
                guard recordSize >= 12, numFields <= 4096 else { break }
                let recordBytes = UInt64(numFields) * UInt64(recordSize)
                guard offset + 16 + recordBytes <= size else { break }

                // 描述符首字 MangledTypeName（相对指针）是类的 mangled 名。纯文本形式
                // 可作为精确匹配键；含 symbolic reference 时普通 demangle 会失败，后续
                // 改用同镜像字段集合匹配，不能因此丢弃整份描述符。
                let descriptorBase = base + Int(offset)
                let keyDelta: Int32 = descriptorBase.load(as: Int32.self)
                let keyTarget = UInt(bitPattern: descriptorBase) &+ UInt(bitPattern: Int(keyDelta))
                let keyLimit = sectionByteLimit(keyTarget, ranges)
                let classKey: String? = keyLimit > 0
                    ? boundedCString(UnsafeRawPointer(bitPattern: keyTarget)!, limit: keyLimit).flatMap(demangleSwiftType)
                    : nil
                var fields: [String: SwiftFieldInfo] = [:]
                for fieldIndex in 0..<numFields {
                    // FieldRecord 紧跟 16 字节 FieldDescriptor 头；标准 ABI 记录只有
                    // Flags / MangledTypeName / FieldName 三项，不包含实例偏移。
                    let record = descriptorBase + 16 + Int(UInt64(fieldIndex) * UInt64(recordSize))
                    let typeDelta: Int32 = (record + 4).load(as: Int32.self)
                    let nameDelta: Int32 = (record + 8).load(as: Int32.self)
                    // 相对指针以「存放该 int32 的地址」为基准。
                    let typeTarget = UInt(bitPattern: record + 4) &+ UInt(bitPattern: Int(typeDelta))
                    let nameTarget = UInt(bitPattern: record + 8) &+ UInt(bitPattern: Int(nameDelta))
                    let typeLimit = sectionByteLimit(typeTarget, ranges)
                    let nameLimit = sectionByteLimit(nameTarget, ranges)
                    guard typeLimit > 0, nameLimit > 0 else { continue }
                    guard let name = boundedCString(UnsafeRawPointer(bitPattern: nameTarget)!, limit: nameLimit) else { continue }
                    let ownership = ownershipFromFieldType(UnsafeRawPointer(bitPattern: typeTarget)!, limit: typeLimit)
                    fields[name] = SwiftFieldInfo(ownership: ownership)
                }
                if !fields.isEmpty {
                    var normalizedFields: [String: SwiftFieldInfo] = [:]
                    var ambiguousNames = Set<String>()
                    for (name, info) in fields {
                        let normalizedName = normalizedSwiftStorageName(name)
                        if let existing = normalizedFields[normalizedName],
                           existing.ownership != info.ownership {
                            normalizedFields.removeValue(forKey: normalizedName)
                            ambiguousNames.insert(normalizedName)
                        } else if !ambiguousNames.contains(normalizedName) {
                            normalizedFields[normalizedName] = info
                        }
                    }
                    let normalizedNames = Set(normalizedFields.keys)
                    descriptors.append(SwiftFieldDescriptorInfo(className: classKey,
                                                                 imagePath: imagePath,
                                                                 fields: fields,
                                                                 normalizedFields: normalizedFields,
                                                                 normalizedNames: normalizedNames))
                }
                // 16 字节头 + NumFields × FieldRecordSize，按 4 字节对齐推进。
                offset += (16 + recordBytes + 3) & ~3
            }
        }
    }
    var indicesByClassName: [String: [Int]] = [:]
    var indicesByImageAndField: [String: [String: [Int]]] = [:]
    for (index, descriptor) in descriptors.enumerated() {
        if let className = descriptor.className {
            indicesByClassName[className, default: []].append(index)
        }
        for fieldName in descriptor.normalizedNames {
            indicesByImageAndField[descriptor.imagePath, default: [:]][fieldName, default: []].append(index)
        }
    }
    let cache = SwiftFieldDescriptorCache(descriptors: descriptors,
                                          indicesByClassName: indicesByClassName,
                                          indicesByImageAndField: indicesByImageAndField)
    swiftFieldDescriptorCache = cache
    swiftFieldDescriptorImageCount = imageCount
    return cache
}

/// 相对指针目标必须落在当前镜像已映射的 section 内，返回该处到 section 末尾的可读上限。
private func sectionByteLimit(_ target: UInt, _ ranges: [(start: UInt, end: UInt)]) -> UInt {
    for range in ranges where target >= range.start && target < range.end {
        return range.end &- target
    }
    return 0
}

/// section 名（sectname 固定 16 字节，可能未 NUL 结尾）。
private func sectionName(_ section: UnsafePointer<section_64>) -> String {
    withUnsafeBytes(of: section.pointee.sectname) { raw in
        let pointer = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
        var length = 0
        while length < 16 && pointer[length] != 0 { length += 1 }
        return String(bytes: UnsafeRawBufferPointer(start: pointer, count: length), encoding: .utf8) ?? ""
    }
}

/// segment 名（segname 同样是固定 16 字节）。
private func segmentName(_ segment: UnsafePointer<segment_command_64>) -> String {
    withUnsafeBytes(of: segment.pointee.segname) { raw in
        let pointer = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
        var length = 0
        while length < 16 && pointer[length] != 0 { length += 1 }
        return String(bytes: UnsafeRawBufferPointer(start: pointer, count: length),
                      encoding: .utf8) ?? ""
    }
}

/// 在已知长度上限内读 NUL 结尾字符串；字段名都在 __swift5_reflstr，均为 ASCII。
private func boundedCString(_ bytes: UnsafeRawPointer, limit: UInt) -> String? {
    let pointer = bytes.assumingMemoryBound(to: UInt8.self)
    let max = Int(limit)
    var length = 0
    while length < max && pointer[length] != 0 { length += 1 }
    guard length > 0, length < max else { return nil }
    return String(bytes: UnsafeRawBufferPointer(start: pointer, count: length), encoding: .utf8)
}

/// 字段类型 mangling 尾缀决定所有权：Xw=weak、Xo=unowned、Xu=unowned(unsafe)。
/// 自定义类型会内嵌 symbolic reference（0x01...0x17 为 4 字节相对指针，
/// 0x18...0x1F 为指针宽度绝对指针），payload 可能含 0，必须整体跳过。
private func ownershipFromFieldType(_ bytes: UnsafeRawPointer, limit: UInt) -> ReferenceOwnership {
    let pointer = bytes.assumingMemoryBound(to: UInt8.self)
    let max = Int(limit)
    var previous: UInt8 = 0
    var current: UInt8 = 0
    var index = 0
    while index < max {
        let byte = pointer[index]
        if byte == 0 { break }
        if byte >= 0x01, byte <= 0x17 {
            guard index + 5 <= max else { break }
            index += 5
            continue
        }
        if byte >= 0x18, byte <= 0x1F {
            let symbolicReferenceSize = 1 + MemoryLayout<UInt>.size
            guard index + symbolicReferenceSize <= max else { break }
            index += symbolicReferenceSize
            continue
        }
        previous = current
        current = byte
        index += 1
    }
    if previous == UInt8(ascii: "X") {
        switch current {
        case UInt8(ascii: "w"): return .weak
        case UInt8(ascii: "o"): return .unowned
        case UInt8(ascii: "u"): return .unownedUnsafe
        default: break
        }
    }
    return .strong
}

/// 仅使用反射 SPI 的名称、类型和绝对实例偏移；isStrong 明确忽略，避免把它误当
/// ownership 来源。相关符号在当前 iOS Swift runtime 导出，而类型级 _forEachField
/// 在当前工具链不可用。
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

private let swiftFunctionMetadataKind: UInt = 0x302

/// 可选闭包的字段元数据是 Optional（enum），不能只用 Function kind 判断。
/// `Optional<() -> Void>` 仍占两个指针字，第二字才是持有捕获对象的上下文。
/// 这里只识别明确的 Swift 厚函数签名；C / block 函数指针不是这种布局。
private func hasSwiftFunctionContext(_ type: Any.Type) -> Bool {
    if swiftMetadataKind(type) == swiftFunctionMetadataKind { return true }
    let name = String(reflecting: type)
    let prefix = "Swift.Optional<"
    guard name.hasPrefix(prefix), name.hasSuffix(">") else { return false }
    let wrapped = String(name.dropFirst(prefix.count).dropLast())
    return (wrapped.hasPrefix("(") || wrapped.hasPrefix("@Sendable ("))
        && wrapped.contains(" -> ")
}

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
    let retainedContext = Unmanaged.passRetained(scanContext)
    let contextPointer = retainedContext.toOpaque()
    defer { retainedContext.release() }
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
    /// 明确强持有：__swift5_fieldmd 无所有权尾缀 / ObjC ivarLayout STRONG / block layout STRONG
    case strong
    /// 类存储属性或 stripped 的全局/静态槽没有可用所有权元数据时，按语言默认
    /// strong 参与强引用图；报告明确标未确证，不冒充已有元数据证明。
    /// 与 unknown 的区别：这里缺的是「确证」，不是「语义」。weak/unowned 是显式修饰，
    /// 元数据能解析时仍以 fieldmd 为准；因此单独标注「未确证」，不冒充 confirmed strong。
    case unconfirmedStrong
    /// 明确归类为 weak（fieldmd Xw / ObjC weak ivar / ObjC block weak capture）
    case weak
    /// Swift unowned（fieldmd Xo）
    case unowned
    /// Swift unowned(unsafe) / unmanaged（fieldmd Xu）
    case unownedUnsafe
    /// 只确认不是 strong：ObjC ivarLayout 之外的 @ ivar，无法继续区分
    /// weak / __unsafe_unretained
    case nonStrong
    /// 真正无法判定所有权：闭包捕获 / 容器透传无 capture 元数据、桥接
    /// @convention(block) 不带 extended layout 等。堆内存形态上强捕获与
    /// [weak x] 一致，保守标 unknown，展示但不参与循环检测，避免误报环。
    case unknown

    /// 是否作为潜在强引用边展示；unknown 仍需展示，避免丢失可能的引用关系。
    var isStrongEdge: Bool {
        self == .strong || self == .unconfirmedStrong || self == .unknown
    }

    /// 找环只排除「语义上真的可能不是引用」的 unknown。unconfirmedStrong 是类
    /// 存储属性（语言默认 strong），元数据缺失时若一并排除，普通强引用环会被
    /// 整条切断（RoomViewController ⇄ RoomMsgContainView 即此类漏检）。
    var participatesInCycleDetection: Bool {
        self == .strong || self == .unconfirmedStrong
    }

    var label: String {
        switch self {
        case .strong: return "strong"
        case .unconfirmedStrong: return "疑似 strong（所有权元数据缺失）"
        case .weak: return "weak"
        case .unowned: return "unowned"
        case .unownedUnsafe: return "unowned(unsafe)"
        case .nonStrong: return "非强（weak/unsafe）"
        case .unknown: return "未知（无可用所有权元数据）"
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

private struct StaticStorageRange {
    let start: UInt
    let end: UInt
    let imageName: String
    let sectionName: String
}

// MARK: - 扫描器

final class MemoryGraphScanner {

    /// 只保留类名匹配任一前缀的对象，控制图规模与噪音；空数组表示不过滤，保留堆上全部对象
    let classPrefixes: [String]
    /// 兜底用：额外视作 weak、不参与强引用图与循环检测的 ivar 名。
    /// weak / unowned 已通过 __swift5_fieldmd（Swift 类）与 ivarLayout（ObjC 类）自动识别，
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
    /// 未注册的 Swift 泛型类只读描述符名称；绝不交给 ObjC 的类名/继承 API。
    private var unregisteredSwiftClassNames: [UInt: String] = [:]
    /// 非对象容器块地址 -> 块大小（透传扫描用）
    private var containerSizeByAddress: [UInt: Int] = [:]
    /// 类指针 -> [ivar 偏移: 属性名]
    private var ivarNameMaps: [UInt: [Int: String]] = [:]
    /// 静态 Swift metadata 指针 -> 已完成 fieldmd 关联的字段布局。多个 Aspects / KVO
    /// 动态子类可能回退到同一个静态父类，复用后不再重复执行 reflection SPI 与字段匹配。
    private var swiftReflectedLayouts: [UInt: (names: [Int: String],
                                                ownership: [Int: ReferenceOwnership],
                                                functions: Set<Int>)] = [:]
    /// 类指针 -> Swift 函数及 Optional<函数> 字段的 context 指针偏移。
    /// 不扫描其他 enum / struct / existential 的内部字，避免伪引用。
    private var swiftFunctionContextOffsets: [UInt: Set<Int>] = [:]
    /// 闭包上下文 metadata 指针 -> 可定位捕获槽的所有权。
    /// 与类的非强字段不同，闭包捕获住在 HeapLocalVariable 上下文里，靠
    /// metadata 上的 CaptureDescriptor（__swift5_capture）解析，按 metadata 缓存
    /// 即可去重（同一闭包类型的所有实例共享同一份捕获布局）。
    private var swiftCaptureOwnershipCache: [UInt: [Int: ReferenceOwnership]] = [:]
    /// 已加载镜像的 __swift5_capture / __swift5_typeref 段区间：校验 CaptureDescriptor
    /// 与其 mangled 类型名确实落在已知只读反射段内，任何越界都退化为 unknown 兜底。
    private var swiftCaptureRanges: [(start: UInt, end: UInt)]?
    private var swiftTypeRefRanges: [(start: UInt, end: UInt)]?
    private var swiftCaptureSectionImageCount: UInt32 = 0
    /// 静态 metadata 指针 -> 容器类型。大量闭包实例共享 metadata，避免反向全堆扫描
    /// 对每个实例都重复一次 vm_read_overwrite。
    private var containerContextByMetadata: [UInt: ContainerContext] = [:]
    /// 类指针 -> weak ivar 偏移集合（ivarLayout 自动识别；Swift 类为空集）
    /// 类指针 -> 非强字段偏移及运行时可确定的持有语义
    private var nonStrongIvarOffsetMaps: [UInt: [Int: ReferenceOwnership]] = [:]
    /// 同一类、同一实例大小的扫描槽位不变；捕获所有权仍逐实例覆盖。
    private var scanLayouts: [UInt: [Int: [(offset: Int, ownerOffset: Int)]]] = [:]
    /// 容器块地址 -> 持有者（incoming 反查扫描时建立）。必须透传字段 ownership，
    /// 否则 unknown 字段经容器后会被默认误标为 strong。
    private var containerOwnerByAddress: [UInt: (owner: UInt,
                                                 ivarName: String?,
                                                 ownership: ReferenceOwnership)] = [:]
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
    /// App 镜像可写数据段中的全局 / static 存储槽。直接命中目标地址时，作为
    /// 非堆的强引用根加入 incoming；地址 -> 标签供报告展示。
    private var staticStorageRanges: [StaticStorageRange] = []
    private var staticStorageImageCount: UInt32 = 0
    private var staticRootLabelByAddress: [UInt: String] = [:]
    private var staticIncomingByTarget: [UInt: [ReferenceEdge]]?
    /// 反射 SPI 只用于 App bundle 内静态 Swift metadata 的字段名、类型和偏移；
    /// 主程序、内嵌 framework / Pod 与 debug dylib 都要覆盖，系统镜像和堆上动态类不调用。
    private let appBundlePath = Bundle.main.bundlePath

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
        /// 引用该对象的对象（逐层反查），包含 strong / unknown / weak / unowned；
        /// 只有参与找环的强引用来源（confirmed / 未确证 strong）继续作为下一层 target。
        let incoming: [ReferenceEdge]
        /// 来源对象地址 -> 反查层级（1 起）
        let incomingLevel: [UInt: Int]
        /// 报告中出现的地址 -> 类名（展示用）
        let classNameByAddress: [UInt: String]
        /// NotificationCenter 注册表长期持有的通知 block。它会强持有目标，
        /// 但 token 与 block 在 Foundation 内部不一定形成可从目标返回的对象环。
        let notificationRetentions: [ReferenceEdge]
        /// 经过该对象的循环引用链（定向 DFS 找出，最多 50 条）
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
        var seenIncomingEdges = Set<String>()
        var visitedStrongSources: Set<UInt> = [address]
        var currentTargets: Set<UInt> = [address]
        for level in 1...max(1, maxDepth) {
            let levelEdges = incomingSweep(targets: currentTargets)
            for edge in levelEdges where seenIncomingEdges.insert(Self.edgeKey(edge)).inserted {
                allIncoming.append(edge)
                if incomingLevel[edge.from] == nil { incomingLevel[edge.from] = level }
            }
            let confirmedStrongSources = Set(levelEdges.lazy
                .filter { $0.ownership.participatesInCycleDetection }
                .map(\.from))
            let newSources = confirmedStrongSources.subtracting(visitedStrongSources)
            visitedStrongSources.formUnion(newSources)
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
            } else if let label = staticRootLabelByAddress[edge.from] {
                classNameByAddress[edge.from] = label
            } else if let label = containerLabelByAddress[edge.from] {
                // incoming 伪来源：无持有者的闭包 / block 堆块
                classNameByAddress[edge.from] = label
            }
        }
        let targetNameMap = ivarNameMap(for: target.classPointer)
        var nonStrongFields: [String: ReferenceOwnership] = [:]
        for (offset, ownership) in nonStrongIvarOwnership(for: target.classPointer)
        where ownership != .unconfirmedStrong {
            // unconfirmedStrong 按默认 strong 参与找环，不属于「非强字段」
            if let name = fieldName(at: offset, in: targetNameMap) { nonStrongFields[name] = ownership }
        }
        let cycles = cycleChains(through: address, directIncoming: allIncoming)
        for cycle in cycles {
            classNameByAddress.merge(cycle.classNameByAddress) { current, _ in current }
        }
        let notificationRetentions = allIncoming.filter { edge in
            guard edge.ownership.participatesInCycleDetection,
                  let sourceIndex = objectIndexByAddress[edge.from] else { return false }
            let sourceName = Self.displayName(of: objects[sourceIndex])
            let label = edge.ivarName ?? ""
            return sourceName.contains("Block")
                && (label.contains("Foundation.Notification") || label.contains("NSNotification"))
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
                               notificationRetentions: notificationRetentions,
                               cycles: cycles)
    }

    /// 定向查找经过 address 的循环引用链：沿强引用边 DFS，只保留能回到目标的闭合路径。
    /// 与全图 Tarjan 不同，这里不构建全堆边表，只展开目标可达对象——保持按需查询的秒级性能。
    /// 报告已经反查出直接回指目标的边，先与目标的 outgoing 边连接成两边环。
    /// 这一步不消耗 DFS 节点预算；短环全部保留（至多 100 条），maxChains
    /// 只限制较长的搜索结果，避免短环被旁路分支挤出报告。
    /// - Parameters:
    ///   - maxDepth: 链最大边数（含回到目标的那条），默认 10；Rx 订阅链会经过多个中间对象
    ///   - maxChains: 较长环的结果上限，默认 50；直接回指短环另保留至多 100 条
    ///   - maxObjects: DFS 展开对象总数上限，默认 2400；仍只扫描目标可达局部图
    func cycleChains(through address: UInt,
                     directIncoming: [ReferenceEdge] = [],
                     maxDepth: Int = 10,
                     maxChains: Int = 50,
                     maxObjects: Int = 2_400) -> [CycleChain] {
        guard let targetIndex = objectIndexByAddress[address] else { return [] }
        let collectLimit = maxChains * 4
        let shortChainLimit = 100
        var chains: [CycleChain] = []
        var seenChains = Set<String>()
        var visitedCount = 0
        var path: [ReferenceEdge] = []
        var onPath: Set<UInt> = [address]

        func nameOf(_ node: UInt) -> String {
            guard let index = objectIndexByAddress[node] else { return Self.hex(node) }
            return Self.displayName(of: objects[index])
        }

        func appendChain(_ chain: [ReferenceEdge]) {
            let key = chain.map(Self.edgeKey).joined(separator: ">")
            guard seenChains.insert(key).inserted else { return }
            var names: [UInt: String] = [:]
            for link in chain {
                names[link.from] = nameOf(link.from)
                names[link.to] = nameOf(link.to)
            }
            chains.append(CycleChain(edges: chain, classNameByAddress: names))
        }

        let directReturnEdges = Dictionary(grouping: directIncoming.filter {
            $0.to == address && $0.ownership.participatesInCycleDetection
        }, by: \.from)
        // incoming 已经做过最多两层全堆反查。把这段反向结果预组装成回到目标的
        // suffix；正向查环一旦走到 suffix 起点即可闭合，不再重复展开 Rx 中间节点。
        var returnSuffixes = directReturnEdges.mapValues { $0.map { [$0] } }
        for _ in 1..<maxDepth {
            var additions: [UInt: [[ReferenceEdge]]] = [:]
            for edge in directIncoming where edge.ownership.participatesInCycleDetection {
                guard let suffixes = returnSuffixes[edge.to], edge.from != address else { continue }
                for suffix in suffixes where !suffix.contains(where: { $0.from == edge.from }) {
                    additions[edge.from, default: []].append([edge] + suffix)
                }
            }
            guard !additions.isEmpty else { break }
            var inserted = false
            for (start, suffixes) in additions {
                for suffix in suffixes {
                    let key = suffix.map(Self.edgeKey).joined(separator: ">")
                    let existing = returnSuffixes[start, default: []]
                    guard !existing.contains(where: {
                        $0.map(Self.edgeKey).joined(separator: ">") == key
                    }) else { continue }
                    returnSuffixes[start, default: []].append(suffix)
                    inserted = true
                }
            }
            if !inserted { break }
        }
        let firstEdges = directCycleReferences(from: objects[targetIndex])
        var cycleReferenceCache: [UInt: [ReferenceEdge]] = [address: firstEdges]
        var prioritizedReferenceCache: [UInt: [ReferenceEdge]] = [:]
        for outward in firstEdges {
            guard chains.count < shortChainLimit else { break }
            if outward.to == address {
                appendChain([outward])
            } else if maxDepth >= 2 {
                for returning in directReturnEdges[outward.to] ?? [] {
                    guard chains.count < shortChainLimit else { break }
                    appendChain([outward, returning])
                }
            }
        }
        let precollectedCount = chains.count

        let firstEdgesForSearch = interleavedCycleRootEdges(firstEdges)
        func branchBudget(for edge: ReferenceEdge) -> Int {
            guard let index = objectIndexByAddress[edge.to] else { return 0 }
            let name = Self.displayName(of: objects[index])
            if name.contains("DisposeBag") { return min(1_600, maxObjects) }
            if name.contains("ViewModel") { return min(600, maxObjects) }
            return max(24, maxObjects / max(1, firstEdgesForSearch.count))
        }

        func references(from node: UInt) -> [ReferenceEdge] {
            if let cached = cycleReferenceCache[node] { return cached }
            guard let index = objectIndexByAddress[node] else { return [] }
            let references = directCycleReferences(from: objects[index])
            cycleReferenceCache[node] = references
            return references
        }

        func prioritized(_ edges: [ReferenceEdge]) -> [ReferenceEdge] {
            edges.sorted { lhs, rhs in
                func score(_ edge: ReferenceEdge) -> Int {
                    if returnSuffixes[edge.to] != nil { return 0 }
                    guard let index = objectIndexByAddress[edge.to] else { return 5 }
                    let name = Self.displayName(of: objects[index])
                    let isRetentionNode = name.contains("Relay") || name.contains("Subject")
                        || name.contains("Observer") || name.contains("Disposable")
                        || name.contains("Sink") || name.contains("DisposeBag")
                    // incoming 两层反查已经知道真正回指目标的 Subject / Observer 地址。
                    // 对同类 Relay 做一层廉价前瞻，优先 roomTravel 这类实际能接上
                    // 回指 suffix 的分支，避免被 ViewModel 里大量无关 Relay 挤掉。
                    if isRetentionNode,
                       references(from: edge.to).contains(where: { returnSuffixes[$0.to] != nil }) {
                        return 1
                    }
                    if isRetentionNode { return 2 }
                    return edge.isIndirect ? 4 : 3
                }
                return score(lhs) < score(rhs)
            }
        }

        func prioritizedReferences(from node: UInt) -> [ReferenceEdge] {
            if let cached = prioritizedReferenceCache[node] { return cached }
            let result = prioritized(references(from: node))
            prioritizedReferenceCache[node] = result
            return result
        }

        func visit(_ current: UInt, _ depth: Int, _ branchLimit: Int,
                   _ branchVisited: inout Int) {
            guard chains.count - precollectedCount < collectLimit,
                  visitedCount < maxObjects, branchVisited < branchLimit,
                  depth <= maxDepth,
                  objectIndexByAddress[current] != nil else { return }
            if let suffixes = returnSuffixes[current] {
                for suffix in suffixes where path.count + suffix.count <= maxDepth {
                    var suffixNodes = onPath
                    var cursor = current
                    let isSimple = suffix.enumerated().allSatisfy { position, edge in
                        guard edge.from == cursor else { return false }
                        cursor = edge.to
                        if edge.to == address { return position == suffix.count - 1 }
                        return suffixNodes.insert(edge.to).inserted
                    }
                    guard isSimple, cursor == address else { continue }
                    appendChain(path + suffix)
                }
            }
            visitedCount += 1
            branchVisited += 1
            let nextEdges = prioritizedReferences(from: current)
            // 先收完本层所有直接回到目标的边（闭合即最短链），再展开其他分支，
            // 避免深搜先占满额度把短环挤掉。
            for edge in nextEdges where edge.to == address {
                guard chains.count - precollectedCount < collectLimit else { break }
                appendChain(path + [edge]) // path 中每个节点唯一（onPath 保证），构成简单环
            }
            for edge in nextEdges where edge.to != address {
                guard chains.count - precollectedCount < collectLimit else { break }
                guard depth < maxDepth, !onPath.contains(edge.to),
                      objectIndexByAddress[edge.to] != nil else { continue }
                onPath.insert(edge.to)
                path.append(edge)
                visit(edge.to, depth + 1, branchLimit, &branchVisited)
                path.removeLast()
                onPath.remove(edge.to)
            }
        }
        for edge in firstEdgesForSearch {
            guard visitedCount < maxObjects,
                  chains.count - precollectedCount < collectLimit else { break }
            if edge.to == address { continue } // 已由短环和直接闭合边收集
            guard objectIndexByAddress[edge.to] != nil else { continue }
            var branchVisited = 0
            let budget = branchBudget(for: edge)
            onPath.insert(edge.to)
            path.append(edge)
            if budget > 0 {
                visit(edge.to, 2, budget, &branchVisited)
            }
            path.removeLast()
            onPath.remove(edge.to)
        }
        let shortChains = chains.filter { $0.edges.count <= 2 }
            .sorted { $0.edges.count < $1.edges.count }
            .prefix(shortChainLimit)
        let longerChains = chains.filter { $0.edges.count > 2 }
            .sorted { $0.edges.count < $1.edges.count }
            .prefix(maxChains)
        return Array(shortChains) + Array(longerChains)
    }

    /// 容器属性可能一次展开数百个元素。按属性交错并把直接字段放前面，避免一个
    /// 无关数组先耗尽预算，使后面的 disposeBag / viewModel 永远没有搜索机会。
    private func interleavedCycleRootEdges(_ edges: [ReferenceEdge]) -> [ReferenceEdge] {
        var groups: [[ReferenceEdge]] = []
        var groupIndexByName: [String: Int] = [:]
        for edge in edges {
            let name = edge.ivarName ?? ""
            if let index = groupIndexByName[name] {
                groups[index].append(edge)
            } else {
                groupIndexByName[name] = groups.count
                groups.append([edge])
            }
        }
        var result: [ReferenceEdge] = []
        result.reserveCapacity(edges.count)
        var offset = 0
        while result.count < edges.count {
            for group in groups where offset < group.count { result.append(group[offset]) }
            offset += 1
        }
        return result.filter { !$0.isIndirect } + result.filter(\.isIndirect)
    }

    /// 某个对象的「偏移 -> ownership」：类级元数据（属性三分） + 该 block 实例的
    /// extended layout（捕获槽），后者覆盖前者
    private func ownershipMap(for object: HeapObject) -> [Int: ReferenceOwnership] {
        nonStrongIvarOwnership(for: object.classPointer)
            .merging(blockCaptureOwnership(for: object)) { _, blockLayout in blockLayout }
    }

    /// 读取引用地址。全堆扫描不持有来源对象，不能把 weak 槽交给 runtime 解引用：
    /// 来源对象可能并发释放，objc_loadWeakRetained 会访问已经失效的 storage。
    /// 类字段只做 vm_read 原始字读取（ObjC/桥接 weak 常可直接命中）；闭包捕获没有
    /// 可靠逐槽 offset，weak 槽直接跳过，避免把任意内容误当 WeakReference。
    private func referencedAddress(base: UnsafeRawPointer, offset: Int,
                                   ownership: ReferenceOwnership,
                                   allowRawWeakStorage: Bool) -> UInt {
        guard ownership == .weak else {
            return base.load(fromByteOffset: offset, as: UInt.self)
        }
        guard allowRawWeakStorage else { return 0 }
        return safeReadUInt(UInt(bitPattern: base) + UInt(offset)) ?? 0
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
            let word = referencedAddress(base: base,
                                         offset: offset,
                                         ownership: edgeOwnership,
                                         allowRawWeakStorage: true)
            guard word != 0, word & 1 == 0 else { continue }
            if let targetIndex = objectIndexByAddress[word] {
                let ivarName = referenceLabel(for: object, at: offset, base: base, nameMap: nameMap)
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
                let ivarName = referenceLabel(for: object, at: offset, base: base, nameMap: nameMap)
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

    /// 缓存 App 主程序及内嵌 framework 的静态存储区。只扫描普通 / zerofill section；
    /// ObjC / Swift metadata 虽也在数据段，但不会在运行时写入普通堆对象地址，命中目标
    /// 时仍表示某个全局缓存或 runtime 根正在持有它。
    private func ensureStaticStorageRanges() {
        let imageCount = _dyld_image_count()
        guard staticStorageImageCount != imageCount else { return }
        staticStorageImageCount = imageCount
        staticStorageRanges = []
        staticIncomingByTarget = nil
        staticRootLabelByAddress = [:]
        let dataSegments: Set<String> = ["__DATA", "__DATA_CONST", "__DATA_DIRTY",
                                         "__AUTH", "__AUTH_CONST"]
        for imageIndex in 0..<imageCount {
            guard let imageNamePointer = _dyld_get_image_name(imageIndex),
                  let headerPointer = _dyld_get_image_header(imageIndex) else { continue }
            let imagePath = String(cString: imageNamePointer)
            guard imagePath == appBundlePath || imagePath.hasPrefix(appBundlePath + "/") else { continue }
            let header = UnsafeRawPointer(headerPointer).assumingMemoryBound(to: mach_header_64.self)
            guard header.pointee.magic == MH_MAGIC_64 else { continue }
            let slide = _dyld_get_image_vmaddr_slide(imageIndex)
            var commandAddress = UnsafeRawPointer(headerPointer) + MemoryLayout<mach_header_64>.size
            for _ in 0..<header.pointee.ncmds {
                let command = commandAddress.assumingMemoryBound(to: load_command.self)
                defer { commandAddress += Int(command.pointee.cmdsize) }
                guard command.pointee.cmd == LC_SEGMENT_64 else { continue }
                let segment = commandAddress.assumingMemoryBound(to: segment_command_64.self)
                guard dataSegments.contains(segmentName(segment)) else { continue }
                let sectionsBase = UnsafeRawPointer(segment) + MemoryLayout<segment_command_64>.size
                for sectionIndex in 0..<segment.pointee.nsects {
                    let section = (sectionsBase + Int(sectionIndex) * MemoryLayout<section_64>.size)
                        .assumingMemoryBound(to: section_64.self)
                    let type = section.pointee.flags & UInt32(SECTION_TYPE)
                    guard type == UInt32(S_REGULAR) || type == UInt32(S_ZEROFILL),
                          section.pointee.size >= UInt64(MemoryLayout<UInt>.size) else { continue }
                    let start = UInt(bitPattern: slide) &+ UInt(section.pointee.addr)
                    let image = URL(fileURLWithPath: imagePath).lastPathComponent
                    staticStorageRanges.append(StaticStorageRange(
                        start: start,
                        end: start &+ UInt(section.pointee.size),
                        imageName: image,
                        sectionName: sectionName(section)))
                }
            }
        }
    }

    /// 查找 App 静态存储槽对 targets 的直接引用。精确符号命中可确认是变量存储；
    /// stripped 构建只能保留 section + 槽地址，ownership 标未确证 strong。
    private func staticIncoming(targets: Set<UInt>, seen: inout Set<String>,
                                into result: inout [ReferenceEdge]) {
        ensureStaticStorageRanges()
        if staticIncomingByTarget == nil {
            var index: [UInt: [ReferenceEdge]] = [:]
            for range in staticStorageRanges {
                let alignedStart = (range.start + 7) & ~UInt(7)
                guard alignedStart < range.end else { continue }
                for address in stride(from: alignedStart, to: range.end - 7, by: 8) {
                    guard let pointer = UnsafeRawPointer(bitPattern: address) else { continue }
                    let value = pointer.load(as: UInt.self)
                    guard objectIndexByAddress[value] != nil else { continue }
                    var info = Dl_info()
                    var variableName: String?
                    var exactSymbol = false
                    if dladdr(pointer, &info) != 0, let symbol = info.dli_sname,
                       UInt(bitPattern: info.dli_saddr) == address {
                        var raw = String(cString: symbol)
                        if raw.hasPrefix("_$s") { raw.removeFirst() }
                        variableName = demangle(raw) ?? raw
                        exactSymbol = true
                    }
                    let slotOffset = address &- range.start
                    let slotName = variableName.map { "全局/静态变量 · \($0)" }
                        ?? "全局/静态槽 · \(range.sectionName)+0x\(String(slotOffset, radix: 16))"
                    staticRootLabelByAddress[address] = "全局/静态根 · \(range.imageName) · \(range.sectionName)"
                    index[value, default: []].append(ReferenceEdge(
                        from: address,
                        to: value,
                        ivarName: slotName,
                        isIndirect: false,
                        ownership: exactSymbol ? .strong : .unconfirmedStrong))
                }
            }
            staticIncomingByTarget = index
        }
        for target in targets {
            for edge in staticIncomingByTarget?[target] ?? [] {
                appendEdge(edge, seen: &seen, into: &result)
            }
        }
    }

    /// 一次全堆定向扫描：找出引用 targets 中任一地址的对象，保留完整 ownership。
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
                var edgeOwnership = ownership
                if let ivarName = fieldName(at: offset, in: nameMap), weakIvarNames.contains(ivarName) {
                    edgeOwnership = .nonStrong
                }
                let word = referencedAddress(base: base,
                                             offset: offset,
                                             ownership: edgeOwnership,
                                             allowRawWeakStorage: true)
                guard word != 0, word & 1 == 0 else { continue }
                if targets.contains(word) {
                    let referenceLabel = referenceLabel(for: object, at: offset, base: base, nameMap: nameMap)
                    appendEdge(ReferenceEdge(from: object.address,
                                             to: word,
                                             ivarName: referenceLabel,
                                             isIndirect: false,
                                             ownership: edgeOwnership),
                               seen: &seen, into: &result)
                } else if edgeOwnership.isStrongEdge,
                          containerSizeByAddress[word] != nil,
                          containerOwnerByAddress[word] == nil {
                    let referenceLabel = referenceLabel(for: object, at: offset, base: base, nameMap: nameMap)
                    updateClosureContainerLabel(at: word, ownerLabel: referenceLabel,
                                                classPointer: object.classPointer, offset: offset)
                    containerOwnerByAddress[word] = (object.address, referenceLabel, edgeOwnership)
                }
            }
        }
        for (containerAddress, _) in containerSizeByAddress {
            if let owner = containerOwnerByAddress[containerAddress] {
                sweepContainer(from: owner.owner,
                               ivarName: owner.ivarName,
                               containerAddress: containerAddress,
                               targets: targets,
                               ownership: owner.ownership,
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
        staticIncoming(targets: targets, seen: &seen, into: &result)
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
        let captureOwnership = context == .closure
            ? swiftCaptureOwnership(for: containerAddress) : [:]
        let size = min(containerSizeByAddress[containerAddress] ?? 0, Int(malloc_size(base)))
        var offset = 8
        while offset + 8 <= size {
            let effective = captureOwnership[offset] ?? (context == .buffer ? ownership : .unknown)
            let word = referencedAddress(base: base,
                                         offset: offset,
                                         ownership: effective,
                                         allowRawWeakStorage: false)
            if word != 0, word & 1 == 0 {
                if targets.contains(word) {
                    appendEdge(ReferenceEdge(from: source,
                                             to: word,
                                             ivarName: ivarName,
                                             isIndirect: true,
                                             ownership: effective),
                               seen: &seen, into: &into)
                } else if depth > 1, word != source, containerSizeByAddress[word] != nil {
                    let nestedLabel = nestedClosureLabel(parentBase: base,
                                                         offset: offset,
                                                         nestedAddress: word,
                                                         fallback: ivarName)
                    sweepContainer(from: source,
                                   ivarName: nestedLabel,
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
        let field = fieldName(at: offset, in: nameMap).map { stripLazyStoragePrefix(forDisplay: $0) }
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
        // 未注册的 RxSwift 泛型类无法安全调用 reflectionMirror，因而没有字段名。
        // Swift 厚函数仍是相邻的「代码指针 + context 指针」；当当前字明确指向
        // 闭包 context 时，用前一字恢复具体 closure #N 所在的方法。
        if field == nil, offset >= MemoryLayout<UInt>.size {
            let contextAddress = base.load(fromByteOffset: offset, as: UInt.self)
            if let contextBase = UnsafeRawPointer(bitPattern: contextAddress),
               containerSizeByAddress[contextAddress] != nil,
               containerContext(contextBase) == .closure {
                let functionAddress = base.load(fromByteOffset: offset - MemoryLayout<UInt>.size,
                                                as: UInt.self)
                if let symbol = closureSymbol(at: functionAddress) {
                    return "RxSwift 闭包 · \(symbol)"
                }
            }
        }
        return field
    }

    /// 闭包 context 里还可能捕获另一份厚函数（RxSwift 包装用户 onNext 时即如此）。
    /// 每深入一层都用相邻代码指针更新标签，最终落到业务源码的 closure #N。
    private func nestedClosureLabel(parentBase: UnsafeRawPointer, offset: Int,
                                    nestedAddress: UInt, fallback: String?) -> String? {
        guard offset >= MemoryLayout<UInt>.size,
              let nestedBase = UnsafeRawPointer(bitPattern: nestedAddress),
              containerContext(nestedBase) == .closure else { return fallback }
        let functionAddress = parentBase.load(fromByteOffset: offset - MemoryLayout<UInt>.size,
                                              as: UInt.self)
        guard let symbol = closureSymbol(at: functionAddress) else { return fallback }
        return "RxSwift 闭包 · \(symbol)"
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

    /// Swift 类的 class_getName 通常返回「模块名.类名」；但当类名含私有判别符
    /// （_TtC...P33_...）等无法展开为模块点号形式时，会返回原始 mangled 符号，
    /// 例如 `_TtC14SawaLudoCommonP33_348D8DBE804BDD42304F3DEEDA8C1BE720EnterRoomFlowManager`。
    /// 这里用运行时 swift_demangle 还原为可读类名，避免图中出现不可读的 mangled 符号。
    /// 仅对以 _Tt 开头的 mangled 名尝试还原，普通「模块名.类名」原样返回；
    /// demangle 失败则回退原始名，不丢对象。
    private func demangleClassNameIfNeeded(_ name: String) -> String {
        guard name.hasPrefix("_Tt") else { return name }
        return demangle(name) ?? name
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
        var unrealizedClassNames: [UInt: String] = [:]
        var rejectedClassPointers = Set<UInt>()
        for range in blockRanges {
            // NSObject 至少 16 字节（isa + 一个指针位）
            guard range.count >= 16, let base = UnsafeRawPointer(bitPattern: range.lowerBound) else { continue }
            let isaWord = base.load(as: UInt.self)
            guard isaWord != 0, isaWord & taggedPointerMask == 0 else { continue }
            let classPointer = isaWord & isaClassMask
            let isRegistered = registeredClasses.contains(classPointer)
            let rawSwiftName: String?
            if isRegistered {
                rawSwiftName = nil
            } else if let cached = unrealizedClassNames[classPointer] {
                rawSwiftName = cached
            } else if rejectedClassPointers.contains(classPointer) {
                rawSwiftName = nil
            } else {
                rawSwiftName = unregisteredSwiftClassName(classPointer)
                if let rawSwiftName {
                    unrealizedClassNames[classPointer] = rawSwiftName
                } else {
                    rejectedClassPointers.insert(classPointer)
                }
            }
            guard isRegistered || rawSwiftName != nil else {
                // 无有效 isa 的块：Swift 闭包上下文（首字是元数据指针而非类 isa）、
                // Swift Array/Dictionary 缓冲区等容器。捕获单个对象的 Swift 闭包
                // 上下文仅 16 字节（元数据 8 + 捕获 8），阈值不能高于 16
                if range.count >= 16 {
                    containerSizeByAddress[range.lowerBound] = Int(range.count)
                    containerLabelByAddress[range.lowerBound] = "匿名堆块（Swift 闭包/缓冲区）"
                }
                continue
            }
            // class_getName 自身会调用 objc_class::demangledName；未注册 metadata
            // 即使部分布局看似有效也可能在该路径崩溃，只保留描述符里的原始名称。
            let className: String
            if let rawSwiftName {
                unregisteredSwiftClassNames[classPointer] = rawSwiftName
                className = rawSwiftName
            } else {
                let anyClass: AnyClass = unsafeBitCast(classPointer, to: AnyClass.self)
                className = demangleClassNameIfNeeded(String(cString: class_getName(anyClass)))
            }
            let bareClassName = className.split(separator: ".").last.map(String.init) ?? className
            if classPrefixes.isEmpty || classPrefixes.contains(where: { bareClassName.hasPrefix($0) || className.hasPrefix($0) }) {
                objectIndexByAddress[range.lowerBound] = objects.count
                objects.append(HeapObject(address: range.lowerBound,
                                          size: Int(range.count),
                                          classPointer: classPointer,
                                          className: className,
                                          isBlock: isRegistered && isBlockClass(classPointer, className: className),
                                          weaklyReferenced: isaWord & 0x4 != 0))
            } else {
                // 被前缀过滤掉的正常对象（如 NSArray、NSString、__NSMallocBlock__），
                // 同样作为容器透传，使 [MGObserver] 存进 NSArray / 闭包捕获的场景不丢边
                containerSizeByAddress[range.lowerBound] = Int(range.count)
                if isRegistered && isBlockClass(classPointer, className: className) {
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
                case 6: assign(count, .unownedUnsafe)            // __unsafe_unretained / unmanaged ≈ unowned(unsafe)
                default: break
                }
            }
        }
        return result
    }

    /// Swift 闭包上下文判定：首字指向 HeapLocalVariableMetadata（kind = 0x400）。
    /// 其捕获槽所有权由 swiftCaptureOwnership 经 __swift5_capture 解析；解析不到的槽
    /// 回落 unknown；数组 / 字典等普通缓冲区的元素仍是 strong。
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
        if let cached = containerContextByMetadata[meta] { return cached }
        guard let kind = safeReadUInt(meta) else { return .unreadable }
        let context: ContainerContext = (kind & 0xfff) == 0x400 ? .closure : .buffer
        containerContextByMetadata[meta] = context
        return context // MetadataKind::HeapLocalVariable
    }

    // MARK: Swift 闭包捕获所有权（__swift5_capture，唯一可靠来源）

    /// 收集所有 dyld 镜像的 __swift5_capture 与 __swift5_typeref 段区间，用于校验
    /// CaptureDescriptor 与其 mangled 类型名确实落在已知只读反射段内。只读 Mach-O
    /// 元数据、不反射、不触碰实例，按 _dyld_image_count 缓存重建。
    private func ensureSwiftCaptureSections() -> (capture: [(start: UInt, end: UInt)],
                                                 typeRef: [(start: UInt, end: UInt)]) {
        let imageCount = _dyld_image_count()
        if let capture = swiftCaptureRanges,
           let typeRef = swiftTypeRefRanges,
           swiftCaptureSectionImageCount == imageCount {
            return (capture, typeRef)
        }
        var captureRanges: [(start: UInt, end: UInt)] = []
        var typeRefRanges: [(start: UInt, end: UInt)] = []
        for imageIndex in 0..<imageCount {
            guard let headerPointer = _dyld_get_image_header(imageIndex) else { continue }
            let header = UnsafeRawPointer(headerPointer).assumingMemoryBound(to: mach_header_64.self)
            guard header.pointee.magic == MH_MAGIC_64 else { continue }
            let slide = _dyld_get_image_vmaddr_slide(imageIndex)
            var commandAddress = UnsafeRawPointer(headerPointer) + MemoryLayout<mach_header_64>.size
            for _ in 0..<header.pointee.ncmds {
                let command = commandAddress.assumingMemoryBound(to: load_command.self)
                guard command.pointee.cmd == LC_SEGMENT_64 else {
                    commandAddress += Int(command.pointee.cmdsize)
                    continue
                }
                let segment = commandAddress.assumingMemoryBound(to: segment_command_64.self)
                let sectionsBase = UnsafeRawPointer(segment) + MemoryLayout<segment_command_64>.size
                for sectionIndex in 0..<segment.pointee.nsects {
                    let section = (sectionsBase + Int(sectionIndex) * MemoryLayout<section_64>.size)
                        .assumingMemoryBound(to: section_64.self)
                    guard section.pointee.size > 0 else { continue }
                    let start = UInt(bitPattern: slide) &+ UInt(section.pointee.addr)
                    let range = (start, start &+ UInt(section.pointee.size))
                    let name = sectionName(section)
                    if name == "__swift5_capture" { captureRanges.append(range) }
                    else if name == "__swift5_typeref" { typeRefRanges.append(range) }
                }
                commandAddress += Int(command.pointee.cmdsize)
            }
        }
        swiftCaptureRanges = captureRanges
        swiftTypeRefRanges = typeRefRanges
        swiftCaptureSectionImageCount = imageCount
        return (captureRanges, typeRefRanges)
    }

    private func addressInRanges(_ address: UInt, _ ranges: [(start: UInt, end: UInt)]) -> Bool {
        ranges.contains { address >= $0.start && address < $0.end }
    }

    /// 相对指针（int32，以自身地址为基准）解析，全程 vm_read 守卫。
    private func readRelativePointer(_ fieldAddress: UInt) -> UInt? {
        guard let raw = safeReadInt32(fieldAddress) else { return nil }
        return fieldAddress &+ UInt(bitPattern: Int(raw))
    }

    /// 安全读取 4 字节无符号 / 有符号整数（CaptureDescriptor 字段、相对偏移）。
    private func safeReadUInt32(_ address: UInt) -> UInt32? {
        guard address != 0 else { return nil }
        var value: UInt32 = 0
        var outSize: vm_size_t = 0
        let result = withUnsafeMutableBytes(of: &value) { buffer -> kern_return_t in
            vm_read_overwrite(mach_task_self_,
                              vm_address_t(address),
                              vm_size_t(4),
                              vm_address_t(UInt(bitPattern: buffer.baseAddress)),
                              &outSize)
        }
        guard result == KERN_SUCCESS, outSize == 4 else { return nil }
        return value
    }

    private func safeReadInt32(_ address: UInt) -> Int32? {
        guard address != 0 else { return nil }
        var value: Int32 = 0
        var outSize: vm_size_t = 0
        let result = withUnsafeMutableBytes(of: &value) { buffer -> kern_return_t in
            vm_read_overwrite(mach_task_self_,
                              vm_address_t(address),
                              vm_size_t(4),
                              vm_address_t(UInt(bitPattern: buffer.baseAddress)),
                              &outSize)
        }
        guard result == KERN_SUCCESS, outSize == 4 else { return nil }
        return value
    }

    /// CaptureTypeRecord 与 FieldRecord 使用同一套 symbolic mangled type；ownership
    /// 只看跳过 symbolic payload 后的末尾 Xw/Xo/Xu，不能把类型内部 token 当后缀。
    private func ownershipFromCaptureType(_ bytes: UnsafeRawPointer,
                                          limit: UInt) -> ReferenceOwnership {
        ownershipFromFieldType(bytes, limit: limit)
    }

    /// Swift 闭包捕获上下文（HeapLocalVariable，kind=0x400）的逐槽所有权。
    /// 唯一可靠来源是 metadata 上的 CaptureDescriptor（位于 __swift5_capture）：
    ///   metadata 偏移 8 = OffsetToFirstCapture；偏移 16 = CaptureDescription 绝对指针。
    /// CaptureDescriptor 的 12 字节头后紧跟 CaptureTypeRecord 相对指针数组。
    /// 所有读都经 vm_read 守卫，且 descTarget 必须落在 __swift5_capture、mangled 必须
    /// 落在 __swift5_typeref，任一不达标即返回空——退化为 scanContainer/sweepContainer
    /// 现有的 unknown 兜底，绝不崩溃或误标。按 metadata 指针缓存去重。
    private func swiftCaptureOwnership(for contextAddress: UInt) -> [Int: ReferenceOwnership] {
        // 首字即 metadata 指针（容器自身是有效堆内存，containerContext 已判定 kind=0x400）
        guard let meta = safeReadUInt(contextAddress), meta & 7 == 0,
              let metaPointer = UnsafeRawPointer(bitPattern: meta),
              malloc_zone_from_ptr(metaPointer) == nil,
              let kind = safeReadUInt(meta), (kind & 0xfff) == 0x400 else { return [:] }
        if let cached = swiftCaptureOwnershipCache[meta] { return cached }
        let result = computeSwiftCaptureOwnership(meta: meta, contextAddress: contextAddress)
        swiftCaptureOwnershipCache[meta] = result
        return result
    }

    /// 实际解析：metadata 已通过 kind 校验后，逐捕获读取 CaptureDescriptor 并判定所有权。
    private func computeSwiftCaptureOwnership(meta: UInt, contextAddress: UInt) -> [Int: ReferenceOwnership] {
        guard let containerBase = UnsafeRawPointer(bitPattern: contextAddress) else { return [:] }
        let containerSize = Int(malloc_size(containerBase))
        guard containerSize >= 24 else { return [:] }
        // OffsetToFirstCapture：捕获数据相对上下文对象起始的偏移（含 16 字节 HeapObject 头）
        let offsetToFirstCapture = safeReadUInt32(meta + 8) ?? 0
        guard offsetToFirstCapture >= 16, offsetToFirstCapture &+ 7 < UInt(containerSize) else { return [:] }
        // HeapLocalVariableMetadata.CaptureDescription 是进程内绝对指针。
        guard let descTarget = safeReadUInt(meta + 16), descTarget != 0 else { return [:] }
        let (captureRanges, typeRefRanges) = ensureSwiftCaptureSections()
        guard addressInRanges(descTarget, captureRanges) else { return [:] }
        guard let numFields = safeReadUInt32(descTarget), numFields > 0, numFields <= 64 else { return [:] }
        // CaptureDescriptor：NumCaptureTypes / NumMetadataSources / NumBindings 共 12 字节，
        // 随后内联 NumCaptureTypes 个 CaptureTypeRecord（每个 4 字节相对指针）。
        let typeRefsBase = descTarget + 12
        // NecessaryBindings 位于闭包头和捕获值之间；泛型 RxSwift 闭包常有多个
        // metadata/witness 绑定，不能把第一个绑定误当成第一个捕获槽。
        let bindingCount = safeReadUInt32(descTarget + 8) ?? 0
        guard bindingCount <= 64 else { return [:] }
        var result: [Int: ReferenceOwnership] = [:]
        var captureOffset = Int(offsetToFirstCapture) + Int(bindingCount) * MemoryLayout<UInt>.size
        for index in 0..<Int(numFields) {
            let slot = typeRefsBase &+ UInt(index * 4)
            guard let mangledAddr = readRelativePointer(slot) else { break }
            let typeLimit = sectionByteLimit(mangledAddr, typeRefRanges)
            guard typeLimit > 0,
                  let typeBytes = UnsafeRawPointer(bitPattern: mangledAddr),
                  captureOffset + MemoryLayout<UInt>.size <= containerSize else { break }
            let ownership = ownershipFromCaptureType(typeBytes, limit: typeLimit)
            result[captureOffset] = ownership

            // CaptureDescriptor 不记录逐槽偏移。weak / unowned 存储可确定为一个指针字，
            // 因而能继续定位下一项；无尾缀 strong 也可能是多字值，当前项起点可靠，
            // 但其后的偏移不可证明，必须停止并让通用扫描把后续边标为 unknown。
            guard ownership != .strong else { break }
            captureOffset += MemoryLayout<UInt>.size
        }
        return result
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

    /// 不触发运行时 realize 的前提下判定类是否为 Swift 类：读 objc_class 的
    /// class_data_bits_t（arm64 偏移 0x20：isa(8) superclass(8) cache(16) bits(8)）
    /// 低 2 位 FAST_IS_SWIFT_STABLE / FAST_IS_SWIFT_LEGACY 标志。Swift 类不能走
    /// class_copyIvarList 等强制 realize 的 API（会崩在 libobjc 的 safe_ro）。
    private func isSwiftClassViaBits(_ classPointer: UInt) -> Bool {
        guard let bits = safeReadUInt(classPointer &+ 0x20) else { return false }
        return bits & 0x3 != 0
    }

    /// 类名 API 自身会在损坏或未完全 realize 的 metadata 上崩溃；Swift/ObjC
    /// 分流只读 metadata，不调用 class_getName。动态子类沿原始 superclass 指针
    /// 回溯，仍可落到其 Swift 父类。
    private func isSwiftClassMetadata(_ classPointer: UInt) -> Bool {
        var current = classPointer
        var visited = Set<UInt>()
        for _ in 0..<8 {
            guard current != 0, current & 7 == 0, visited.insert(current).inserted else { break }
            if isSwiftClassViaBits(current) { return true }
            if let descriptor = safeReadUInt(current &+ 64), descriptor & 3 == 0,
               let descriptorPointer = UnsafeRawPointer(bitPattern: descriptor),
               let flags = safeReadUInt32(descriptor), flags & 0x1f == 0x10,
               malloc_zone_from_ptr(descriptorPointer) == nil {
                var image = Dl_info()
                if dladdr(descriptorPointer, &image) != 0 { return true }
            }
            guard let superclass = safeReadUInt(current &+ 8), superclass != current else { break }
            current = superclass
        }
        return false
    }

    /// 泛型特化类可能尚未进入 objc_copyClassList。仅以 Swift 类标志、
    /// 只读 ClassDescriptor 和有界原始名称共同识别；不调用任何 ObjC Class API。
    private func unregisteredSwiftClassName(_ classPointer: UInt) -> String? {
        guard classPointer != 0, classPointer & 7 == 0,
              isSwiftClassViaBits(classPointer),
              let descriptor = safeReadUInt(classPointer &+ 64), descriptor & 3 == 0,
              malloc_zone_from_ptr(UnsafeRawPointer(bitPattern: descriptor)) == nil,
              let flags = safeReadUInt32(descriptor), flags & 0x1f == 0x10,
              let relativeName = safeReadUInt32(descriptor &+ 8) else { return nil }
        var image = Dl_info()
        guard let descriptorPointer = UnsafeRawPointer(bitPattern: descriptor),
              dladdr(descriptorPointer, &image) != 0 else { return nil }
        let signedOffset = Int64(Int32(bitPattern: relativeName))
        let nameField = descriptor &+ 8
        guard signedOffset >= 0 ? nameField <= UInt.max - UInt(signedOffset)
                                : nameField >= UInt(-signedOffset) else { return nil }
        let nameAddress = signedOffset >= 0 ? nameField + UInt(signedOffset)
                                            : nameField - UInt(-signedOffset)
        var bytes: [UInt8] = []
        for index in 0..<128 {
            guard let byte = safeReadByte(nameAddress &+ UInt(index)) else { return nil }
            if byte == 0 { break }
            guard byte >= 0x21, byte <= 0x7e else { return nil }
            bytes.append(byte)
        }
        guard !bytes.isEmpty, bytes.count < 128 else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Swift 类字段映射：名称、类型和绝对实例偏移来自 reflectionMirror SPI，
    /// ownership 只按字段名匹配 __swift5_fieldmd。反射的 isStrong 明确不参与判定。
    /// 仅反射已注册且可安全定位的类；未注册泛型类保留节点，但退回原始字扫描。
    private func ivarNameMapFromFieldmd(classPointer: UInt, runtimeClass: AnyClass) -> [Int: String] {
        var map: [Int: String] = [:]
        var ownershipByOffset: [Int: ReferenceOwnership] = [:]
        var functionContextOffsets = Set<Int>()
        guard let reflectionClass = safeReflectionClass(startingAt: runtimeClass) else {
            swiftFunctionContextOffsets[classPointer] = functionContextOffsets
            ivarNameMaps[classPointer] = map
            nonStrongIvarOffsetMaps[classPointer] = ownershipByOffset
            return map
        }
        let reflectionClassPointer = UInt(bitPattern: unsafeBitCast(reflectionClass,
                                                                    to: UnsafeRawPointer.self))
        if let cached = swiftReflectedLayouts[reflectionClassPointer] {
            swiftFunctionContextOffsets[classPointer] = cached.functions
            ivarNameMaps[classPointer] = cached.names
            nonStrongIvarOffsetMaps[classPointer] = cached.ownership
            return cached.names
        }
        let reflectionType: Any.Type = reflectionClass
        let fieldCount = swiftRecursiveChildCount(reflectionType)
        var reflectedFields: [ReflectedSwiftField] = []
        if fieldCount > 0, fieldCount <= 1024 {
            for index in 0..<fieldCount {
                var metadata = SwiftFieldReflectionMetadata(name: nil,
                                                            freeFunc: nil,
                                                            isStrong: false,
                                                            isVar: false)
                let fieldType = swiftRecursiveChildMetadata(reflectionType,
                                                            index: index,
                                                            fieldMetadata: &metadata)
                let name = metadata.name.map { String(cString: $0) }
                metadata.freeFunc?(metadata.name)
                guard let name else { continue }
                let offset = swiftRecursiveChildOffset(reflectionType, index: index)
                guard offset > 0 else { continue }
                if map[offset] == nil { map[offset] = name }
                reflectedFields.append(ReflectedSwiftField(name: name, offset: offset, type: fieldType))
            }
        }
        // 未注册泛型 metadata 不交给 class_getName / class_getSuperclass。
        // 字段偏移仍由 Swift 反射取得，fieldmd 无法安全关联时标未确证 strong。
        let fieldInfoByName = unregisteredSwiftClassNames[reflectionClassPointer] == nil
            ? swiftFieldInfoByName(startingAt: reflectionClass,
                                   reflectedNames: reflectedFields.map(\.name)) : [:]
        for field in reflectedFields {
            if let fieldInfo = fieldInfoByName[field.name] {
                switch fieldInfo.ownership {
                case .strong:
                    ownershipByOffset.removeValue(forKey: field.offset)
                case .weak, .unowned, .unownedUnsafe:
                    ownershipByOffset[field.offset] = fieldInfo.ownership
                case .unconfirmedStrong:
                    ownershipByOffset[field.offset] = .unconfirmedStrong
                case .nonStrong, .unknown:
                    ownershipByOffset[field.offset] = .unknown
                }
            } else {
                // 描述符未匹配（类名含 symbolic reference、跨类同名字段歧义）时，
                // 字段本身仍是类存储属性，Swift/ObjC 默认 strong。此前一刀切标
                // unknown，会让整条强引用环因「unknown 不参与找环」被漏检
                // （RoomViewController ⇄ RoomMsgContainView 即此类）。这里按
                // 未确证 strong 放行，报告页明确标注，不冒充 confirmed。
                ownershipByOffset[field.offset] = .unconfirmedStrong
            }

            // 闭包也可能内嵌在值类型属性中（例如 RxSwift.Bag 的 _value0）。
            // 只定位函数值的 context 字，不把 struct 的其他内部字推断为强引用。
            functionContextOffsets.formUnion(swiftFunctionContexts(in: field.type,
                                                                  at: field.offset,
                                                                  depth: 0))
        }
        swiftFunctionContextOffsets[classPointer] = functionContextOffsets
        ivarNameMaps[classPointer] = map
        nonStrongIvarOffsetMaps[classPointer] = ownershipByOffset
        swiftReflectedLayouts[reflectionClassPointer] = (map, ownershipByOffset, functionContextOffsets)
        return map
    }

    private func swiftFunctionContexts(in type: Any.Type, at baseOffset: Int, depth: Int) -> Set<Int> {
        if hasSwiftFunctionContext(type) { return [baseOffset + MemoryLayout<UInt>.size] }
        guard depth < 4, swiftMetadataKind(type) == 0x200 else { return [] } // struct
        let count = swiftRecursiveChildCount(type)
        guard count > 0, count <= 64 else { return [] }
        var offsets = Set<Int>()
        for index in 0..<count {
            var metadata = SwiftFieldReflectionMetadata(name: nil,
                                                        freeFunc: nil,
                                                        isStrong: false,
                                                        isVar: false)
            let childType = swiftRecursiveChildMetadata(type, index: index,
                                                       fieldMetadata: &metadata)
            metadata.freeFunc?(metadata.name)
            let childOffset = swiftRecursiveChildOffset(type, index: index)
            guard childOffset >= 0 else { continue }
            offsets.formUnion(swiftFunctionContexts(in: childType,
                                                   at: baseOffset + childOffset,
                                                   depth: depth + 1))
        }
        return offsets
    }

    /// 合并当前类与父类的 fieldmd 信息；子类同名字段优先。recursiveChild* 返回
    /// 继承链字段的绝对偏移，因此 ownership 查找也必须覆盖整条静态继承链。
    private func swiftFieldInfoByName(startingAt runtimeClass: AnyClass,
                                      reflectedNames: [String]) -> [String: SwiftFieldInfo] {
        let descriptorCache = ensureSwiftFieldDescriptors()
        let descriptors = descriptorCache.descriptors
        var result: [String: SwiftFieldInfo] = [:]
        var ambiguousExactNames = Set<String>()
        var classKeys = Set<String>()
        var imagePaths = Set<String>()
        var currentClass: AnyClass? = runtimeClass
        while let anyClass = currentClass {
            classKeys.insert(String(cString: class_getName(anyClass)))
            classKeys.insert(String(reflecting: anyClass))
            if let imagePath = class_getImageName(anyClass).map({ String(cString: $0) }),
               imagePath == appBundlePath || imagePath.hasPrefix(appBundlePath + "/") {
                imagePaths.insert(imagePath)
            }
            if anyClass == NSObject.self { break }
            currentClass = class_getSuperclass(anyClass)
        }

        // 能解析出类名时优先精确关联当前类与父类。
        let exactDescriptorIndices = Set(classKeys.flatMap {
            descriptorCache.indicesByClassName[$0] ?? []
        })
        for name in reflectedNames {
            let infos = exactDescriptorIndices.compactMap {
                matchingFieldInfo(for: name, in: descriptors[$0])
            }
            let ownershipValues = Set(infos.map { $0.ownership.rawValue })
            if ownershipValues.count == 1 {
                result[name] = infos[0]
            } else if !infos.isEmpty {
                ambiguousExactNames.insert(name)
            }
        }

        // symbolic class name 无法普通 demangle 时，按 swift_eval 的字段集合方案回退；
        // 额外限定同一 Mach-O 镜像，并优先选择与本类反射字段重合最多的描述符。
        let reflectedSet = Set(reflectedNames.map(normalizedSwiftStorageName))
        for name in reflectedNames where result[name] == nil && !ambiguousExactNames.contains(name) {
            let normalizedName = normalizedSwiftStorageName(name)
            let candidateIndices = Set(imagePaths.flatMap {
                descriptorCache.indicesByImageAndField[$0]?[normalizedName] ?? []
            })
            var candidates: [(info: SwiftFieldInfo, score: Int, fullMatch: Bool)] = []
            for index in candidateIndices {
                let descriptor = descriptors[index]
                guard let info = matchingFieldInfo(for: name, in: descriptor) else { continue }
                let score = descriptor.normalizedNames.intersection(reflectedSet).count
                guard score > 0 else { continue }
                candidates.append((info, score, descriptor.normalizedNames.isSubset(of: reflectedSet)))
            }
            let requireFullMatch = candidates.contains { $0.fullMatch }
            var bestScore = -1
            var bestInfo: SwiftFieldInfo?
            var bestOwnership: ReferenceOwnership?
            var ownershipConflict = false
            for candidate in candidates where !requireFullMatch || candidate.fullMatch {
                if candidate.score > bestScore {
                    bestScore = candidate.score
                    bestInfo = candidate.info
                    bestOwnership = candidate.info.ownership
                    ownershipConflict = false
                } else if candidate.score == bestScore,
                          bestOwnership != candidate.info.ownership {
                    ownershipConflict = true
                }
            }
            if !ownershipConflict, let bestInfo { result[name] = bestInfo }
        }
        return result
    }

    private func matchingFieldInfo(for fieldName: String,
                                   in descriptor: SwiftFieldDescriptorInfo) -> SwiftFieldInfo? {
        if let exact = descriptor.fields[fieldName] { return exact }
        let normalizedName = normalizedSwiftStorageName(fieldName)
        return descriptor.normalizedFields[normalizedName]
    }

    private func isHeapResidentMetadata(_ classPointer: UInt) -> Bool {
        guard let pointer = UnsafeRawPointer(bitPattern: classPointer) else { return true }
        return malloc_zone_from_ptr(pointer) != nil
    }

    private func safeReflectionClass(startingAt runtimeClass: AnyClass) -> AnyClass? {
        var currentClass: AnyClass? = runtimeClass
        while let anyClass = currentClass {
            let pointer = UInt(bitPattern: unsafeBitCast(anyClass, to: UnsafeRawPointer.self))
            if unregisteredSwiftClassNames[pointer] != nil {
                // 描述符足以识别类节点，却不能证明动态 metadata 可安全反射。
                // 真机会在 recursiveCount 主动断点；不碰 ObjC 父类 API。
                return nil
            }
            if !isHeapResidentMetadata(pointer), isAppReflectionImage(anyClass) { return anyClass }
            if anyClass == NSObject.self { break }
            currentClass = class_getSuperclass(anyClass)
        }
        return nil
    }

    private func isAppReflectionImage(_ anyClass: AnyClass) -> Bool {
        guard let imagePath = class_getImageName(anyClass).map({ String(cString: $0) }) else { return false }
        return imagePath == appBundlePath || imagePath.hasPrefix(appBundlePath + "/")
    }

    private func ivarNameMap(for classPointer: UInt) -> [Int: String] {
        if let cached = ivarNameMaps[classPointer] { return cached }
        if let rawName = unregisteredSwiftClassNames[classPointer],
           rawName.hasPrefix("_ContiguousArrayStorage")
            || rawName.hasPrefix("_ArrayStorage")
            || rawName.hasPrefix("_DictionaryStorage") {
            // 标准库集合元素尾随在类实例之后，不在反射字段列表里。
            // 此类存储必须逐字扫描，否则 DisposeBag 的元素会消失。
            ivarNameMaps[classPointer] = [:]
            nonStrongIvarOffsetMaps[classPointer] = [:]
            return [:]
        }
        let runtimeClass: AnyClass = unsafeBitCast(classPointer, to: AnyClass.self)
        // Swift 类必须先于 ObjC 路径分流：class_copyIvarList / class_getIvarLayout /
        // class_getInstanceSize 会强制 realize；class_getName 也可能在 demangledName
        // 崩溃。只读 Swift 标志、类描述符和原始父类指针判断。
        if unregisteredSwiftClassNames[classPointer] != nil || isSwiftClassMetadata(classPointer) {
            return ivarNameMapFromFieldmd(classPointer: classPointer, runtimeClass: runtimeClass)
        }
        // —— 以下 ObjC 类路径：ObjC 类在 dyld 加载时已 realize，以下 API 安全 ——
        var map: [Int: String] = [:]
        var encodings: [Int: String] = [:]
        var strongOffsets = Set<Int>()
        var weakLayoutOffsets = Set<Int>()
        var currentClass: AnyClass? = runtimeClass
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
        // ObjC 类：__weak 与 __unsafe_unretained 的类型编码相同（'@'），由两份
        // 布局区分：weak 布局命中即 weak；strong 布局未覆盖的 @ 字段只能确认
        // 非强（nonStrong）。空编码兜底标 unknown（不冒充 strong）。
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
        ivarNameMaps[classPointer] = map
        nonStrongIvarOffsetMaps[classPointer] = ownershipByOffset
        return map
    }

    /// 指定类的非强字段偏移 -> 确切语义
    private func nonStrongIvarOwnership(for classPointer: UInt) -> [Int: ReferenceOwnership] {
        _ = ivarNameMap(for: classPointer) // 顺带填充缓存
        return nonStrongIvarOffsetMaps[classPointer] ?? [:]
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
    /// - Swift 反射确认为函数或 Optional<函数> 的字段额外补扫内部字：值宽 16 字节
    ///   （函数指针 + 上下文指针），上下文指针位于字段偏移 +8 处，
    ///   仅当该字不属于下一个字段时补扫。ObjC 类不补扫，避免扫进
    ///   struct ivar 内部或填充区产生噪音；
    /// - 无 ivar 信息时回退从 isa 之后的逐字全扫；未注册 Swift 类的槽位
    ///   所有权只能标未确证 strong，不冒充 fieldmd 已确认的 strong
    private func scanOffsets(nameMap: [Int: String], usableSize: Int, classPointer: UInt,
                             ownershipByOffset: [Int: ReferenceOwnership]) -> [(offset: Int, ownership: ReferenceOwnership)] {
        if let layout = scanLayouts[classPointer]?[usableSize] {
            return layout.map { slot in
                (slot.offset,
                 ownershipByOffset[slot.offset] ?? ownershipByOffset[slot.ownerOffset] ?? .strong)
            }
        }
        var slots: [(offset: Int, ownerOffset: Int)] = []
        let fallbackOwnership: ReferenceOwnership = unregisteredSwiftClassNames[classPointer] == nil
            ? .strong : .unconfirmedStrong
        // 偏移 0 恒为 isa（block 类会暴露名为 isa 的 ivar），不是引用字段；
        // 过滤后无有效字段（如 __NSMallocBlock__ 仅剩 isa）则回退全字扫描
        let fieldOffsets = nameMap.keys.filter { $0 > 0 && $0 % 8 == 0 && $0 + 8 <= usableSize }.sorted()
        if fieldOffsets.isEmpty {
            for offset in stride(from: 8, to: usableSize - 7, by: 8) {
                slots.append((offset, offset))
            }
            // 变长集合缓冲区的大小高度分散，缓存整段逐字槽位会吃掉大量内存。
            return slots.map { ($0.offset, ownershipByOffset[$0.offset] ?? fallbackOwnership) }
        }
        let functionContexts = swiftFunctionContextOffsets[classPointer] ?? []
        for offset in fieldOffsets {
            slots.append((offset, offset))
            let contextOffset = offset + MemoryLayout<UInt>.size
            if functionContexts.contains(contextOffset),
               !nameMap.keys.contains(contextOffset),
               contextOffset + MemoryLayout<UInt>.size <= usableSize {
                slots.append((contextOffset, offset))
            }
        }
        for contextOffset in functionContexts where contextOffset > 0 && contextOffset % 8 == 0
            && contextOffset + 8 <= usableSize && !slots.contains(where: { $0.offset == contextOffset }) {
            let fieldOffset = fieldOffsets.last(where: { $0 < contextOffset })
            if let fieldOffset { slots.append((contextOffset, fieldOffset)) }
        }
        scanLayouts[classPointer, default: [:]][usableSize] = slots
        return slots.map { slot in
            (slot.offset, ownershipByOffset[slot.offset] ?? ownershipByOffset[slot.ownerOffset] ?? .strong)
        }
    }

    /// 透传扫描容器块：跳过 8 字节元数据头，逐字找已识别对象；
    /// 命中嵌套容器（block 内嵌 Swift 闭包上下文等桥接链）时递归，
    /// depth 限制递归层数防止失控
    private func scanContainer(from source: UInt, ivarName: String?, ownership: ReferenceOwnership,
                               containerBase: UnsafeRawPointer, containerSize: Int,
                               seen: inout Set<String>, into: inout [ReferenceEdge], depth: Int = 3) {
        // 普通缓冲区（数组 / 字典 backing 等）元素按强持有处理；Swift 闭包上下文
        // （HeapLocalVariable）的可定位捕获槽由 __swift5_capture 的 CaptureDescriptor 判定：
        // 强捕获标 strong（参与循环检测），weak/unowned 标对应语义，解析不到的槽回落 unknown。
        let context = containerContext(containerBase)
        let captureOwnership = context == .closure
            ? swiftCaptureOwnership(for: UInt(bitPattern: containerBase)) : [:]
        var offset = 8
        while offset + 8 <= containerSize {
            let effective = captureOwnership[offset] ?? (context == .buffer ? ownership : .unknown)
            let word = referencedAddress(base: containerBase,
                                         offset: offset,
                                         ownership: effective,
                                         allowRawWeakStorage: false)
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
                    let nestedLabel = nestedClosureLabel(parentBase: containerBase,
                                                         offset: offset,
                                                         nestedAddress: word,
                                                         fallback: ivarName)
                    scanContainer(from: source,
                                  ivarName: nestedLabel,
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
    /// 类属性的 weak / unowned 已通过 fieldmd / ivarLayout 自动排除，
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
            /// strong / weak / unowned / unownedUnsafe / nonStrong / unknown
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
