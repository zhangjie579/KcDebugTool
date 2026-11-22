#import "KCObjCEval.h"
#import "KCObjCEvalSwiftSymbols.h"

#import <mach/mach.h>
#import <objc/runtime.h>
#import <TargetConditionals.h>
#import <string.h>

static NSString *const KCEvalErrorDomain = @"KCObjCEval";

/// An address literal is kept distinct from an integer until the destination
/// type is known. `0x2a` can therefore be an integer parameter or a receiver.
@interface KCAddress : NSObject
@property (nonatomic) uintptr_t bits;
@end
@implementation KCAddress
- (NSString *)description { return [NSString stringWithFormat:@"0x%llx", (unsigned long long)self.bits]; }
@end

@interface KCObjCEvalResult ()
@property (nonatomic) BOOL success;
@property (nonatomic) BOOL hasReturnValue;
@property (nonatomic, strong, nullable) id value;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@end

@implementation KCObjCEvalResult
- (NSString *)displayText {
    if (!self.success) return self.errorMessage ?: @"求值失败";
    if (!self.hasReturnValue) return @"<void>";
    return self.value ? [self.value description] : @"nil";
}
@end

/// Parser errors are caught only at the public API boundary. Method exceptions
/// are converted there too, so an invalid expression never escapes as an exception.
static void KCFail(NSString *message) {
    @throw [NSException exceptionWithName:@"KCObjCEvalError" reason:message userInfo:nil];
}

static const char *KCType(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

/// Reject unmapped/stale pointers before sending an Objective-C message. The
/// check recognizes realized classes, including dynamic KVO subclasses. It is
/// still a best-effort snapshot: the caller must keep the object alive.
static id KCObjectAtAddress(uintptr_t address) {
    if (address < 0x1000 || (address & (sizeof(void *) - 1))) KCFail(@"对象地址无效或未对齐");
    uintptr_t isa = 0;
    vm_size_t readSize = 0;
    kern_return_t result = vm_read_overwrite(mach_task_self(), (vm_address_t)address,
                                              sizeof(isa), (vm_address_t)&isa, &readSize);
    if (result != KERN_SUCCESS || readSize != sizeof(isa)) KCFail(@"对象地址不可读");
    // arm64 nonpointer isa stores flags in the high bits. The low class bits
    // are stable on supported arm64 Apple platforms; raw isa works unchanged.
#if defined(__arm64__) && TARGET_OS_OSX
    isa &= 0x00007ffffffffff8ULL;
#elif defined(__arm64__)
    isa &= 0x0000000ffffffff8ULL;
#endif
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) KCFail(@"无法读取 Objective-C 类表");
    Class __unsafe_unretained *classes = (Class __unsafe_unretained *)calloc((size_t)count, sizeof(Class));
    if (!classes) KCFail(@"内存不足");
    count = objc_getClassList(classes, count);
    BOOL found = NO;
    for (int i = 0; i < count; i++) {
        if ((uintptr_t)classes[i] == isa) { found = YES; break; }
    }
    free(classes);
    if (!found) KCFail(@"地址不是已注册的 Objective-C 对象（Swift 值类型也不支持地址调用）");
    return (__bridge id)(void *)address;
}

static id KCResolvedObject(id value) {
    if ([value isKindOfClass:KCAddress.class]) return KCObjectAtAddress(((KCAddress *)value).bits);
    if ([value isKindOfClass:NSString.class] && [value hasPrefix:@"0x"]) {
        const char *s = [value UTF8String];
        char *end = NULL;
        unsigned long long bits = strtoull(s, &end, 16);
        if (end && *end == '\0' && end != s + 2) return KCObjectAtAddress((uintptr_t)bits);
    }
    return value == NSNull.null ? nil : value;
}

// The Swift symbol adapter uses the same checked address conversion as the
// Objective-C invocation path, so both paths reject invalid object pointers.
id KCObjCEvalResolveAddress(id value) { return KCResolvedObject(value); }
NSNumber *KCObjCEvalAddressNumber(id value) {
    return [value isKindOfClass:KCAddress.class] ? @(((KCAddress *)value).bits) : nil;
}

