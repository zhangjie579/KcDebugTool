#import "SEMachOSymbolResolver.h"

#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <string.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/runtime.h>

typedef char *(*SESwiftDemangle)(const char *, size_t, char *, size_t *, uint32_t);

/// 已加载镜像中一个 section 的运行时地址区间，用于校验字段描述符的相对指针目标。
typedef struct {
    uintptr_t start;
    uintptr_t end;
} SESectionRange;

/// `__swift5_fieldmd` section 的运行时地址与长度。
typedef struct {
    uintptr_t address;
    uint64_t size;
} SEFieldSection;

/// 相对指针目标必须落在当前镜像已映射的 section 内，返回该处到 section 末尾的可读上限。
/// 字段描述符里的相对指针可能被 strip 或指向异常地址，不能无条件解引用。
static size_t SESectionByteLimit(uintptr_t target, const SESectionRange *ranges, size_t count) {
    for (size_t index = 0; index < count; index++) {
        if (target >= ranges[index].start && target < ranges[index].end) {
            return (size_t)(ranges[index].end - target);
        }
    }
    return 0;
}

/// 在已知长度上限内读 NUL 结尾字符串；字段名在 __swift5_reflstr，都是 ASCII。
static NSString * _Nullable SEBoundedCString(const uint8_t *bytes, size_t limit) {
    size_t length = 0;
    while (length < limit && bytes[length] != 0) { length++; }
    if (length == 0 || length == limit) { return nil; }
    NSString *text = [[NSString alloc] initWithBytes:bytes length:length
                                            encoding:NSUTF8StringEncoding];
    return text ?: [[NSString alloc] initWithBytes:bytes length:length
                                          encoding:NSISOLatin1StringEncoding];
}

/// 字段类型 mangling 的尾缀决定所有权：Xw=weak、Xo=unowned、Xu=unowned(unsafe)/unmanaged。
/// 自定义类型会内嵌 symbolic reference（0x01/0x02 + 4 字节相对指针），指针里可能含 0 字节，
/// 不能按普通 C 字符串扫描；这里跳过这 5 字节，只记录其余 mangling 字符的末尾两字节。
static NSString *SEOwnershipFromFieldType(const uint8_t *bytes, size_t limit) {
    uint8_t previous = 0;
    uint8_t current = 0;
    size_t index = 0;
    while (index < limit) {
        uint8_t byte = bytes[index];
        if (byte == 0) { break; }
        if (byte == 0x01 || byte == 0x02) {
            if (index + 5 > limit) { break; }
            index += 5;
            continue;
        }
        previous = current;
        current = byte;
        index++;
    }
    if (previous == 'X') {
        switch (current) {
        case 'w': return @"weak";
        case 'o': return @"unowned";
        case 'u': return @"unowned(unsafe)";
        default: break;
        }
    }
    return @"strong";
}

/// 跳过 ObjC encoding 的 const/in/out/bycopy 等前缀修饰符，返回真正决定内存布局的首字符。
/// `NSInvocation` 的返回和 ivar 编码都可能携带这些修饰符；不先跳过会把可装箱标量误判为未知类型。
static const char *SESkipTypeQualifiers(const char *type) {
    while (type != NULL && strchr("rnNoORV", type[0]) != NULL) { type++; }
    return type;
}

/// 按 `NSMethodSignature` 的真实 ABI 编码从 `NSInvocation` 取回结果并装箱为 Foundation 对象。
/// 对象使用 `__unsafe_unretained` 避免读返回槽时额外改变 ARC 所有权；标量用正确宽度的局部变量读取；
/// 结构体等未专门解释的布局封装为 `NSValue` 描述文本。void 和 nil 均返回 NSNull，区分信息由调用方的 isVoid 保存。
static id SEBoxInvocationReturn(NSInvocation *invocation, NSMethodSignature *signature) {
    const char *type = SESkipTypeQualifiers(signature.methodReturnType);
    if (type == NULL || type[0] == 'v') { return NSNull.null; }
    if (strncmp(type, "@?", 2) == 0) { return @"<block>"; }
    if (type[0] == '@' || type[0] == '#') {
        __unsafe_unretained id value = nil;
        [invocation getReturnValue:&value];
        return value ?: NSNull.null;
    }
#define SE_BOX_SCALAR(TYPE) do { TYPE value = 0; [invocation getReturnValue:&value]; return @(value); } while (0)
    switch (type[0]) {
    case 'B': SE_BOX_SCALAR(BOOL);
    case 'c': SE_BOX_SCALAR(char);
    case 'C': SE_BOX_SCALAR(unsigned char);
    case 's': SE_BOX_SCALAR(short);
    case 'S': SE_BOX_SCALAR(unsigned short);
    case 'i': SE_BOX_SCALAR(int);
    case 'I': SE_BOX_SCALAR(unsigned int);
    case 'l': SE_BOX_SCALAR(long);
    case 'L': SE_BOX_SCALAR(unsigned long);
    case 'q': SE_BOX_SCALAR(long long);
    case 'Q': SE_BOX_SCALAR(unsigned long long);
    case 'f': SE_BOX_SCALAR(float);
    case 'd': SE_BOX_SCALAR(double);
    case ':': {
        SEL value = NULL;
        [invocation getReturnValue:&value];
        return value == NULL ? NSNull.null : NSStringFromSelector(value);
    }
    default: break;
    }
#undef SE_BOX_SCALAR
    NSUInteger length = signature.methodReturnLength;
    if (length == 0) { return NSNull.null; }
    void *bytes = calloc(1, length);
    if (bytes == NULL) { return @"<无法分配返回值缓冲区>"; }
    [invocation getReturnValue:bytes];
    NSValue *value = [NSValue valueWithBytes:bytes objCType:type];
    free(bytes);
    return value.description ?: @"<无法展示的返回值>";
}

