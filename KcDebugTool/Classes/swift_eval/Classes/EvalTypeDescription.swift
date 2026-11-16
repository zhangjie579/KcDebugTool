import Foundation
import ObjectiveC

/// 调试页「成员清单」结果：沿继承链逐类列出 Properties / Instance Methods / Class Methods。
///
/// 文本刻意沿用 ObjC 私有调试接口 `_methodDescription` 的风格，方便和 LLDB 输出对照：
/// ```
/// in swiftTest.ViewController:
/// 	Instance Methods:
/// 		- (long) numberOfSectionsInCollectionView:(id)arg1; (0x105853b20)
/// ```
/// ObjC 成员来自 runtime（属性、ivar、实例方法、元类上的类方法）；纯 Swift 成员从 Mach-O
/// 符号补充并标 `[swift]`；Swift 存储属性在 runtime 里是 ivar，用 `(ivar)` 行列出。
/// 这里只读元数据，不实例化对象、不调用 getter，因此不会触发业务副作用。
public struct EvalTypeDescription {

    public struct Member {
        /// 供筛选和链接使用的未格式化成员名；重载的完整区分信息位于 `signature`。
        public let name: String
        /// 接近 LLDB 风格的可读声明，包含类型、地址和成员来源标记。
        public let signature: String
        /// 当前加载地址；ObjC 为 IMP、Swift 为函数符号。仅用于诊断，ASLR 后不可持久化。
        public let address: UInt?
        /// objc / swift / ivar，网页用它做来源标记和筛选。
        public let source: String
        /// 显式业务参数数量，不包含 ObjC 隐含的 self / _cmd。
        public let argumentCount: Int

        /// 将成员投影为 JSON 友好字典，地址固定转换成十六进制字符串以避免 JavaScript 精度丢失。
        public var dictionary: [String: Any] {
            var result: [String: Any] = [
                "name": name,
                "signature": signature,
                "source": source,
                "argumentCount": argumentCount
            ]
            if let address = address {
                result["address"] = "0x" + String(address, radix: 16)
            }
            return result
        }
    }

    public struct Group {
        /// 分组标题，例如 Properties、Instance Methods 或 Class Methods。
        public let title: String
        /// 当前类、当前类别下已经排序并去重的成员快照。
        public let members: [Member]

        /// JSON 传输格式；成员继续调用各自的 `dictionary`。
        public var dictionary: [String: Any] {
            ["title": title, "members": members.map(\.dictionary)]
        }
    }

    public struct Section {
        /// 当前继承链节点的完整 runtime 类名。
        public let className: String
        /// 此类声明的成员分组；父类会作为独立 Section 保持来源清晰。
        public let groups: [Group]

        /// JSON 传输格式。
        public var dictionary: [String: Any] {
            ["className": className, "groups": groups.map(\.dictionary)]
        }
    }

    /// 用户输入的原始目标（地址或类名），去除首尾空白后保存。
    public let target: String
    /// 成功解析后最具体类的完整 runtime 名；失败时保留输入目标。
    public let className: String
    /// 目标是否通过 `0x` 地址而非类名解析，用于 UI 提示地址生命周期限制。
    public let isAddress: Bool
    /// 由最具体类到父类的成员清单，不会实例化对象或主动读取属性值。
    public let sections: [Section]
    /// 元数据可见性、所有权推断与地址有效范围等限制说明。
    public let notes: [String]
    /// 可直接展示的 LLDB 风格文本；与 `sections` 内容等价但不适合程序化消费。
    public let displayText: String
    /// 失败原因；非空即表示本次没有可用的成员清单。
    public let error: String?

    /// 是否成功定位目标并构建成员清单。
    public var isSuccess: Bool { error == nil }

    /// 全部 Section 中成员数量的聚合，供页面快速显示规模。
    public var memberCount: Int {
        sections.reduce(0) { $0 + $1.groups.reduce(0) { $0 + $1.members.count } }
    }