/// Writes a single argument using its actual Objective-C type encoding.
/// Object addresses are resolved only for object/Class parameters; numeric
/// parameters retain their numeric interpretation.
static void KCSetArgument(NSInvocation *inv, NSMethodSignature *sig, NSUInteger index, id value) {
    const char *type = KCType([sig getArgumentTypeAtIndex:index]);
    if (!type || !*type) KCFail(@"参数类型未知");
    if (*type == '@' || *type == '#') {
        id object = KCResolvedObject(value);
        if (*type == '#' && object && !object_isClass(object)) KCFail(@"参数需要 Class");
        [inv setArgument:&object atIndex:index];
        return;
    }
    if ([value isKindOfClass:KCAddress.class]) value = @(((KCAddress *)value).bits);
    if (*type == ':') {
        SEL selector = value == NSNull.null ? NULL : NSSelectorFromString([value description]);
        [inv setArgument:&selector atIndex:index];
        return;
    }
    if (*type == '^' || *type == '*') {
        void *pointer = (void *)(uintptr_t)[value unsignedLongLongValue];
        [inv setArgument:&pointer atIndex:index];
        return;
    }
    if (*type == '{' && [value isKindOfClass:NSValue.class] &&
        strcmp([(NSValue *)value objCType], type) == 0) {
        NSUInteger size = 0;
        NSGetSizeAndAlignment(type, &size, NULL);
        void *bytes = calloc(1, size);
        if (!bytes) KCFail(@"内存不足");
        [(NSValue *)value getValue:bytes];
        [inv setArgument:bytes atIndex:index];
        free(bytes);
        return;
    }
    if (![value isKindOfClass:NSNumber.class])
        KCFail([NSString stringWithFormat:@"第 %lu 个参数需要数值或 NSValue", (unsigned long)(index - 1)]);
#define KC_ARG(T, EXPR) do { T n = (T)(EXPR); [inv setArgument:&n atIndex:index]; return; } while (0)
    switch (*type) {
        case 'B': KC_ARG(BOOL, [value boolValue]);
        case 'c': KC_ARG(char, [value charValue]);
        case 'C': KC_ARG(unsigned char, [value unsignedCharValue]);
        case 's': KC_ARG(short, [value shortValue]);
        case 'S': KC_ARG(unsigned short, [value unsignedShortValue]);
        case 'i': KC_ARG(int, [value intValue]);
        case 'I': KC_ARG(unsigned int, [value unsignedIntValue]);
        case 'l': KC_ARG(long, [value longValue]);
        case 'L': KC_ARG(unsigned long, [value unsignedLongValue]);
        case 'q': KC_ARG(long long, [value longLongValue]);
        case 'Q': KC_ARG(unsigned long long, [value unsignedLongLongValue]);
        case 'f': KC_ARG(float, [value floatValue]);
        case 'd': KC_ARG(double, [value doubleValue]);
        default: KCFail([NSString stringWithFormat:@"暂不支持参数类型 %s", type]);
    }
#undef KC_ARG
}

/// NSInvocation follows the method's ABI, so scalar getters and method
/// returns are boxed without pretending that they are Objective-C objects.
static id KCBoxReturn(NSInvocation *inv, NSMethodSignature *sig) {
    const char *type = KCType(sig.methodReturnType);
    if (*type == 'v') return nil;
    if (*type == '@' || *type == '#') {
        __unsafe_unretained id object = nil;
        [inv getReturnValue:&object];
        return object;
    }
#define KC_RET(T) do { T n = 0; [inv getReturnValue:&n]; return @(n); } while (0)
    switch (*type) {
        case 'B': KC_RET(BOOL);
        case 'c': KC_RET(char);
        case 'C': KC_RET(unsigned char);
        case 's': KC_RET(short);
        case 'S': KC_RET(unsigned short);
        case 'i': KC_RET(int);
        case 'I': KC_RET(unsigned int);
        case 'l': KC_RET(long);
        case 'L': KC_RET(unsigned long);
        case 'q': KC_RET(long long);
        case 'Q': KC_RET(unsigned long long);
        case 'f': KC_RET(float);
        case 'd': KC_RET(double);
        case ':': { SEL sel = NULL; [inv getReturnValue:&sel]; return sel ? NSStringFromSelector(sel) : nil; }
        case '^': case '*': { void *ptr = NULL; [inv getReturnValue:&ptr]; return [NSValue valueWithPointer:ptr]; }
        default: break;
    }
#undef KC_RET
    if (*type == '{' || *type == '[') {
        NSUInteger size = sig.methodReturnLength;
        void *bytes = calloc(1, size);
        if (!bytes) KCFail(@"内存不足");
        [inv getReturnValue:bytes];
        id result = [NSValue valueWithBytes:bytes objCType:type];
        free(bytes);
        return result;
    }
    KCFail([NSString stringWithFormat:@"暂不支持返回类型 %s", type]);
    return nil;
}