/// UIKit 某些看似普通的 getter 会按对象内部状态抛异常（例如 UIColor.CIColor），
/// 异常即使被捕获也会触发 Xcode 的 Objective-C Exception 断点。UI 对象只自动读取
/// 无参数标量 getter 和经过确认的常用展示属性，其余仍输出 owner/type 元数据。
static BOOL SECanInvokeUIPropertyGetter(NSString *propertyName, SEL getter) {
    static NSSet<NSString *> *safeNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        safeNames = [NSSet setWithArray:@[
            @"frame", @"bounds", @"center", @"transform", @"contentScaleFactor",
            @"tag", @"alpha", @"hidden", @"isHidden", @"opaque", @"isOpaque",
            @"clipsToBounds", @"userInteractionEnabled", @"isUserInteractionEnabled",
            @"contentMode", @"backgroundColor", @"tintColor", @"superview", @"subviews",
            @"window", @"layer", @"constraints", @"safeAreaInsets", @"layoutMargins",
            @"directionalLayoutMargins", @"accessibilityIdentifier", @"text", @"attributedText",
            @"font", @"textColor", @"textAlignment", @"numberOfLines", @"image",
            @"highlightedImage", @"title", @"currentTitle", @"currentImage", @"currentTitleColor",
            @"isViewLoaded", @"parentViewController", @"childViewControllers",
            @"presentedViewController", @"presentingViewController", @"name", @"superlayer",
            @"sublayers", @"position", @"anchorPoint", @"zPosition", @"opacity",
            @"cornerRadius", @"borderWidth", @"borderColor", @"shadowColor", @"shadowOpacity",
            @"shadowOffset", @"shadowRadius", @"CGColor"
        ]];
    });
    return [safeNames containsObject:propertyName] ||
        [safeNames containsObject:NSStringFromSelector(getter)];
}

/// 直接读取 property 对应的 backing ivar，不触发 getter、KVC、消息转发或 category 逻辑。
/// 在不发送消息的前提下读取 ivar。对象 ivar 用 runtime API 获取，其余标量基于 ivar offset 从对象内存复制。
/// 这避免属性 getter 的副作用和异常；未知聚合类型不解包为业务字段，只返回 NSValue 的描述以保证读取不越界。
static id SEBoxIvarValue(id object, Ivar ivar) {
    const char *type = SESkipTypeQualifiers(ivar_getTypeEncoding(ivar));
    if (type == NULL) { return @"<未知 ivar 类型>"; }
    if (strncmp(type, "@?", 2) == 0) { return @"<block>"; }
    if (type[0] == '@' || type[0] == '#') {
        id value = object_getIvar(object, ivar);
        return value ?: NSNull.null;
    }
    const uint8_t *bytes = (const uint8_t *)(__bridge const void *)object + ivar_getOffset(ivar);
#define SE_READ_IVAR(TYPE) do { TYPE value = 0; memcpy(&value, bytes, sizeof(value)); return @(value); } while (0)
    switch (type[0]) {
    case 'B': SE_READ_IVAR(BOOL);
    case 'c': SE_READ_IVAR(char);
    case 'C': SE_READ_IVAR(unsigned char);
    case 's': SE_READ_IVAR(short);
    case 'S': SE_READ_IVAR(unsigned short);
    case 'i': SE_READ_IVAR(int);
    case 'I': SE_READ_IVAR(unsigned int);
    case 'l': SE_READ_IVAR(long);
    case 'L': SE_READ_IVAR(unsigned long);
    case 'q': SE_READ_IVAR(long long);
    case 'Q': SE_READ_IVAR(unsigned long long);
    case 'f': SE_READ_IVAR(float);
    case 'd': SE_READ_IVAR(double);
    case ':': {
        SEL value = NULL;
        memcpy(&value, bytes, sizeof(value));
        return value == NULL ? NSNull.null : NSStringFromSelector(value);
    }
    case '^': case '*': {
        uintptr_t value = 0;
        memcpy(&value, bytes, sizeof(value));
        return [NSString stringWithFormat:@"0x%llx", (unsigned long long)value];
    }
    default: break;
    }
#undef SE_READ_IVAR
    NSUInteger size = 0;
    NSGetSizeAndAlignment(type, &size, NULL);
    if (size == 0) { return @"<无法读取的 ivar 类型>"; }
    NSValue *value = [NSValue valueWithBytes:bytes objCType:type];
    return value.description ?: @"<无法展示的 ivar>";
}

