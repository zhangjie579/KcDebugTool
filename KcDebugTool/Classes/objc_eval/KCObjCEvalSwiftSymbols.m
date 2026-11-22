#import "KCObjCEvalSwiftSymbols.h"

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/runtime.h>
#import <string.h>

typedef char *(*KCSwiftDemangle)(const char *, size_t, char *, size_t *, uint32_t);
extern id KCObjCEvalResolveAddress(id value);
extern NSNumber *KCObjCEvalAddressNumber(id value);
extern void *KCObjCEvalCreateSwiftStringWords(const void *text, uint64_t words[2]);
extern void KCObjCEvalReleaseSwiftStringWords(void *box);
extern void *KCObjCEvalCopyNSStringFromSwiftStringWords(const uint64_t words[2]);

#if defined(__arm64__)
extern void KCObjCEvalSwiftCallArm64(uintptr_t function, uintptr_t context,
                                     const uint64_t gp[8], const uint64_t fp[8],
                                     uint64_t outGP[3], uint64_t outFP[4]);
#endif

@interface KCObjCEvalSwiftType ()
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uintptr_t metadata;
@end
@implementation KCObjCEvalSwiftType
- (NSString *)description { return self.name; }
@end

static void KCSwiftFail(NSString *reason) {
    @throw [NSException exceptionWithName:@"KCObjCEvalError" reason:reason userInfo:nil];
}

/// Scan loaded images once per image-count change. `n_value + slide` is the
/// live ASLR-adjusted address; a mangled-name match alone is not callable.
static NSArray<NSDictionary *> *KCSwiftSymbols(void) {
    static NSArray<NSDictionary *> *cache;
    static uint32_t cachedCount;
    @synchronized (KCObjCEvalSwiftType.class) {
        uint32_t imageCount = _dyld_image_count();
        if (cache && cachedCount == imageCount) return cache;
        KCSwiftDemangle demangle = (KCSwiftDemangle)dlsym(RTLD_DEFAULT, "swift_demangle");
        if (!demangle) return @[];
        NSMutableArray *found = [NSMutableArray array];
        for (uint32_t image = 0; image < imageCount; image++) {
            const struct mach_header *header = _dyld_get_image_header(image);
            if (!header || header->magic != MH_MAGIC_64) continue;
            const struct mach_header_64 *header64 = (const struct mach_header_64 *)header;
            const uint8_t *command = (const uint8_t *)(header64 + 1);
            const struct symtab_command *symtab = NULL;
            const struct segment_command_64 *linkedit = NULL;
            for (uint32_t j = 0; j < header64->ncmds; j++) {
                const struct load_command *load = (const struct load_command *)command;
                if (load->cmdsize < sizeof(*load)) break;
                if (load->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)load;
                if (load->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *segment = (const struct segment_command_64 *)load;
                    if (strcmp(segment->segname, SEG_LINKEDIT) == 0) linkedit = segment;
                }
                command += load->cmdsize;
            }
            if (!symtab || !linkedit) continue;
            intptr_t slide = _dyld_get_image_vmaddr_slide(image);
            uintptr_t base = (uintptr_t)(slide + linkedit->vmaddr - linkedit->fileoff);
            const struct nlist_64 *symbols = (const struct nlist_64 *)(base + symtab->symoff);
            const char *strings = (const char *)(base + symtab->stroff);
            for (uint32_t k = 0; k < symtab->nsyms; k++) {
                const struct nlist_64 n = symbols[k];
                if ((n.n_type & N_TYPE) != N_SECT || n.n_value == 0 || n.n_un.n_strx >= symtab->strsize) continue;
                const char *mangled = strings + n.n_un.n_strx;
                if (strncmp(mangled, "_$s", 3) && strncmp(mangled, "$s", 2)) continue;
                char *expanded = demangle(mangled[0] == '_' ? mangled + 1 : mangled,
                                          strlen(mangled) - (mangled[0] == '_'), NULL, NULL, 0);
                if (!expanded) continue;
                NSString *name = [NSString stringWithUTF8String:expanded];
                free(expanded);
                if (name) [found addObject:@{@"name": name, @"address": @((uint64_t)(n.n_value + slide))}];
            }
        }
        cache = [found copy]; cachedCount = imageCount;
        return cache;
    }
}