    /// 对应 `/api/describe` 的 JSON 结构；所有地址都已字符串化，适合 JavaScript 消费。
    public var dictionary: [String: Any] {
        var result: [String: Any] = [
            "ok": isSuccess,
            "target": target,
            "className": className,
            "isAddress": isAddress,
            "classCount": sections.count,
            "memberCount": memberCount,
            "display": displayText,
            "sections": sections.map(\.dictionary),
            "notes": notes
        ]
        if let error = error { result["error"] = error }
        return result
    }

    /// target 可以是 `0x...` 对象地址，也可以是短类名或 `Module.Class`。
    /// 与 evaluate 一样默认在主线程执行，避免读 UIKit 元数据时的线程约束。
    public static func describe(target rawTarget: String,
                                includeSwift: Bool = true,
                                includeSuperclasses: Bool = true,
                                includeIvars: Bool = true) -> EvalTypeDescription {
        if SwiftEval.dispatchOnMainThread, !Thread.isMainThread {
            // 非主线程时同步切回主线程，避免读 UIKit 元数据时的线程约束。
            var result: EvalTypeDescription?
            DispatchQueue.main.sync {
                result = build(target: rawTarget, includeSwift: includeSwift,
                               includeSuperclasses: includeSuperclasses, includeIvars: includeIvars)
            }
            if let result = result { return result }
        }
        return build(target: rawTarget, includeSwift: includeSwift,
                     includeSuperclasses: includeSuperclasses, includeIvars: includeIvars)
    }

    // MARK: - 目标解析与继承链

    /// 解析目标、收集继承链，并把 runtime/Mach-O 元数据汇总为 Section；失败不抛错而返回统一失败模型。
    private static func build(target rawTarget: String, includeSwift: Bool,
                              includeSuperclasses: Bool, includeIvars: Bool) -> EvalTypeDescription {
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return failure(target: target, message: "请输入对象地址或类名")
        }
        let isAddress = parseAddress(target) != nil
        let rootClass: AnyClass
        if let address = parseAddress(target) {
            do {
                // 沿用 eval 的地址校验：isa 必须属于当前 runtime 类表且对象仍存活。
                let resolved = try ObjectiveCEvalBridge.object(at: address)
                guard let cls = object_getClass(resolved.value) else {
                    return failure(target: target, message: "对象地址 0x\(String(address, radix: 16)) 没有 runtime 类")
                }
                rootClass = cls
            } catch let error as EvalError {
                return failure(target: target, message: error.description)
            } catch {
                return failure(target: target, message: "解析对象地址失败：\(error)")
            }
        } else if let cls = ObjectiveCEvalBridge.findClass(named: target) {
            rootClass = cls
        } else if let cls = SwiftMachOInvoker.classType(named: target) {
            // 纯 Swift 类不在 NSClassFromString 名字表里，但类型元数据可直接当类对象用。
            rootClass = cls
        } else {
            return failure(target: target, message: "找不到类「\(target)」",
                           suggestion: "可输入完整类名（Module.Class）或 0x 开头的存活对象地址")
        }

        // 纯 Swift 类同样有 isa / superclass，class_getSuperclass 会一直走到 _SwiftObject。
        var classes: [AnyClass] = []
        var current: AnyClass? = rootClass
        while let cls = current, classes.count < 64 {
            // 沿继承链逐类收集，最多 64 层以免无限循环。
            classes.append(cls)
            current = includeSuperclasses ? class_getSuperclass(cls) : nil
        }
        let classNames = classes.map(name(of:))
        let className = classNames.first ?? target
        // 一次性按类型名批量拉取 Swift 符号（避免逐类重复扫整张符号表）。
        let swiftMembers = includeSwift
            ? SwiftMachOInvoker.memberDescriptions(forTypeNames: classNames)
            : [:]
        var sections: [Section] = []
        for index in classes.indices {
            let cls: AnyClass = classes[index]
            let key = SwiftEvalRegistry.key(classNames[index])
            // 为当前类合并 ObjC + Swift 成员，分组排序后作为独立 Section。
            let groups = groups(of: cls, swift: swiftMembers[key] ?? [], includeIvars: includeIvars)
            if !groups.isEmpty {
                sections.append(Section(className: classNames[index], groups: groups))
            }
        }