#if defined(__arm64__)
extern void SEInvokeSwiftArm64(void *function,
                              void *context,
                              const uint64_t generalWords[8],
                              const uint64_t floatingWords[8],
                              uint64_t outputGeneral[3],
                              uint64_t outputFloating[4]);
#endif

@implementation SEMachOSymbolResolver

/// 扫描全部已加载 Mach-O 镜像的可执行 section，筛选 Swift mangled 函数并 demangle；按镜像数量缓存，
/// 新动态库加载后自动重建。只返回符号元数据和 ASLR 后地址，不执行任何 Swift 函数。
+ (NSArray<NSDictionary<NSString *,id> *> *)allSwiftSymbols {
    SESwiftDemangle demangle = (SESwiftDemangle)dlsym(RTLD_DEFAULT, "swift_demangle");
    if (demangle == NULL) { return @[]; }

    // Swift mangling 会用 substitution 压缩重复的模块名 / 类型名前缀，例如
    // SawaNewHomeViewController 在 mangled 名中可能变成 `0A21NewHomeViewController`。
    // 因此不能在 demangle 前用完整类型名过滤。这里按已加载镜像数缓存全部 Swift
    // 函数符号；新增动态镜像后自动重建，后续类型查询只过滤 demangled 字符串。
    static NSArray<NSDictionary<NSString *, id> *> *cachedSymbols;
    static uint32_t cachedImageCount;
    NSArray<NSDictionary<NSString *, id> *> *symbolsSnapshot;
    uint32_t imageCount = _dyld_image_count();
    @synchronized (self) {
        if (cachedSymbols == nil || cachedImageCount != imageCount) {
            NSMutableArray<NSDictionary<NSString *, id> *> *allSymbols = NSMutableArray.array;
            for (uint32_t imageIndex = 0; imageIndex < imageCount; imageIndex++) {
                const struct mach_header_64 *header =
                    (const struct mach_header_64 *)_dyld_get_image_header(imageIndex);
                if (header == NULL || header->magic != MH_MAGIC_64) { continue; }
                intptr_t slide = _dyld_get_image_vmaddr_slide(imageIndex);
                const struct symtab_command *symbolTable = NULL;
                const struct segment_command_64 *linkedit = NULL;
                BOOL executableSections[256] = {NO};
                uint32_t sectionOrdinal = 1;
                const uint8_t *commandAddress = (const uint8_t *)(header + 1);
                for (uint32_t commandIndex = 0; commandIndex < header->ncmds; commandIndex++) {
                    const struct load_command *command = (const struct load_command *)commandAddress;
                    if (command->cmd == LC_SYMTAB) {
                        symbolTable = (const struct symtab_command *)command;
                    } else if (command->cmd == LC_SEGMENT_64) {
                        const struct segment_command_64 *segment =
                            (const struct segment_command_64 *)command;
                        if (strcmp(segment->segname, SEG_LINKEDIT) == 0) { linkedit = segment; }
                        const struct section_64 *sections =
                            (const struct section_64 *)(segment + 1);
                        for (uint32_t sectionIndex = 0; sectionIndex < segment->nsects;
                             sectionIndex++, sectionOrdinal++) {
                            if (sectionOrdinal < 256 &&
                                (sections[sectionIndex].flags &
                                 (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS)) != 0) {
                                executableSections[sectionOrdinal] = YES;
                            }
                        }
                    }
                    commandAddress += command->cmdsize;
                }
                if (symbolTable == NULL || linkedit == NULL) { continue; }

                uintptr_t linkeditBase = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
                const struct nlist_64 *symbols =
                    (const struct nlist_64 *)(linkeditBase + symbolTable->symoff);
                const char *strings = (const char *)(linkeditBase + symbolTable->stroff);
                NSString *image =
                    [NSString stringWithUTF8String:_dyld_get_image_name(imageIndex) ?: ""];
                for (uint32_t symbolIndex = 0; symbolIndex < symbolTable->nsyms; symbolIndex++) {
                    const struct nlist_64 symbol = symbols[symbolIndex];
                    if ((symbol.n_type & N_STAB) != 0 ||
                        (symbol.n_type & N_TYPE) != N_SECT || symbol.n_value == 0 ||
                        symbol.n_sect == 0 || !executableSections[symbol.n_sect]) {
                        continue;
                    }
                    if (symbol.n_un.n_strx == 0 ||
                        symbol.n_un.n_strx >= symbolTable->strsize) { continue; }
                    const char *rawName = strings + symbol.n_un.n_strx;
                    const char *mangled = rawName[0] == '_' ? rawName + 1 : rawName;
                    // 只处理 Swift 符号前缀（$s/$S），跳过 ObjC 与无名符号。
                    if (strncmp(mangled, "$s", 2) != 0 &&
                        strncmp(mangled, "$S", 2) != 0) { continue; }
                    // 调用 runtime 的 swift_demangle 还原符号声明，失败则跳过该符号。
                    char *demangledCString =
                        demangle(mangled, strlen(mangled), NULL, NULL, 0);
                    if (demangledCString == NULL) { continue; }
                    NSString *demangledName =
                        [NSString stringWithUTF8String:demangledCString];
                    free(demangledCString);
                    if (demangledName == nil) { continue; }
                    uintptr_t address = (uintptr_t)slide + (uintptr_t)symbol.n_value;
                    [allSymbols addObject:@{
                        @"address": @(address),
                        @"mangled": [NSString stringWithUTF8String:mangled],
                        @"demangled": demangledName,
                        @"image": image ?: @""
                    }];
                }
            }
            cachedSymbols = allSymbols.copy;
            cachedImageCount = imageCount;
        }
        symbolsSnapshot = cachedSymbols;
    }
    return symbolsSnapshot;
}