static id KCInvoke(id receiver, NSString *selectorName, NSArray *arguments, BOOL property, BOOL *isVoid) {
    receiver = KCResolvedObject(receiver);
    if (!receiver) KCFail(@"无法向 nil 发送消息");
    SEL selector = NSSelectorFromString(selectorName);
    if (![receiver respondsToSelector:selector]) {
        id swiftOutput = nil;
        if (KCObjCEvalInvokeSwift(receiver, selectorName, arguments, property, &swiftOutput, isVoid)) return swiftOutput;
        KCFail([NSString stringWithFormat:@"%@ 不响应 %@", receiver, selectorName]);
    }
    NSMethodSignature *signature = [receiver methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != arguments.count + 2)
        KCFail([NSString stringWithFormat:@"%@ 参数数量不匹配", selectorName]);
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:signature];
    inv.target = receiver;
    inv.selector = selector;
    for (NSUInteger i = 0; i < arguments.count; i++)
        KCSetArgument(inv, signature, i + 2, arguments[i]);
    [inv retainArguments];
    [inv invoke];
    *isVoid = *KCType(signature.methodReturnType) == 'v';
    return KCBoxReturn(inv, signature);
}

@interface KCObjCEvalParser : NSObject
@property (nonatomic, copy) NSString *source;
@property (nonatomic, copy) NSDictionary<NSString *, id> *variables;
@property (nonatomic) NSUInteger offset;
@property (nonatomic) BOOL lastWasVoid;
@property (nonatomic) BOOL inArgument;
- (id)parse;
@end

@implementation KCObjCEvalParser