        var lines: [String] = []
        for (index, section) in sections.enumerated() {
            if index > 0 { lines.append("") }
            lines.append("in \(section.className):")
            for group in section.groups {
                lines.append("\(group.title):")
                for member in group.members { lines.append("\t\(member.signature)") }
            }
        }
        let displayText = lines.isEmpty ? "(没有可见成员)" : lines.joined(separator: "\n")

        var notes: [String] = []
        if includeSwift {
            notes.append("[swift] 行来自 Mach-O 符号表（Strip / LTO 会减少可见数量），与同名 ObjC selector 重复的已去除。")
        }
        if includeIvars {
            notes.append("(ivar) 行是 runtime ivar，对应 Swift 存储属性 / ObjC 实例变量；$__lazy_storage_$_name 与 _name 还原成业务属性名，类型取同名 Swift getter 或 @property，取不到时为 id。")
            notes.append("ivar 的 strong / weak / unowned / unowned(unsafe) 来自 Mach-O __swift5_fieldmd 字段描述符的类型 mangling（只读元数据，不实例化、不读属性值）；Strip 掉反射元数据或纯 ObjC ivar 无法判定时退化为不带所有权的 (ivar)。")
        }
        notes.append("(0x...) 是方法 IMP 或 Swift 符号的当前加载地址；地址输入只支持仍存活且已注册到 runtime 的对象。")
        if !includeSuperclasses { notes.append("已关闭父类，只列出 \(className) 自身声明的成员。") }

