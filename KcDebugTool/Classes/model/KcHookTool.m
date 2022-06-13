//
//  KcHookTool.m
//  test001-hook
//
//  Created by samzjzhang on 2020/7/16.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "KcHookTool.h"
#import <objc/message.h>
#import "KcAspects.h"
#import "KcHookModel.h"
//#import "THInterceptor.h"

// 引用 - KCSwiftMeta 处理swift的dump className
// canImport(MLeaksFinder) swift可以这样判断
#if __has_include("KcDebugTool/KcDebugTool-Swift.h")
#import "KcDebugTool/KcDebugTool-Swift.h"
#else
#import "KcDebugTool-Swift.h"
#endif

#pragma mark - 基于Aspcet

@interface KcHookAspcet : NSObject <KcAspectable>

@end

@implementation KcHookAspcet

- (void)kc_hookWithObjc:(id)objc
               selector:(SEL)selector
            withOptions:(KcAspectType)options
             usingBlock:(void(^)(KcHookAspectInfo *info))block
                  error:(NSError **)error {
    // 如果为swift的class, 因为kc_aspect_hookSelector是NSObject的扩展, swift class没有这个方法, 调用会crash
    // swift class 转NSObject, 成功了⚠️
    NSObject *_Nullable cocoaObjc = (NSObject *)objc;
    
//    id hookObjc = objc;
    if (!cocoaObjc
        || ![cocoaObjc respondsToSelector:@selector(kc_aspect_hookSelector:withOptions:usingBlock:error:)]) {
        // 第1种: 想通过runtime来兼容Swift的运行时, 再最后消息转发时, 方法找不到了
        // 第2种: 修改class的super class。class_setSuperclass
        // 第3种: 动态创建个class, 把isa中的runtime方法全部copy过来
        [KcLogParamModel logWithKey:@"hook失败⚠️" format:@"objc: %@, selector: %@", objc, NSStringFromSelector(selector)];
        return;
        
//        if (!object_isClass(objc)) {
//            Class superClass = class_getSuperclass([objc class]);
//            if ([NSStringFromClass(superClass) containsString:@"SwiftObject"]) {
////                class_setSuperclass(object_getClass(objc), [NSObject class]);
//
//                NSString *aspectClassName = [NSString stringWithFormat:@"%@_kcAscpet", NSStringFromClass([objc class])];
//                Class aspectClass = objc_allocateClassPair([NSObject class], aspectClassName.UTF8String, 0);
//
//                unsigned int count;
//                Method *methodList = class_copyMethodList([objc class], &count);
//                for (int i = 0; i < count; i++) {
//                    Method method = methodList[i];
//                    class_addMethod(aspectClass, method_getName(method), method_getImplementation(method), method_getTypeEncoding(method));
//                }
//                free(methodList);
//                methodList = nil;
//
//                objc_registerClassPair(aspectClass);
//
//                object_setClass(objc, aspectClass);
//            }
//        }
        
//        Class cls = object_getClass(object_getClass(objc));
//        if (object_isClass(objc)) {
//            cls = object_getClass(objc);
//        }
//
//        Method method = class_getClassMethod([NSObject class], @selector(kc_aspect_hookSelector:withOptions:usingBlock:error:));
//
//        class_addMethod(cls, @selector(kc_aspect_hookSelector:withOptions:usingBlock:error:), method_getImplementation(method),  method_getTypeEncoding(method));
//
//        if (!cocoaObjc
//            || ![[cocoaObjc class] respondsToSelector:@selector(kc_aspect_hookSelector:withOptions:usingBlock:error:)]) {
//            [KcLogParamModel logWithKey:@"hook失败⚠️" format:@"objc: %@, selector: %@", objc, NSStringFromSelector(selector)];
//            return;
//        }
//
//        // 因为内部会用class作为dict的key, 需要遵守NSCopying
//        if (![cocoaObjc conformsToProtocol:@protocol(NSCopying)]) {
//            BOOL success = class_addProtocol([cocoaObjc class], @protocol(NSCopying));
//
//            class_addMethod(object_getClass([cocoaObjc class]), @selector(copyWithZone:), default_copyWithZone, "@@:@");
//            class_addMethod(object_getClass(NSClassFromString(@"Swift._SwiftObject")), @selector(copyWithZone:), default_copyWithZone, "@@:@");
//            if (!success) {
//                return;
//            }
//        }
//
//        if (![[cocoaObjc class] respondsToSelector:@selector(instanceMethodSignatureForSelector:)]) {
//            BOOL success = class_addMethod(object_getClass([cocoaObjc class]), @selector(instanceMethodSignatureForSelector:), default_instanceMethodSignatureForSelector, "@@::");
//            if (!success) {
//                return;
//            }
//        }
//
//        hookObjc = [cocoaObjc class];
    }
    
    [objc kc_aspect_hookSelector:selector withOptions:(KcAspectOptions)options usingBlock:^(id<KcAspectInfo> info) {
        if (block) {
            KcHookAspectInfo *model = [[KcHookAspectInfo alloc] init];
            model.instance = info.instance;
            model.selectorName = NSStringFromSelector(selector);
            model.arguments = info.arguments;
            model.aspectInfo = info;
            
            block(model);
        }
    } error:error];
}