KCObjCEvalSwiftType *KCObjCEvalFindSwiftType(NSString *name) {
#if !defined(__arm64__)
    return nil;
#else
    NSString *marker = [@"type metadata accessor for " stringByAppendingString:name];
    for (NSDictionary *entry in KCSwiftSymbols()) {
        if (![entry[@"name"] isEqualToString:marker]) continue;
        uintptr_t address = [entry[@"address"] unsignedLongLongValue];
        // Swift metadata accessors take a request word and return metadata in x0.
        void *(*accessor)(uintptr_t) = (void *(*)(uintptr_t))address;
        void *metadata = accessor(0);
        if (!metadata) return nil;
        KCObjCEvalSwiftType *type = [KCObjCEvalSwiftType new];
        type.name = name; type.metadata = (uintptr_t)metadata;
        return type;
    }
    return nil;
#endif
}

static NSString *KCNormalizedType(NSString *type) {
    NSString *value = [type stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return [value hasPrefix:@"Swift."] ? [value substringFromIndex:6] : value;
}

/// Match a demangled signature to an Objective-C-style selector. The first
/// selector component does not encode Swift's first external label, so an
/// ambiguous overload is rejected rather than selecting an arbitrary symbol.
static NSDictionary *KCMatchSymbol(NSString *typeName, NSString *member, NSUInteger arity,
                                   BOOL property, BOOL typeReceiver) {
    NSMutableArray *matches = [NSMutableArray array];
    NSString *shortType = [[typeName componentsSeparatedByString:@"."] lastObject];
    NSArray *parts = [member componentsSeparatedByString:@":"];
    NSString *base = parts.firstObject;
    for (NSDictionary *entry in KCSwiftSymbols()) {
        NSString *name = entry[@"name"];
        if ([name hasPrefix:@"@objc "] || [name containsString:@"thunk"] ||
            [name containsString:@"method descriptor"] || [name containsString:@"specialization"] ||
            [name containsString:@"protocol witness"]) continue;
        BOOL staticMember = [name hasPrefix:@"static "] || [name hasPrefix:@"class "];
        if (typeReceiver != staticMember) continue;
        if (staticMember) name = [name substringFromIndex:[name hasPrefix:@"static "] ? 7 : 6];
        NSString *head = nil, *returnType = nil, *parameterText = @"";
        if (property) {
            NSRange getter = [name rangeOfString:@".getter : "];
            if (getter.location == NSNotFound) continue;
            head = [name substringToIndex:getter.location];
            returnType = [name substringFromIndex:NSMaxRange(getter)];
        } else {
            NSRange open = [name rangeOfString:@"("];
            NSRange arrow = [name rangeOfString:@") -> " options:NSBackwardsSearch];
            if (open.location == NSNotFound || arrow.location == NSNotFound || arrow.location < open.location) continue;
            head = [name substringToIndex:open.location];
            parameterText = [name substringWithRange:NSMakeRange(NSMaxRange(open), arrow.location - NSMaxRange(open))];
            returnType = [name substringFromIndex:NSMaxRange(arrow)];
        }
        NSRange dot = [head rangeOfString:@"." options:NSBackwardsSearch];
        if (dot.location == NSNotFound) continue;
        NSString *owner = [head substringToIndex:dot.location];
        NSString *method = [head substringFromIndex:dot.location + 1];
        if (!([owner isEqualToString:typeName] || [owner isEqualToString:shortType]) || ![method isEqualToString:base]) continue;
        NSMutableArray *parameterTypes = [NSMutableArray array];
        NSMutableArray *labels = [NSMutableArray array];
        if (parameterText.length) {
            for (NSString *item in [parameterText componentsSeparatedByString:@", "]) {
                NSRange colon = [item rangeOfString:@": "];
                if (colon.location == NSNotFound) {
                    [labels addObject:@"_"];
                    [parameterTypes addObject:item];
                    continue;
                }
                [labels addObject:[item substringToIndex:colon.location]];
                [parameterTypes addObject:[item substringFromIndex:NSMaxRange(colon)]];
            }
        }
        if (parameterTypes.count != arity) continue;
        BOOL labelMatch = YES;
        for (NSUInteger i = 1; i < arity; i++) {
            if (![labels[i] isEqualToString:parts[i]]) { labelMatch = NO; break; }
        }
        if (!labelMatch) continue;
        [matches addObject:@{@"address": entry[@"address"], @"return": returnType,
                             @"parameters": parameterTypes, @"signature": entry[@"name"]}];
    }
    if (matches.count > 1) KCSwiftFail([NSString stringWithFormat:@"Swift 符号重载不明确：%@", [matches valueForKey:@"signature"]]);
    return matches.firstObject;
}

static void KCAppendSwiftArgument(id value, NSString *type, uint64_t gp[8], NSUInteger *g,
                                  uint64_t fp[8], NSUInteger *f, NSMutableArray<NSValue *> *stringBoxes) {
    NSString *name = KCNormalizedType(type);
    NSNumber *address = KCObjCEvalAddressNumber(value);
    if ([name isEqualToString:@"String"]) {
        if (![value isKindOfClass:NSString.class] || *g > 6) KCSwiftFail(@"Swift String 参数需要字符串及两个空闲寄存器");
        uint64_t words[2] = {0};
        void *box = KCObjCEvalCreateSwiftStringWords((__bridge const void *)value, words);
        [stringBoxes addObject:[NSValue valueWithPointer:box]];
        gp[(*g)++] = words[0];
        gp[(*g)++] = words[1];
        return;
    }
    if ([name isEqualToString:@"Double"] || [name isEqualToString:@"Float"]) {
        if (![value isKindOfClass:NSNumber.class] || *f >= 8) KCSwiftFail(@"Swift 浮点参数无效或超出寄存器限制");
        if ([name isEqualToString:@"Double"]) { double d = [value doubleValue]; memcpy(&fp[(*f)++], &d, sizeof(d)); }
        else { float v = [value floatValue]; memcpy(&fp[(*f)++], &v, sizeof(v)); }
        return;
    }
    if (*g >= 8) KCSwiftFail(@"Swift 参数超出寄存器限制");
    if ([name isEqualToString:@"Bool"] || [name hasPrefix:@"Int"] || [name hasPrefix:@"UInt"]) {
        if (address) value = address;
        if (![value isKindOfClass:NSNumber.class]) KCSwiftFail(@"Swift 整数或 Bool 参数需要 NSNumber");
        gp[(*g)++] = [value unsignedLongLongValue]; return;
    }
    if ([name isEqualToString:@"AnyObject"] || [name isEqualToString:@"NSObject"] ||
        NSClassFromString(name) || KCObjCEvalFindSwiftType(name)) {
        value = KCObjCEvalResolveAddress(value);
        gp[(*g)++] = (uintptr_t)(__bridge void *)value; return;
    }
    KCSwiftFail([NSString stringWithFormat:@"暂不支持 Swift 参数类型 %@", type]);
}

static id KCBoxSwiftReturn(NSString *type, uint64_t gp[3], uint64_t fp[4], BOOL *isVoid) {
    NSString *name = KCNormalizedType(type);
    if ([name isEqualToString:@"Void"] || [name isEqualToString:@"()"]) { *isVoid = YES; return nil; }
    if ([name isEqualToString:@"Bool"]) return @(gp[0] != 0);
    if ([name isEqualToString:@"Int"] || [name isEqualToString:@"Int64"]) return @((int64_t)gp[0]);
    if ([name isEqualToString:@"Int8"]) return @((int8_t)gp[0]);
    if ([name isEqualToString:@"Int16"]) return @((int16_t)gp[0]);
    if ([name isEqualToString:@"Int32"]) return @((int32_t)gp[0]);
    if ([name hasPrefix:@"UInt"]) return @(gp[0]);
    if ([name isEqualToString:@"Double"]) { double d; memcpy(&d, fp, sizeof(d)); return @(d); }
    if ([name isEqualToString:@"Float"]) { float f; memcpy(&f, fp, sizeof(f)); return @(f); }
    if ([name isEqualToString:@"String"]) return (__bridge_transfer NSString *)KCObjCEvalCopyNSStringFromSwiftStringWords(gp);
    if ([name isEqualToString:@"AnyObject"] || [name isEqualToString:@"NSObject"] ||
        NSClassFromString(name) || KCObjCEvalFindSwiftType(name)) {
        // Native Swift returns class references at +1. Transfer that ownership
        // to ARC so the result remains alive through further chained calls.
        return (__bridge_transfer id)(void *)(uintptr_t)gp[0];
    }
    KCSwiftFail([NSString stringWithFormat:@"暂不支持 Swift 返回类型 %@", type]);
    return nil;
}

BOOL KCObjCEvalInvokeSwift(id receiver, NSString *member, NSArray *arguments, BOOL property,
                           id *output, BOOL *isVoid) {
#if !defined(__arm64__)
    return NO;
#else
    BOOL typeReceiver = [receiver isKindOfClass:KCObjCEvalSwiftType.class] || object_isClass(receiver);
    NSString *typeName = [receiver isKindOfClass:KCObjCEvalSwiftType.class] ?
                         ((KCObjCEvalSwiftType *)receiver).name :
                         [NSString stringWithUTF8String:class_getName(typeReceiver ? receiver : object_getClass(receiver))];
    NSDictionary *match = KCMatchSymbol(typeName, member, arguments.count, property, typeReceiver);
    if (!match) return NO;
    // Validate every argument and return type before entering native Swift
    // code. Unsupported value layouts must never be guessed from register bits.
    NSString *returnType = KCNormalizedType(match[@"return"]);
    BOOL supportedReturn = [@[@"Void", @"()", @"Bool", @"Int", @"Int8", @"Int16", @"Int32", @"Int64",
                              @"UInt", @"UInt8", @"UInt16", @"UInt32", @"UInt64", @"Float", @"Double",
                              @"AnyObject", @"NSObject", @"String"] containsObject:returnType] ||
                           NSClassFromString(returnType) || KCObjCEvalFindSwiftType(returnType);
    if (!supportedReturn) KCSwiftFail([NSString stringWithFormat:@"暂不支持 Swift 返回类型 %@", returnType]);
    uint64_t gp[8] = {0}, fp[8] = {0}, outGP[3] = {0}, outFP[4] = {0};
    NSUInteger g = 0, f = 0;
    NSArray *types = match[@"parameters"];
    NSMutableArray<NSValue *> *stringBoxes = [NSMutableArray array];
    @try {
        for (NSUInteger i = 0; i < arguments.count; i++)
            KCAppendSwiftArgument(arguments[i], types[i], gp, &g, fp, &f, stringBoxes);
    } @catch (NSException *exception) {
        for (NSValue *box in stringBoxes) KCObjCEvalReleaseSwiftStringWords(box.pointerValue);
        @throw;
    }
    uintptr_t context = [receiver isKindOfClass:KCObjCEvalSwiftType.class] ?
                        ((KCObjCEvalSwiftType *)receiver).metadata : (uintptr_t)(__bridge void *)receiver;
    KCObjCEvalSwiftCallArm64([match[@"address"] unsignedLongLongValue], context, gp, fp, outGP, outFP);
    for (NSValue *box in stringBoxes) KCObjCEvalReleaseSwiftStringWords(box.pointerValue);
    if (isVoid) *isVoid = NO;
    id result = KCBoxSwiftReturn(match[@"return"], outGP, outFP, isVoid);
    if (output) *output = result;
    return YES;
#endif
}