- (unichar)peek { return self.offset < self.source.length ? [self.source characterAtIndex:self.offset] : 0; }
- (void)space {
    while ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[self peek]]) self.offset++;
}
- (BOOL)take:(unichar)c { [self space]; if ([self peek] != c) return NO; self.offset++; return YES; }
- (void)expect:(unichar)c {
    if (![self take:c]) KCFail([NSString stringWithFormat:@"位置 %lu 需要 '%C'", (unsigned long)self.offset, c]);
}
- (NSString *)identifier {
    [self space]; NSUInteger start = self.offset;
    NSCharacterSet *first = [NSCharacterSet characterSetWithCharactersInString:@"_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ$"];
    NSCharacterSet *rest = [NSCharacterSet characterSetWithCharactersInString:@"_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ$0123456789"];
    if (![first characterIsMember:[self peek]]) KCFail([NSString stringWithFormat:@"位置 %lu 需要标识符", (unsigned long)self.offset]);
    self.offset++;
    while ([rest characterIsMember:[self peek]]) self.offset++;
    return [self.source substringWithRange:NSMakeRange(start, self.offset - start)];
}
- (NSString *)quotedString {
    [self space]; NSUInteger start = self.offset;
    [self expect:'"'];
    BOOL escaped = NO;
    while ([self peek]) {
        unichar c = [self peek]; self.offset++;
        if (c == '"' && !escaped) {
            NSString *json = [self.source substringWithRange:NSMakeRange(start, self.offset - start)];
            NSData *data = [[NSString stringWithFormat:@"[%@]", json] dataUsingEncoding:NSUTF8StringEncoding];
            NSArray *values = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if (!values.count) KCFail(@"字符串转义无效");
            return values.firstObject;
        }
        if (c == '\\' && !escaped) escaped = YES; else escaped = NO;
    }
    KCFail(@"字符串没有结束引号"); return nil;
}
- (id)number {
    [self space]; NSUInteger start = self.offset;
    if ([self peek] == '-') self.offset++;
    BOOL hex = [self peek] == '0' && self.offset + 1 < self.source.length &&
               ([self.source characterAtIndex:self.offset + 1] == 'x' || [self.source characterAtIndex:self.offset + 1] == 'X');
    if (hex) {
        self.offset += 2;
        NSUInteger digits = self.offset;
        NSCharacterSet *chars = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
        while ([chars characterIsMember:[self peek]]) self.offset++;
        if (digits == self.offset) KCFail(@"十六进制地址缺少数字");
        NSString *text = [self.source substringWithRange:NSMakeRange(start, self.offset - start)];
        KCAddress *address = [KCAddress new]; address.bits = (uintptr_t)strtoull(text.UTF8String, NULL, 16);
        return address;
    }
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    while ([digits characterIsMember:[self peek]]) self.offset++;
    if ([self peek] == '.') { self.offset++; while ([digits characterIsMember:[self peek]]) self.offset++; }
    NSString *text = [self.source substringWithRange:NSMakeRange(start, self.offset - start)];
    return [text containsString:@"."] ? @([text doubleValue]) : @([text longLongValue]);
}
- (id)arrayLiteral {
    [self expect:'[']; NSMutableArray *items = [NSMutableArray array];
    if ([self take:']']) return items;
    do { [items addObject:[self expression] ?: NSNull.null]; } while ([self take:',']);
    [self expect:']']; return items;
}
- (id)dictionaryLiteral {
    [self expect:'{']; NSMutableDictionary *items = [NSMutableDictionary dictionary];
    if ([self take:'}']) return items;
    do {
        id key = [self expression]; [self expect:':'];
        id value = [self expression];
        if (!key || ![key conformsToProtocol:@protocol(NSCopying)]) KCFail(@"字典 key 必须可复制");
        items[key] = value ?: NSNull.null;
    } while ([self take:',']);
    [self expect:'}']; return items;
}
/// A message is parsed recursively. Each argument is itself an expression,
/// allowing `[self make:[Factory shared]]` and arbitrary nesting.
- (id)message {
    [self expect:'['];
    BOOL parentArgument = self.inArgument;
    self.inArgument = NO;
    id receiver = [self expression];
    self.inArgument = parentArgument;
    NSString *head = [self identifier];
    NSMutableString *selector = [head mutableCopy];
    NSMutableArray *args = [NSMutableArray array];
    if ([self take:':']) {
        [selector appendString:@":"];
        self.inArgument = YES;
        [args addObject:[self expression] ?: NSNull.null];
        self.inArgument = parentArgument;
        while (YES) {
            [self space]; if ([self peek] == ']') break;
            [selector appendFormat:@"%@:", [self identifier]];
            [self expect:':'];
            self.inArgument = YES;
            [args addObject:[self expression] ?: NSNull.null];
            self.inArgument = parentArgument;
        }
    }
    [self expect:']'];
    BOOL isVoid = NO;
    id result = KCInvoke(receiver, selector, args, NO, &isVoid);
    self.lastWasVoid = isVoid;
    return result;
}
- (id)primary {
    [self space]; unichar c = [self peek];
    if (c == '[') return [self message];
    if (c == '"') return [self quotedString];
    if (c == '(') { self.offset++; id value = [self expression]; [self expect:')']; return value; }
    if (c == '@') {
        self.offset++; [self space]; c = [self peek];
        if (c == '"') return [self quotedString];
        if (c == '[') return [self arrayLiteral];
        if (c == '{') return [self dictionaryLiteral];
        if (c == '(') { self.offset++; id value = [self expression]; [self expect:')']; return value; }
        if (c == '-' || [NSCharacterSet.decimalDigitCharacterSet characterIsMember:c]) return [self number];
        NSString *word = [self identifier];
        if ([word isEqual:@"YES"]) return @YES;
        if ([word isEqual:@"NO"]) return @NO;
        KCFail([NSString stringWithFormat:@"不支持的 @ 字面量 %@", word]);
    }
    if (c == '-' || [NSCharacterSet.decimalDigitCharacterSet characterIsMember:c]) return [self number];
    NSString *name = [self identifier];
    if ([name isEqual:@"nil"] || [name isEqual:@"NULL"]) return nil;
    if ([name isEqual:@"YES"] || [name isEqual:@"true"]) return @YES;
    if ([name isEqual:@"NO"] || [name isEqual:@"false"]) return @NO;
    id variable = self.variables[name];
    if (variable) return variable == NSNull.null ? nil : variable;
    Class cls = NSClassFromString(name);
    if (cls) return cls;
    KCObjCEvalSwiftType *swiftType = KCObjCEvalFindSwiftType(name);
    if (swiftType) return swiftType;
    // Swift's runtime class name may contain a module prefix. Only consume a
    // dotted suffix if the complete name resolves to a class; otherwise the
    // caller still gets an ordinary property chain or a clear unknown name.
    NSUInteger originalOffset = self.offset;
    NSMutableString *qualified = [name mutableCopy];
    while ([self take:'.']) {
        [qualified appendFormat:@".%@", [self identifier]];
        cls = NSClassFromString(qualified);
        if (cls) return cls;
        swiftType = KCObjCEvalFindSwiftType(qualified);
        if (swiftType) return swiftType;
    }
    self.offset = originalOffset;
    // A bare word is convenient for string arguments: `[obj setName:Alice]`.
    // Receiver names remain strict, so misspelled variables/classes still fail.
    if (self.inArgument) return name;
    KCFail([NSString stringWithFormat:@"未知标识符 %@；请通过 variables 传入对象", name]);
    return nil;
}
/// A dot reads through the getter, except for the final component of an
/// assignment, which sends its setter without first evaluating the getter.
- (id)expression {
    self.lastWasVoid = NO;
    id value = [self primary];
    while ([self take:'.']) {
        NSString *property = [self identifier];
        if ([self take:'=']) {
            BOOL parentArgument = self.inArgument;
            self.inArgument = YES; // Match bare-word handling in method arguments.
            id assigned = [self expression];
            self.inArgument = parentArgument;
            NSString *setter = [NSString stringWithFormat:@"set%@%@:",
                                [[property substringToIndex:1] uppercaseString],
                                [property substringFromIndex:1]];
            BOOL isVoid = NO;
            KCInvoke(value, setter, @[assigned ?: NSNull.null], NO, &isVoid);
            self.lastWasVoid = NO;
            return assigned;
        }
        BOOL isVoid = NO;
        value = KCInvoke(value, property, @[], YES, &isVoid);
        if (isVoid) KCFail([NSString stringWithFormat:@"%@ 没有属性返回值", property]);
        self.lastWasVoid = NO;
    }
    return value;
}
- (id)parse {
    id value = [self expression]; [self space];
    while ([self take:';']) { [self space]; if (![self peek]) break; value = [self expression]; [self space]; }
    if ([self peek]) KCFail([NSString stringWithFormat:@"位置 %lu 有未解析内容", (unsigned long)self.offset]);
    return value;
}
@end