/// 以单一类型名为便捷入口复用多名称筛选；空输入直接返回空数组以避免无意义全表遍历。
+ (NSArray<NSDictionary<NSString *,id> *> *)symbolsContainingType:(NSString *)typeName {
    if (typeName.length == 0) { return @[]; }
    return [self symbolsContainingAnyTypeIn:@[typeName]];
}

/// 在已缓存的 demangle 结果中筛选任一类型子串；过滤发生在 ObjC 层，避免向 Swift 桥接大 App 全量符号。
+ (NSArray<NSDictionary<NSString *,id> *> *)symbolsContainingAnyTypeIn:(NSArray<NSString *> *)typeNames {
    if (typeNames.count == 0) { return @[]; }
    NSMutableArray<NSDictionary<NSString *, id> *> *result = NSMutableArray.array;
    for (NSDictionary<NSString *, id> *symbol in [self allSwiftSymbols]) {
        NSString *demangledName = symbol[@"demangled"];
        for (NSString *typeName in typeNames) {
            if (typeName.length > 0 && [demangledName rangeOfString:typeName].location != NSNotFound) {
                [result addObject:symbol];
                break;
            }
        }
    }
    return result;
}

/// 扫描所有镜像的 `__swift5_fieldmd`，把每个字段描述符转成 字段名 → 所有权 的字典。
/// 缓存按已加载镜像数重建；只读 Mach-O 元数据，不触碰任何实例或属性 getter。
/// 扫描每个镜像的 `__swift5_fieldmd` 字段描述符，解相对指针并提取字段名到所有权的映射；
/// 每次解引用都受 section 范围限制，防止被 strip/损坏元数据导向越界地址。
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)allSwiftFieldDescriptors {
    static NSArray<NSDictionary<NSString *, NSString *> *> *cachedDescriptors;
    static uint32_t cachedImageCount;
    uint32_t imageCount = _dyld_image_count();
    @synchronized (self) {
        if (cachedDescriptors == nil || cachedImageCount != imageCount) {
            NSMutableArray<NSDictionary<NSString *, NSString *> *> *all = NSMutableArray.array;
            for (uint32_t imageIndex = 0; imageIndex < imageCount; imageIndex++) {
                const struct mach_header_64 *header =
                    (const struct mach_header_64 *)_dyld_get_image_header(imageIndex);
                if (header == NULL || header->magic != MH_MAGIC_64) { continue; }
                intptr_t slide = _dyld_get_image_vmaddr_slide(imageIndex);

                SESectionRange ranges[256];
                size_t rangeCount = 0;
                SEFieldSection fieldSections[8];
                size_t fieldSectionCount = 0;
                const uint8_t *commandAddress = (const uint8_t *)(header + 1);
                for (uint32_t commandIndex = 0; commandIndex < header->ncmds; commandIndex++) {
                    const struct load_command *command = (const struct load_command *)commandAddress;
                    if (command->cmd == LC_SEGMENT_64) {
                        const struct segment_command_64 *segment =
                            (const struct segment_command_64 *)command;
                        const struct section_64 *sections =
                            (const struct section_64 *)(segment + 1);
                        for (uint32_t sectionIndex = 0; sectionIndex < segment->nsects;
                             sectionIndex++) {
                            const struct section_64 *section = sections + sectionIndex;
                            uintptr_t start = (uintptr_t)slide + section->addr;
                            if (rangeCount < 256 && section->size > 0) {
                                ranges[rangeCount++] =
                                    (SESectionRange){ start, start + section->size };
                            }
                            if (fieldSectionCount < 8 &&
                                strncmp(section->sectname, "__swift5_fieldmd", 16) == 0) {
                                fieldSections[fieldSectionCount++] =
                                    (SEFieldSection){ start, section->size };
                            }
                        }
                    }
                    commandAddress += command->cmdsize;
                }

                for (size_t sectionIndex = 0; sectionIndex < fieldSectionCount; sectionIndex++) {
                    const uint8_t *base = (const uint8_t *)fieldSections[sectionIndex].address;
                    uint64_t size = fieldSections[sectionIndex].size;
                    uint64_t offset = 0;
                    while (offset + 16 <= size) {
                        // FieldDescriptor: MangledTypeName(4) Superclass(4) Kind(2)
                        // FieldRecordSize(2) NumFields(4)，随后是 NumFields 条 FieldRecord。
                        uint16_t recordSize = 0;
                        uint32_t numFields = 0;
                        memcpy(&recordSize, base + offset + 10, sizeof(recordSize));
                        memcpy(&numFields, base + offset + 12, sizeof(numFields));
                        // recordSize / 字段数是 ABI 完整性校验；NumFields==0 是合法的空类型描述符，
                        // 必须跳过并继续，否则会漏掉它后面所有类型。
                        if (recordSize < 12 || numFields > 4096) { break; }
                        uint64_t recordBytes = (uint64_t)numFields * recordSize;
                        if (offset + 16 + recordBytes > size) { break; }

                        NSMutableDictionary<NSString *, NSString *> *fields =
                            [NSMutableDictionary dictionaryWithCapacity:numFields];
                        for (uint32_t fieldIndex = 0; fieldIndex < numFields; fieldIndex++) {
                            const uint8_t *record =
                                base + offset + 16 + (uint64_t)fieldIndex * recordSize;
                            int32_t typeDelta = 0;
                            int32_t nameDelta = 0;
                            memcpy(&typeDelta, record + 4, sizeof(typeDelta));
                            memcpy(&nameDelta, record + 8, sizeof(nameDelta));
                            // 相对指针以「存放该 int32 的地址」为基准。
                            uintptr_t typeTarget = (uintptr_t)(record + 4) + (intptr_t)typeDelta;
                            uintptr_t nameTarget = (uintptr_t)(record + 8) + (intptr_t)nameDelta;
                            size_t typeLimit = SESectionByteLimit(typeTarget, ranges, rangeCount);
                            size_t nameLimit = SESectionByteLimit(nameTarget, ranges, rangeCount);
                            if (typeLimit == 0 || nameLimit == 0) { continue; }
                            NSString *name = SEBoundedCString((const uint8_t *)nameTarget, nameLimit);
                            if (name.length == 0) { continue; }
                            fields[name] = SEOwnershipFromFieldType(
                                (const uint8_t *)typeTarget, typeLimit);
                        }
                        if (fields.count > 0) { [all addObject:fields.copy]; }
                        // 16 字节 header + NumFields × FieldRecordSize，按 4 字节对齐推进。
                        uint64_t descriptorSize = 16 + recordBytes;
                        offset += (descriptorSize + 3) & ~3ULL;
                    }
                }
            }
            cachedDescriptors = all.copy;
            cachedImageCount = imageCount;
        }
        return cachedDescriptors;
    }
}