//static id default_copyWithZone(id objc, SEL sel, NSZone *zone) {
//    return objc;
//}
//
//static NSMethodSignature *default_instanceMethodSignatureForSelector(Class cls, SEL sel, SEL aSelector) {
//    Method method = class_getInstanceMethod(cls, aSelector);
//    if (!method) {
//        return nil;
//    }
//    return [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
//}

@end

#pragma mark - 基于THInterceptor

@interface KcHookInterceptor : NSObject <KcAspectable>

@end

@implementation KcHookInterceptor

/// [className : [selectorName : block]]
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, void(^)(KcHookAspectInfo *info)> *> *cacheBlocks;

- (void)kc_hookWithObjc:(id)objc
               selector:(SEL)selector
            withOptions:(KcAspectType)options
             usingBlock:(void(^)(KcHookAspectInfo *info))block
                  error:(NSError **)error {
#if !defined (__arm64__)
//    #error x86_64 & arm64e to be supported
#endif
    NSAssert(options == KcAspectTypeBefore, @"只能hook before");

    if (!cacheBlocks) {
        cacheBlocks = [[NSMutableDictionary alloc] init];
    }
    
    Class cls = object_isClass(objc) ? objc : object_getClass(objc);

    BOOL result = [self.class hookWithClass:cls selector:selector];
    if (!result) {
        return;
    }
//    NSString *className = NSStringFromClass(cls);
//    NSString *selectorName = NSStringFromSelector(selector);
//    NSMutableDictionary<NSString *, void(^)(KcHookAspectInfo *info)> *blockDict = cacheBlocks[className];
//    if (!blockDict) {
//        blockDict = [[NSMutableDictionary alloc] init];
//        cacheBlocks[className] = blockDict;
//    }
//    blockDict[selectorName] = block;
    
    // 改为关联类型👻
    objc_setAssociatedObject(cls, selector, block, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

+ (BOOL)hookWithClass:(Class)cls selector:(SEL)selector {
    Method origMethod = class_getInstanceMethod(cls, selector);
    if (!origMethod) return false;

//#if defined (__arm64__)
    
//    IMP originIMP = method_getImplementation(origMethod);
//    
//    static THInterceptor *interceptor = nil;
//    if (!interceptor) {
//        interceptor = [THInterceptor sharedInterceptorWithFunction:(IMP)kc_addHandleBeforeExecute];
//    }
//
//    if (!interceptor) return false;
//
//    THInterceptorResult *result = [interceptor interceptFunction:originIMP];
//    if (!result || result.state == THInterceptStateFailed) return false;
//
//    method_setImplementation(origMethod, result.replacedAddress);

//#endif
    
    return true;
}

void kc_addHandleBeforeExecute(id object, SEL selector, ...) {
    
    // 1.只取了2个参数
    void *v1 = nil; // 用id类型会crash, 当没参数/参数为基本类型 crash; 用va_list会crash
    void *v2 = nil;
    
    // https://juejin.im/post/5ab4cd60f265da239612536e
    // "=r" (变量标识符)，在汇编执行完毕后会将%0寄存器的值保存在变量标识符内，如果有多个变量需要赋值，可以使用%1, %2以此类推

#if defined (__arm64__)
    __asm__ __volatile__(
        "mov %0, x2\n"
        "mov %1, x3"
        : "=r" (v1), "=r" (v2)
        :
        :
    );
#endif
    
    
    
    // 2.v1、v2只关注对象
    NSMutableArray<id> *arguments = [[NSMutableArray alloc] init];
    NSMethodSignature *originSignature = [object methodSignatureForSelector:selector];
    
    if (originSignature.numberOfArguments > 2) {
        for (NSInteger i = 2; i < originSignature.numberOfArguments & i < 4; i++) {
            id argument = nil;
            const char *argType = [originSignature getArgumentTypeAtIndex:i];
            // Skip const type qualifier.
            if (argType[0] == _C_CONST) argType++;
            
            if (strcmp(argType, @encode(id)) == 0 || strcmp(argType, @encode(Class)) == 0) {
                // 只取了2个参数
                argument = i == 2 ? (__bridge id)v1 : (__bridge id)v2;
            } else if (strcmp(argType, @encode(SEL)) == 0) {
                SEL sel = i == 2 ? v1 : v2;
                if (sel) {
                    argument = NSStringFromSelector(sel);
                }
            // 3.class
            } else if (strcmp(argType, @encode(Class)) == 0) {
                argument = i == 2 ? (__bridge id)v1 : (__bridge id)v2;
            }
            if (argument) {
                [arguments addObject:argument];
            }
        }
    }
    
    // 执行block
    void(^block)(KcHookAspectInfo *info) = objc_getAssociatedObject(object, selector);
    if (!block) {
        block = objc_getAssociatedObject(object_getClass(object), selector);
    }
    if (!block) {
        return;
    }
    
//    NSString *className = NSStringFromClass(object_getClass(object));
//    NSString *selectorName = NSStringFromSelector(selector);
//    void(^block)(KcHookAspectInfo *info) = cacheBlocks[className][selectorName];
//    if (!block) {
//        return;
//    }
    
    KcHookAspectInfo *model = [[KcHookAspectInfo alloc] init];
    model.instance = object;
    model.selectorName = NSStringFromSelector(selector);
    model.arguments = arguments;
    
    block(model);
    
//    NSMethodSignature *blockSignature = kc_blockMethodSignature(block, nil);
//    if (!blockSignature) {
//        return;
//    }
//
//    NSInteger argumentCount = blockSignature.numberOfArguments - 1; // 返回值类型也算在里面了
//    if (argumentCount == 3) {
//        void(^imp)(id, SEL, id) = block;
//        imp(object, selector, arguments);
//    } else if (argumentCount == 2) {
//        void(^imp)(id, SEL) = block;
//        imp(object, selector);
//    } else if (argumentCount == 0) {
//        void(^imp)(void) = block;
//        imp();
//    }
}

@end

@interface KcHookTool ()

@property (nonatomic) id<KcAspectable> tool;

@end

@implementation KcHookTool

- (instancetype)init {
    if (self = [super init]) {
        self.tool = [self.class manager];
    }
    return self;
}

- (void)kc_hookWithClassName:(NSString *)className selectorName:(NSString *)selectorName withOptions:(KcAspectType)options usingBlock:(void (^)(KcHookAspectInfo * _Nonnull))block {
    Class _Nullable cls = NSClassFromString(className);
    SEL _Nullable selector = NSSelectorFromString(selectorName);
    
    if (!cls || !selector) {
        return;
    }
    
    [self kc_hookWithObjc:cls selector:selector withOptions:options usingBlock:block error:nil];
}

- (void)kc_hookWithClassName:(NSString *)className selector:(SEL)selector withOptions:(KcAspectType)options usingBlock:(void (^)(KcHookAspectInfo * _Nonnull))block {
    Class _Nullable cls = NSClassFromString(className);
    
    if (!cls) {
        return;
    }
    
    [self kc_hookWithObjc:cls selector:selector withOptions:options usingBlock:block error:nil];
}

- (void)kc_hookWithObjc:(id)objc selectorName:(NSString *)selectorName withOptions:(KcAspectType)options usingBlock:(void (^)(KcHookAspectInfo * _Nonnull info))block {
    SEL _Nullable selector = NSSelectorFromString(selectorName);
    
    if (!selector) {
        return;
    }
    
    [self kc_hookWithObjc:objc selector:selector withOptions:options usingBlock:block error:nil];
}

- (void)kc_hookWithObjc:(id)objc selector:(SEL)selector withOptions:(KcAspectType)options usingBlock:(void (^)(KcHookAspectInfo * _Nonnull))block error:(NSError *__autoreleasing  _Nullable *)error {
    [self.tool kc_hookWithObjc:objc selector:selector withOptions:options usingBlock:block error:error];
}

+ (id<KcAspectable>)manager {
    return [self aspect];
}

+ (id<KcAspectable>)aspect {
    return [[KcHookAspcet alloc] init];
}

+ (id<KcAspectable>)interceptor {
    return [[KcHookInterceptor alloc] init];
}

@end

@implementation KcHookAspectInfo

- (nullable NSString *)className {
    if (!self.instance) {
        return nil;
    }

    NSString *className;
    if (class_isMetaClass(object_getClass(self.instance))) {
        className = NSStringFromClass(self.instance);
    } else {
        className = NSStringFromClass([self.instance class]);
    }

    if ([KcHookAspectInfo isSwiftClassName:className]) {
//        className = [NSClassFromString(@"KCSwiftMeta") performSelector:@selector(demangleName:) withObject:className];
        className = [KCSwiftMeta demangleName:className];
    }
    return className ?: @"";
}

/// 对象的class
- (nullable Class)instanceClass {
    if (!self.instance) {
        return nil;
    }

    return object_getClass(self.instance);
}

/// 过滤命名空间
- (nullable NSString *)classNameFilterNameSpace {
    NSString *_Nullable className = [self className];
    
    if (!className) {
        return className;
    }
    
    // 处理swift 命名空间, 不能用后面往前面查询, 因为存在多层命名空间的问题
    NSRange range = [className rangeOfString:@"."];
    if (range.location != NSNotFound) {
        className = [className substringFromIndex:range.location + range.length];
    }
    
    return className;
}

/// 过滤selectorName前缀
- (NSString *)selectorNameFilterPrefix {
    NSString *name = self.selectorName;
    if ([name hasPrefix:@"aspects__"]) {
        name = [name substringFromIndex:@"aspects__".length];
    }
    return name;
}

/// 方法名 - 可能包含了aspects__前缀
- (SEL)selector {
    return NSSelectorFromString(self.selectorName);
}

/// 方法名 - 不包含aspects__前缀
- (SEL)originalSelector {
    NSString *selectorName = [self.selectorName hasPrefix:@"aspects__"] ? [self.selectorName substringFromIndex:@"aspects__".length] : self.selectorName;
    return NSSelectorFromString(selectorName);
}

/// 过滤前缀
- (SEL)selectorFromName:(NSString *)selectorName {
    NSString *name = selectorName.copy;
    if ([selectorName hasPrefix:@"aspects__"]) {
        name = [selectorName substringFromIndex:@"aspects__".length];
    }
    return NSSelectorFromString(name);
}

/// 是否是swift className
+ (BOOL)isSwiftClassName:(NSString *)className {
    if ([className hasPrefix:@"_Tt"]) {
        return true;
    }
    if ([className containsString:@"."]) {
        return true;
    }
    if ([className containsString:@"Swift."]) {
        return true;
    }
    return false;
}

@end