        return EvalTypeDescription(target: target, className: className, isAddress: isAddress,
                                   sections: sections, notes: notes,
                                   displayText: displayText, error: nil)
    }

    /// 生成结构完整的失败结果，使 HTTP 客户端无需区分异常响应和正常 describe JSON。
    private static func failure(target: String, message: String,
                                suggestion: String? = nil) -> EvalTypeDescription {
        let display = message + (suggestion.map { "\n\($0)" } ?? "")
        return EvalTypeDescription(target: target, className: "", isAddress: parseAddress(target) != nil,
                                   sections: [], notes: [], displayText: display, error: message)
    }

    /// 仅解析带 `0x`/`0X` 前缀的十六进制对象地址，防止普通数字类名被误当指针。
    private static func parseAddress(_ text: String) -> UInt? {
        var hex = text
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard !hex.isEmpty, hex.count <= 16,
              hex.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else { return nil }
        // 无 0x 前缀时至少 8 位，避免把短类名误判成地址。
        guard text.hasPrefix("0x") || text.hasPrefix("0X") || hex.count >= 8 else { return nil }
        return UInt(hex, radix: 16)
    }

    /// 读取 runtime 保存的完整类名；空名称时退化为 Swift 反射类型名。
    private static func name(of cls: AnyClass) -> String {
        String(cString: class_getName(cls))
    }

    // MARK: - 单类成员

    /// 收集单个类直接声明的 ObjC 属性/ivar/方法并合并同类 Swift 符号，随后按展示组排序。
    private static func groups(of cls: AnyClass, swift: [SwiftMachOInvoker.MemberDescription],
                               includeIvars: Bool) -> [Group] {
        var properties: [Member] = []
        var instanceMethods: [Member] = []
        var classMethods: [Member] = []
        // Swift 符号与 @objc 方法会同时出现；按「名字前缀 + 参数个数」去掉 ObjC 已覆盖的项。
        var objcInstanceNames: [(String, Int)] = []
        var objcClassNames: [(String, Int)] = []
        var propertyNames = Set<String>()
        // Swift 存储属性在 runtime 里没有有效 type encoding：先收集 ObjC @property 与
        // Swift getter 的声明类型，供同名 ivar（含 lazy backing storage）补类型。
        var propertyTypes = Dictionary(
            swift.filter { $0.group == .property }
                .map { ($0.name, shortSwiftType($0.returnType)) },
            uniquingKeysWith: { first, _ in first })

        // 先收集实例属性，再收集元类上的类属性；两者都进 properties 分组。
        collectObjCProperties(cls, isClassProperty: false, into: &properties,
                              names: &propertyNames, types: &propertyTypes)
        if let metaClass = object_getClass(cls) {
            collectObjCProperties(metaClass, isClassProperty: true, into: &properties,
                                  names: &propertyNames, types: &propertyTypes)
        }
        if includeIvars {
            // 仅在需要时枚举 runtime ivar，并以同名 property/Swift getter 补足类型。
            collectIvars(cls, propertyTypes: propertyTypes,
                         into: &properties, names: &propertyNames)
        }
        // 收集实例方法（及元类上的类方法），记录名字+参数数供 Swift 符号去重。
        collectObjCMethods(cls, isClassMethod: false, into: &instanceMethods,
                           names: &objcInstanceNames)
        if let metaClass = object_getClass(cls) {
            collectObjCMethods(metaClass, isClassMethod: true, into: &classMethods,
                               names: &objcClassNames)
        }
        // 最后并入 Swift 符号，去掉与 ObjC selector 重复的桥接成员。
        appendSwiftMembers(swift, properties: &properties, instanceMethods: &instanceMethods,
                           classMethods: &classMethods, propertyNames: &propertyNames,
                           objcInstanceNames: objcInstanceNames, objcClassNames: objcClassNames)

        let sortedProperties = sorted(properties)
        let sortedInstanceMethods = sorted(instanceMethods)
        let sortedClassMethods = sorted(classMethods)
        var result: [Group] = []
        if !sortedProperties.isEmpty { result.append(Group(title: "Properties", members: sortedProperties)) }
        if !sortedInstanceMethods.isEmpty {
            result.append(Group(title: "Instance Methods", members: sortedInstanceMethods))
        }
        if !sortedClassMethods.isEmpty {
            result.append(Group(title: "Class Methods", members: sortedClassMethods))
        }
        return result
    }

    /// 以成员名、签名和地址稳定排序，保证同一进程内刷新页面不会出现随机顺序。
    private static func sorted(_ members: [Member]) -> [Member] {
        members.sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.signature < rhs.signature
        }
    }

    /// 枚举类或元类直接声明的 property，解析 attributes 中的类型、读写性、内存语义和 getter/setter。
    private static func collectObjCProperties(_ owner: AnyClass, isClassProperty: Bool,
                                              into properties: inout [Member],
                                              names: inout Set<String>,
                                              types: inout [String: String]) {
        var count: UInt32 = 0
        guard let list = class_copyPropertyList(owner, &count) else { return }
        defer { free(list) }
        for index in 0..<Int(count) {
            let property = list.advanced(by: index).pointee
            let propertyName = cString(property_getName(property))
            guard !propertyName.isEmpty, names.insert(propertyName).inserted else { continue }
            let attributes = cString(property_getAttributes(property))
                .split(separator: ",").map(String.init)
            let rawType = attributes.first(where: { $0.hasPrefix("T") }).map { String($0.dropFirst()) } ?? ""
            let typeName = EvalObjCTypeName.readable(rawType)
            var qualifiers: [String] = isClassProperty ? ["class"] : []
            for attribute in attributes where !attribute.hasPrefix("T") {
                switch attribute {
                case "N": qualifiers.append("nonatomic")
                case "&": qualifiers.append("strong")
                case "C": qualifiers.append("copy")
                case "W": qualifiers.append("weak")
                case "R": qualifiers.append("readonly")
                case "D": qualifiers.append("dynamic")
                default:
                    if attribute.hasPrefix("G") { qualifiers.append("getter=" + String(attribute.dropFirst())) }
                    if attribute.hasPrefix("S") { qualifiers.append("setter=" + String(attribute.dropFirst())) }
                }
            }
            // 同名 backing ivar 没有 type encoding 时，用 @property 的 T 编码补类型。
            if types[propertyName] == nil, !typeName.isEmpty, typeName != "?" {
                types[propertyName] = typeName
            }
            let qualifierText = qualifiers.isEmpty ? "" : " (" + qualifiers.joined(separator: ", ") + ")"
            let separator = typeName.hasSuffix("*") ? "" : " "
            properties.append(Member(name: propertyName,
                                     signature: "@property\(qualifierText) \(typeName)\(separator)\(propertyName);",
                                     address: nil, source: "objc", argumentCount: 0))
        }
    }

    /// `lazy var` 与 property wrapper 的 backing ivar 是编译器内部命名，
    /// 清单里统一还原成业务属性名，和 Mirror 展示的处理保持一致。
    private static let lazyStoragePrefix = "$__lazy_storage_$_"

    private static func normalizedIvarName(_ rawName: String) -> String {
        if rawName.hasPrefix(lazyStoragePrefix) {
            return String(rawName.dropFirst(lazyStoragePrefix.count))
        }
        if rawName.hasPrefix("_") { return String(rawName.dropFirst()) }
        return rawName
    }

    /// 枚举 runtime ivar，并以同名 property 或 Swift getter 补足类型；所有权来自 `__swift5_fieldmd` 元数据。
    private static func collectIvars(_ owner: AnyClass, propertyTypes: [String: String],
                                     into properties: inout [Member], names: inout Set<String>) {
        var count: UInt32 = 0
        guard let list = class_copyIvarList(owner, &count) else { return }
        defer { free(list) }
        // 字段描述符用的是编译期原始名（含 $__lazy_storage_$_ 前缀），按原始名一次性查所有权，
        // 展示时再归一化；纯 ObjC 类的 ivar 在 Swift 字段描述符里没有对应项，返回空串即不标注。
        let rawNames = (0..<Int(count)).map { cString(ivar_getName(list.advanced(by: $0).pointee)) }
        let ownership = SEMachOSymbolResolver.fieldOwnership(forIvarNames: rawNames)
        for index in 0..<Int(count) {
            let ivar = list.advanced(by: index).pointee
            let ivarName = rawNames[index]
            let displayName = normalizedIvarName(ivarName)
            // backing ivar 已由同名 @property / Swift getter 表达时，只保留那一行。
            guard !displayName.isEmpty, names.insert(displayName).inserted else { continue }
            let decoded = EvalObjCTypeName.readable(cString(ivar_getTypeEncoding(ivar)))
                .trimmingCharacters(in: .whitespaces)
            // 纯 Swift ivar 的 encoding 是空串：按业务名取 Swift getter 或 ObjC @property 的声明类型。
            let typeName = !decoded.isEmpty && decoded != "?"
                ? decoded : (propertyTypes[displayName] ?? propertyTypes[ivarName] ?? "id")
            let separator = typeName.hasSuffix("*") ? "" : " "
            let qualifier = index < ownership.count && !ownership[index].isEmpty
                ? "ivar, \(ownership[index])" : "ivar"
            properties.append(Member(name: displayName,
                                     signature: "@property (\(qualifier)) \(typeName)\(separator)\(displayName);",
                                     address: nil, source: "ivar", argumentCount: 0))
        }
    }

    /// 枚举当前类/元类直接实现的 Method，保留 IMP 地址和显式参数数以支持调用目录与筛选。
    private static func collectObjCMethods(_ owner: AnyClass, isClassMethod: Bool,
                                           into methods: inout [Member],
                                           names: inout [(String, Int)]) {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(owner, &count) else { return }
        defer { free(list) }
        for index in 0..<Int(count) {
            let method = list.advanced(by: index).pointee
            let selector = NSStringFromSelector(method_getName(method))
            let argumentCount = max(Int(method_getNumberOfArguments(method)) - 2, 0)
            let signature = objcMethodSignature(method, selector: selector,
                                                argumentCount: argumentCount,
                                                isClassMethod: isClassMethod)
            let baseName = selector.split(separator: ":").first.map(String.init) ?? selector
            let imp = method_getImplementation(method)
            let address = UInt(bitPattern: unsafeBitCast(imp, to: UnsafeRawPointer.self))
            methods.append(Member(name: baseName, signature: signature, address: address,
                                  source: "objc", argumentCount: argumentCount))
            names.append((baseName.lowercased(), argumentCount))
        }
    }

    /// 将 ObjC selector 与每个 type encoding 格式化为接近 Swift 的声明文本；原编码仍由调用层使用。
    private static func objcMethodSignature(_ method: Method, selector: String,
                                            argumentCount: Int, isClassMethod: Bool) -> String {
        // ObjC 方法也统一成 Swift 声明式：name(_: Type, label: Type) -> ReturnType (0x...) [objc]。
        // selector 的第一段是方法名、其余分段作为外部参数标签；第一个参数对应 Swift 的「_」无标签。
        let returnType = objcTypeForSwift(EvalObjCTypeName.readable(copiedString(method_copyReturnType(method))))
        let parts = selector.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let baseName = parts.first ?? selector
        let params: [String] = (0..<argumentCount).map { index in
            let part = index < parts.count ? parts[index] : ""
            let type = objcTypeForSwift(EvalObjCTypeName.readable(
                copiedString(method_copyArgumentType(method, UInt32(index + 2)))))
            let label = (index == 0 || part.isEmpty) ? "_" : part
            return "\(label): \(type)"
        }
        let imp = method_getImplementation(method)
        let address = UInt(bitPattern: unsafeBitCast(imp, to: UnsafeRawPointer.self))
        return "\(baseName)(\(params.joined(separator: ", "))) -> \(returnType) (0x\(String(address, radix: 16))) [objc]"
    }

    /// ObjC 类型编码 → Swift 风格展示：去掉 __C. 模块前缀与指针星号，void 读作 Void。
    private static func objcTypeForSwift(_ encoding: String) -> String {
        var text = encoding.replacingOccurrences(of: "__C.", with: "")
            .replacingOccurrences(of: " *", with: "")
        if text == "void" { text = "Void" }
        return text.isEmpty ? "id" : text
    }

    /// 将已解析的 Swift 符号去重后归入属性/实例方法/类方法，并删除与 ObjC selector 重复的桥接成员。
    private static func appendSwiftMembers(_ items: [SwiftMachOInvoker.MemberDescription],
                                           properties: inout [Member],
                                           instanceMethods: inout [Member],
                                           classMethods: inout [Member],
                                           propertyNames: inout Set<String>,
                                           objcInstanceNames: [(String, Int)],
                                           objcClassNames: [(String, Int)]) {
        var seen = Set<String>()
        for item in items {
            let hex = String(item.address, radix: 16)
            switch item.group {
            case .property:
                guard propertyNames.insert(item.name).inserted else { continue }
                let qualifier = item.isClassMember ? "swift, class" : "swift"
                properties.append(Member(name: item.name,
                                         signature: "@property (\(qualifier)) \(shortSwiftType(item.returnType)) \(item.name); (0x\(hex)) [swift]",
                                         address: item.address, source: "swift", argumentCount: 0))
            case .instanceMethod, .classMethod:
                let isClassMethod = item.group == .classMethod
                let objcNames = isClassMethod ? objcClassNames : objcInstanceNames
                let bare = item.name.lowercased()
                if objcNames.contains(where: { $0.0.hasPrefix(bare) && $0.1 == item.parameterTypes.count }) {
                    continue
                }
                // Swift 声明式：name(externalLabel: Type, ...) -> ReturnType。
                // Mach-O 符号只保留外部参数标签，运行时无法还原内部参数名，
                // 因此 _ 标签输出「_: Type」，具名标签输出「label: Type」（外部名即内部名）。
                let swiftParams = zip(item.labels, item.parameterTypes).map { label, type in
                    let t = shortSwiftType(type)
                    return (label.isEmpty || label == "_") ? "_: \(t)" : "\(label): \(t)"
                }.joined(separator: ", ")
                let swiftSig = "\(item.name)(\(swiftParams)) -> \(shortSwiftType(item.returnType))"
                // 同名重载可能有多个符号地址；清单按签名去重，调用侧仍由标签消歧。
                guard seen.insert(swiftSig).inserted else { continue }
                let signature = "\(swiftSig) (0x\(hex)) [swift]"
                let member = Member(name: item.name, signature: signature, address: item.address,
                                    source: "swift", argumentCount: item.parameterTypes.count)
                if isClassMethod {
                    classMethods.append(member)
                } else {
                    instanceMethods.append(member)
                }
            }
        }
    }

    /// 清理符号展示中的 `Swift.` 与 `__C.` 桥接前缀，并将空元组显示为 Void。
    private static func shortSwiftType(_ typeName: String) -> String {
        let text = typeName.replacingOccurrences(of: "Swift.", with: "")
            // Swift 桥接的 ObjC 类在符号里带 __C. 模块前缀，展示时去掉（如 __C.UITableView → UITableView）。
            .replacingOccurrences(of: "__C.", with: "")
        return text == "()" ? "Void" : text
    }

    // MARK: - C 字符串

    /// 将 runtime 借用的 C 字符串转为 Swift String；nil 统一为空串，不负责释放内存。
    private static func cString(_ pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer = pointer else { return "" }
        return String(cString: pointer)
    }

    /// runtime 的 copy*Type 返回 malloc 出来的 C 字符串，必须逐个释放。
    private static func copiedString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer = pointer else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