/// 将给定 ivar 名列表与字段描述符集合交叉匹配：优先整组完全命中，再要求候选所有权一致，
/// 防止不同类同名属性互相污染；无法确认的项以空串返回而不是猜测 strong。
+ (NSArray<NSString *> *)fieldOwnershipForIvarNames:(NSArray<NSString *> *)names {
    if (names.count == 0) { return @[]; }
    NSArray<NSDictionary<NSString *, NSString *> *> *descriptors = [self allSwiftFieldDescriptors];
    // 一个类的 ivar 名集合应与它的 FieldDescriptor 字段名集合相同；优先用「全部命中」的描述符，
    // 再要求所有候选对该名字给出一致的所有权，避免同名属性跨类串味。
    NSMutableArray<NSMutableSet<NSString *> *> *exact = NSMutableArray.array;
    NSMutableArray<NSMutableSet<NSString *> *> *loose = NSMutableArray.array;
    for (NSUInteger index = 0; index < names.count; index++) {
        [exact addObject:NSMutableSet.set];
        [loose addObject:NSMutableSet.set];
    }
    for (NSDictionary<NSString *, NSString *> *descriptor in descriptors) {
        BOOL allPresent = YES;
        for (NSString *name in names) {
            if (descriptor[name] == nil) { allPresent = NO; break; }
        }
        for (NSUInteger index = 0; index < names.count; index++) {
            NSString *ownership = descriptor[names[index]];
            if (ownership == nil) { continue; }
            [loose[index] addObject:ownership];
            if (allPresent) { [exact[index] addObject:ownership]; }
        }
    }
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:names.count];
    for (NSUInteger index = 0; index < names.count; index++) {
        // 名字集合能对上时用精确投票；否则退化为全局同名一致投票，仍要求唯一才采信。
        NSMutableSet<NSString *> *values = exact[index].count > 0 ? exact[index] : loose[index];
        [result addObject:values.count == 1 ? values.anyObject : @""];
    }
    return result.copy;
}