@implementation KCObjCEval
+ (KCObjCEvalResult *)evaluate:(NSString *)expression { return [self evaluate:expression variables:nil]; }
+ (KCObjCEvalResult *)evaluate:(NSString *)expression variables:(NSDictionary<NSString *,id> *)variables {
    KCObjCEvalResult *result = [KCObjCEvalResult new];
    @try {
        if (!expression.length) KCFail(@"表达式不能为空");
        KCObjCEvalParser *parser = [KCObjCEvalParser new];
        parser.source = expression; parser.variables = variables ?: @{};
        result.value = [parser parse];
        result.hasReturnValue = !parser.lastWasVoid;
        result.success = YES;
    } @catch (NSException *exception) {
        result.errorMessage = exception.reason ?: exception.name;
    }
    return result;
}

+ (BOOL)injectSelector:(SEL)selector intoClass:(Class)cls classMethod:(BOOL)classMethod
        implementation:(KCObjCEvalMethodBlock)implementation error:(NSError **)error {
    NSString *name = selector ? NSStringFromSelector(selector) : @"";
    NSUInteger count = [[name componentsSeparatedByString:@":"] count] - 1;
    if (!cls || !selector || !implementation || count > 4 ||
        (count && ![name hasSuffix:@":"])) {
        if (error) *error = [NSError errorWithDomain:KCEvalErrorDomain code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"需要有效的类、selector、实现；只支持 0 到 4 个对象参数"}];
        return NO;
    }
    Class target = classMethod ? object_getClass(cls) : cls;
    KCObjCEvalMethodBlock body = [implementation copy];
    // imp_implementationWithBlock removes _cmd from the block ABI. Each case
    // has an exact arity, avoiding a variadic IMP and undefined register use.
    IMP imp = NULL;
    switch (count) {
        case 0: { imp = imp_implementationWithBlock(^id(id receiver) { return body(receiver, @[]); }); break; }
        case 1: { imp = imp_implementationWithBlock(^id(id receiver, id a) { return body(receiver, @[a ?: NSNull.null]); }); break; }
        case 2: { imp = imp_implementationWithBlock(^id(id receiver, id a, id b) { return body(receiver, @[a ?: NSNull.null, b ?: NSNull.null]); }); break; }
        case 3: { imp = imp_implementationWithBlock(^id(id receiver, id a, id b, id c) { return body(receiver, @[a ?: NSNull.null, b ?: NSNull.null, c ?: NSNull.null]); }); break; }
        case 4: { imp = imp_implementationWithBlock(^id(id receiver, id a, id b, id c, id d) { return body(receiver, @[a ?: NSNull.null, b ?: NSNull.null, c ?: NSNull.null, d ?: NSNull.null]); }); break; }
    }
    NSMutableString *encoding = [@"@@:" mutableCopy];
    for (NSUInteger i = 0; i < count; i++) [encoding appendString:@"@"];
    // Refuse to replace an existing method: the caller can safely retry after
    // fixing a typo without silently changing production behavior.
    if (!class_addMethod(target, selector, imp, encoding.UTF8String)) {
        imp_removeBlock(imp);
        if (error) *error = [NSError errorWithDomain:KCEvalErrorDomain code:2 userInfo:@{
            NSLocalizedDescriptionKey: @"方法已存在；动态注入只添加新方法"}];
        return NO;
    }
    return YES;
}
@end