/// ObjC type encoding → 可读类型名，仅用于展示；调用侧仍按原始编码走 NSInvocation。
enum EvalObjCTypeName {

    static func readable(_ encoding: String) -> String {
        let characters = Array(encoding)
        var index = 0
        return read(characters, &index)
    }

    /// 递归消费一个 ObjC encoding 类型单元；调用者传入共享游标以正确跳过嵌套指针和聚合体。
    private static func read(_ chars: [Character], _ index: inout Int) -> String {
        while index < chars.count, "rnNoORVj".contains(chars[index]) { index += 1 }
        guard index < chars.count else { return "?" }
        let char = chars[index]
        index += 1
        switch char {
        case "v": return "void"
        case "c": return "char"
        case "C": return "unsigned char"
        case "s": return "short"
        case "S": return "unsigned short"
        case "i": return "int"
        case "I": return "unsigned int"
        case "l": return "long"
        case "L": return "unsigned long"
        case "q": return "long"
        case "Q": return "unsigned long"
        case "f": return "float"
        case "d": return "double"
        case "D": return "long double"
        case "B": return "BOOL"
        case "*": return "char *"
        case ":": return "SEL"
        case "#": return "Class"
        case "@": return objectType(chars, &index)
        case "^": return read(chars, &index) + " *"
        case "?": return "unknown"
        case "{": return "struct " + namedAggregate(balanced(chars, &index, open: "{", close: "}"))
        case "(": return "union " + namedAggregate(balanced(chars, &index, open: "(", close: ")"))
        case "[":
            let content = balanced(chars, &index, open: "[", close: "]")
            return readable(String(content.drop(while: { $0.isNumber }))) + "[]"
        case "b":
            while index < chars.count, chars[index].isNumber { index += 1 }
            return "bitfield"
        default: return String(char)
        }
    }