/// 调用 arm64 汇编桩，把 Swift 调用约定的通用/浮点参数寄存器和 self 上下文写入，再收集返回寄存器。
/// 仅桥接已经由 Swift 层验证过的函数地址与布局；非 arm64 返回结构化架构不支持错误。
+ (NSDictionary<NSString *,NSArray<NSNumber *> *> * _Nullable)
    invokeAddress:(uintptr_t)address
          context:(uintptr_t)context
     generalWords:(NSArray<NSNumber *> *)generalWords
    floatingWords:(NSArray<NSNumber *> *)floatingWords
             error:(NSError **)error {
#if defined(__arm64__)
    if (address == 0 || generalWords.count > 8 || floatingWords.count > 8) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"SwiftEval.MachO" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Swift ABI 地址或参数寄存器数量无效"}];
        }
        return nil;
    }
    uint64_t gp[8] = {0};
    uint64_t fp[8] = {0};
    uint64_t outputGP[3] = {0};
    uint64_t outputFP[4] = {0};
    for (NSUInteger index = 0; index < generalWords.count; index++) {
        gp[index] = generalWords[index].unsignedLongLongValue;
    }
    for (NSUInteger index = 0; index < floatingWords.count; index++) {
        fp[index] = floatingWords[index].unsignedLongLongValue;
    }
    SEInvokeSwiftArm64((void *)address, (void *)context, gp, fp, outputGP, outputFP);
    return @{
        @"general": @[@(outputGP[0]), @(outputGP[1]), @(outputGP[2])],
        @"floating": @[@(outputFP[0]), @(outputFP[1]), @(outputFP[2]), @(outputFP[3])]
    };
#else
    if (error != NULL) {
        *error = [NSError errorWithDomain:@"SwiftEval.MachO" code:2
                                 userInfo:@{NSLocalizedDescriptionKey: @"Mach-O Swift 动态调用当前只支持 arm64 真机"}];
    }
    return nil;
#endif
}

/// 报告当前编译目标是否存在匹配的汇编调用桩，供 Swift 层在发起动态调用前做硬性短路。
+ (BOOL)supportsCurrentArchitecture {
#if defined(__arm64__)
    return YES;
#else
    return NO;
#endif
}

/// 以 mach_vm_read 安全读取候选地址的 isa 指针，并验证该 isa 出现在 runtime 类表中；
/// 返回类名而不 retain 对象，调用方必须自行保证对象生命周期。
+ (NSDictionary<NSString *,id> * _Nullable)
    objectInfoAtAddress:(uintptr_t)address
                  error:(NSError **)error {
    if (address < 0x1000 || (address & (sizeof(void *) - 1)) != 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"SwiftEval.Address" code:20
                                     userInfo:@{NSLocalizedDescriptionKey: @"对象地址为空、过小或未按指针宽度对齐"}];
        }
        return nil;
    }

    uintptr_t isaWord = 0;
    vm_size_t readSize = 0;
    kern_return_t result = vm_read_overwrite(
        mach_task_self(), (vm_address_t)address, (vm_size_t)sizeof(isaWord),
        (vm_address_t)&isaWord, &readSize);
    if (result != KERN_SUCCESS || readSize != sizeof(isaWord)) {
        if (error != NULL) {
            NSString *message = [NSString stringWithFormat:@"地址 0x%llx 当前不可读",
                                 (unsigned long long)address];
            *error = [NSError errorWithDomain:@"SwiftEval.Address" code:21
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
        }
        return nil;
    }

    uintptr_t decodedISA = isaWord;
    uintptr_t *maskAddress = (uintptr_t *)dlsym(RTLD_DEFAULT, "objc_debug_isa_class_mask");
    if (maskAddress != NULL && *maskAddress != 0) {
        // 用 runtime 的 isa 掩码剥离 isa 上的标记位（non-pointer isa），得到真实 class 地址。
        decodedISA = isaWord & *maskAddress;
    }

    // 取出 runtime 全部已注册类，逐一比对 isa 是否指向已知类。
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    Class matchedClass = Nil;
    for (unsigned int index = 0; index < classCount; index++) {
        uintptr_t classAddress = (uintptr_t)classes[index];
        if (classAddress == isaWord || classAddress == decodedISA) {
            matchedClass = classes[index];
            break;
        }
    }
    free(classes);
    if (matchedClass == Nil) {
        if (error != NULL) {
            NSString *message = [NSString stringWithFormat:
                                 @"地址 0x%llx 可读，但 isa 不是当前运行时中的已知类",
                                 (unsigned long long)address];
            *error = [NSError errorWithDomain:@"SwiftEval.Address" code:22
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
        }
        return nil;
    }
    const char *className = class_getName(matchedClass);
    return @{
        @"address": @(address),
        @"classAddress": @((uintptr_t)matchedClass),
        @"className": className == NULL ? @"" : [NSString stringWithUTF8String:className]
    };
}

/// 读取对象及父类直接声明的 ObjC property/ivar 信息。getter 只在安全条件下通过 NSInvocation 执行，
/// 单属性的 NSException 被捕获并记录，不会中断整棵对象展示。
+ (NSDictionary<NSString *,id> *)objectiveCInfoForObject:(id)object
                                            maxProperties:(NSUInteger)maxProperties {
    if (object == nil) { return @{}; }
    if (![NSThread isMainThread] && [self requiresMainThreadForObject:object]) {
        __block NSDictionary<NSString *, id> *mainThreadInfo = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            mainThreadInfo = [self objectiveCInfoForObject:object maxProperties:maxProperties];
        });
        return mainThreadInfo ?: @{};
    }
    Class runtimeClass = object_getClass(object);
    NSString *description = [NSString stringWithFormat:@"<%@: 0x%llx>",
                             NSStringFromClass(runtimeClass),
                             (unsigned long long)(uintptr_t)(__bridge void *)object];

    NSMutableArray<NSDictionary<NSString *, id> *> *properties = NSMutableArray.array;
    NSMutableSet<NSString *> *names = NSMutableSet.set;
    BOOL restrictGetterInvocation = [self requiresMainThreadForObject:object];
    Class currentClass = object_getClass(object);
    while (currentClass != Nil && properties.count < maxProperties) {
        unsigned int count = 0;
        // 枚举当前类直接声明的 property 列表（不含父类）。
        objc_property_t *list = class_copyPropertyList(currentClass, &count);
        for (unsigned int index = 0; index < count && properties.count < maxProperties; index++) {
            objc_property_t property = list[index];
            const char *rawName = property_getName(property);
            if (rawName == NULL) { continue; }
            NSString *name = [NSString stringWithUTF8String:rawName];
            if (name.length == 0 || [names containsObject:name]) { continue; }
            [names addObject:name];

            // 读取 @property 的 T(类型)/G(getter)/V(ivar) 特性，用于判断能否直接读 backing ivar。
            char *rawType = property_copyAttributeValue(property, "T");
            char *rawGetter = property_copyAttributeValue(property, "G");
            char *rawIvar = property_copyAttributeValue(property, "V");
            NSString *encoding = rawType == NULL ? @"?" : [NSString stringWithUTF8String:rawType];
            SEL getter = sel_registerName(rawGetter == NULL ? rawName : rawGetter);
            Ivar backingIvar = rawIvar == NULL ? NULL : class_getInstanceVariable(currentClass, rawIvar);
            free(rawType);
            free(rawGetter);
            free(rawIvar);

            NSMutableDictionary<NSString *, id> *info = [@{
                @"name": name,
                @"owner": NSStringFromClass(currentClass),
                @"type": encoding ?: @"?"
            } mutableCopy];
            @try {
                if (backingIvar != NULL) {
                    // 有 backing ivar 时直接按内存读取，不触发 getter，避免副作用与异常。
                    info[@"value"] = SEBoxIvarValue(object, backingIvar);
                    info[@"source"] = @"ivar";
                    [properties addObject:info];
                    continue;
                }
                NSMethodSignature *signature = [object methodSignatureForSelector:getter];
                if (!restrictGetterInvocation || !SECanInvokeUIPropertyGetter(name, getter)) {
                    // 非 UI 对象或白名单外的属性：不读 getter，只留元数据避免副作用。
                    info[@"valueUnavailable"] = @"无 backing ivar；为避免 getter 副作用，未自动读取";
                } else if (signature == nil || signature.numberOfArguments != 2 ||
                           ![object respondsToSelector:getter]) {
                    info[@"error"] = @"getter 不可调用";
                } else {
                    // 安全条件下通过 NSInvocation 调用 getter 并装箱返回值。
                    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
                    invocation.target = object;
                    invocation.selector = getter;
                    [invocation invoke];
                    info[@"value"] = SEBoxInvocationReturn(invocation, signature);
                    info[@"source"] = @"getter";
                }
            } @catch (NSException *exception) {
                info[@"error"] = exception.reason ?: exception.name;
            }
            [properties addObject:info];
        }
        free(list);
        currentClass = class_getSuperclass(currentClass);
    }
    uintptr_t address = (uintptr_t)(__bridge void *)object;
    return @{
        @"className": NSStringFromClass(object_getClass(object)),
        @"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)address],
        @"description": description,
        @"properties": properties
    };
}