    /// 解析 `@` 后的对象/class/block encoding，并去掉桥接模块前缀以生成可读展示。
    private static func objectType(_ chars: [Character], _ index: inout Int) -> String {
        if index < chars.count, chars[index] == "?" {
            index += 1
            return "id /* block */"
        }
        if index < chars.count, chars[index] == "\"" {
            index += 1
            var name = ""
            while index < chars.count, chars[index] != "\"" {
                name.append(chars[index])
                index += 1
            }
            if index < chars.count { index += 1 }
            return name.isEmpty ? "id" : name.replacingOccurrences(of: "__C.", with: "") + " *"
        }
        return "id"
    }

    /// 跳过结构体 / union / 数组的完整内容，只取 `{name=...}` 里的名字。
    private static func balanced(_ chars: [Character], _ index: inout Int,
                                 open: Character, close: Character) -> String {
        var depth = 1
        var content = ""
        while index < chars.count, depth > 0 {
            let char = chars[index]
            index += 1
            if char == open { depth += 1 }
            if char == close {
                depth -= 1
                if depth == 0 { break }
            }
            content.append(char)
        }
        return content
    }

    /// 从 `{Name=...}` 或 `(Name=...)` 聚合 encoding 中只提取名称，避免把内部字段展开到成员清单。
    private static func namedAggregate(_ content: String) -> String {
        let name = content.split(separator: "=").first.map(String.init) ?? "?"
        return name.isEmpty ? "?" : name
    }
}