/// 判断 UIKit/QuartzCore 对象是否必须回主线程反射，避免后台访问 UI runtime 产生线程违规。
+ (BOOL)requiresMainThreadForObject:(id)object {
    if (object == nil) { return NO; }
    // App 自定义 UIView / UIViewController 子类不在 UIKitCore 镜像内，需按继承关系判断。
    NSArray<NSString *> *mainThreadBaseClasses = @[
        @"UIResponder", @"UIGestureRecognizer", @"NSLayoutConstraint", @"CALayer"
    ];
    Class objectClass = object_getClass(object);
    for (NSString *name in mainThreadBaseClasses) {
        Class baseClass = NSClassFromString(name);
        for (Class currentClass = objectClass; baseClass != Nil && currentClass != Nil;
             currentClass = class_getSuperclass(currentClass)) {
            if (currentClass == baseClass) { return YES; }
        }
    }
    const char *imageName = objectClass == Nil ? NULL : class_getImageName(objectClass);
    if (imageName == NULL) { return NO; }
    return strstr(imageName, "/UIKit.framework/") != NULL ||
        strstr(imageName, "/UIKitCore.framework/") != NULL ||
        strstr(imageName, "/QuartzCore.framework/") != NULL;
}

/// 使用 selector 定位 ObjC 方法并以 NSInvocation 写入对象/NSNumber 参数。返回 `isVoid` 与装箱 value，
/// 令 Swift 层可区分 void、nil 和标量；不支持的结构体/指针参数会在编码校验阶段返回 NSError。
+ (NSDictionary<NSString *,id> * _Nullable)
    invokeObjectiveCTarget:(id)target
              selectorName:(NSString *)selectorName
                 arguments:(NSArray *)arguments
                     error:(NSError **)error {
    SEL selector = NSSelectorFromString(selectorName);
    // 用 selector 取方法签名；参数数需与实参数+2（self/_cmd）匹配。
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments != arguments.count + 2) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"SwiftEval.ObjC" code:10
                                     userInfo:@{NSLocalizedDescriptionKey: @"ObjC 方法签名不存在或参数数量不匹配"}];
        }
        return nil;
    }
    // 按签名创建 NSInvocation 并填入 target/selector，retainArguments 保证调用期间参数存活。
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    [invocation retainArguments];
    for (NSUInteger index = 0; index < arguments.count; index++) {
        id value = arguments[index];
        const char *type = [signature getArgumentTypeAtIndex:index + 2];
        while (strchr("rnNoORV", type[0]) != NULL) { type++; }
        if (type[0] == '@' || type[0] == '#') {
            id object = value == NSNull.null ? nil : value;
            [invocation setArgument:&object atIndex:index + 2];
            continue;
        }
        if (![value isKindOfClass:NSNumber.class]) {
            if (error != NULL) {
                NSString *message = [NSString stringWithFormat:@"第 %lu 个 ObjC 参数需要 NSNumber 标量", (unsigned long)index];
                *error = [NSError errorWithDomain:@"SwiftEval.ObjC" code:11
                                         userInfo:@{NSLocalizedDescriptionKey: message}];
            }
            return nil;
        }
        NSNumber *number = value;
#define SE_SET_SCALAR(TYPE, GETTER) do { TYPE scalar = number.GETTER; [invocation setArgument:&scalar atIndex:index + 2]; } while (0)
        switch (type[0]) {
        case 'B': SE_SET_SCALAR(BOOL, boolValue); break;
        case 'c': SE_SET_SCALAR(char, charValue); break;
        case 'C': SE_SET_SCALAR(unsigned char, unsignedCharValue); break;
        case 's': SE_SET_SCALAR(short, shortValue); break;
        case 'S': SE_SET_SCALAR(unsigned short, unsignedShortValue); break;
        case 'i': SE_SET_SCALAR(int, intValue); break;
        case 'I': SE_SET_SCALAR(unsigned int, unsignedIntValue); break;
        case 'l': SE_SET_SCALAR(long, longValue); break;
        case 'L': SE_SET_SCALAR(unsigned long, unsignedLongValue); break;
        case 'q': SE_SET_SCALAR(long long, longLongValue); break;
        case 'Q': SE_SET_SCALAR(unsigned long long, unsignedLongLongValue); break;
        case 'f': SE_SET_SCALAR(float, floatValue); break;
        case 'd': SE_SET_SCALAR(double, doubleValue); break;
        default:
            if (error != NULL) {
                NSString *message = [NSString stringWithFormat:@"ObjC 参数编码 %s 暂不支持", type];
                *error = [NSError errorWithDomain:@"SwiftEval.ObjC" code:12
                                         userInfo:@{NSLocalizedDescriptionKey: message}];
            }
            return nil;
        }
#undef SE_SET_SCALAR
    }
    // 完成所有参数写入后执行调用。
    [invocation invoke];

    const char *returnType = signature.methodReturnType;
    while (strchr("rnNoORV", returnType[0]) != NULL) { returnType++; }
    if (returnType[0] == 'v') { return @{@"isVoid": @YES, @"value": NSNull.null}; }
    if (returnType[0] == '@' || returnType[0] == '#') {
        __unsafe_unretained id value = nil;
        [invocation getReturnValue:&value];
        return @{@"isVoid": @NO, @"value": value ?: NSNull.null};
    }
#define SE_RETURN_SCALAR(TYPE) do { TYPE value = 0; [invocation getReturnValue:&value]; return @{@"isVoid": @NO, @"value": @(value)}; } while (0)
    switch (returnType[0]) {
    case 'B': SE_RETURN_SCALAR(BOOL);
    case 'c': SE_RETURN_SCALAR(char);
    case 'C': SE_RETURN_SCALAR(unsigned char);
    case 's': SE_RETURN_SCALAR(short);
    case 'S': SE_RETURN_SCALAR(unsigned short);
    case 'i': SE_RETURN_SCALAR(int);
    case 'I': SE_RETURN_SCALAR(unsigned int);
    case 'l': SE_RETURN_SCALAR(long);
    case 'L': SE_RETURN_SCALAR(unsigned long);
    case 'q': SE_RETURN_SCALAR(long long);
    case 'Q': SE_RETURN_SCALAR(unsigned long long);
    case 'f': SE_RETURN_SCALAR(float);
    case 'd': SE_RETURN_SCALAR(double);
    default: break;
    }
#undef SE_RETURN_SCALAR
    if (error != NULL) {
        NSString *message = [NSString stringWithFormat:@"ObjC 返回编码 %s 暂不支持", returnType];
        *error = [NSError errorWithDomain:@"SwiftEval.ObjC" code:13
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return nil;
}

@end
