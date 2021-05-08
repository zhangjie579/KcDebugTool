//
//  Aspects.m
//  Aspects - A delightful, simple library for aspect oriented programming.
//
//  Copyright (c) 2014 Peter Steinberger. Licensed under the MIT license.
//

#import "KcAspects.h"
#import <libkern/OSAtomic.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "KcMethodCallStack.h"

#define AspectLog(...)
//#define AspectLog(...) do { NSLog(__VA_ARGS__); }while(0)
#define AspectLogError(...) do { NSLog(__VA_ARGS__); }while(0)

// Block internals.
typedef NS_OPTIONS(int, KcAspectBlockFlags) {
    KcAspectBlockFlagsHasCopyDisposeHelpers = (1 << 25),
    KcAspectBlockFlagsHasSignature          = (1 << 30)
};
typedef struct _AspectBlock {
    __unused Class isa;
    // block的类型
    KcAspectBlockFlags flags;
    __unused int reserved;
    void (__unused *invoke)(struct _AspectBlock *block, ...);
    struct {
        unsigned long int reserved;
        unsigned long int size;
        // requires AspectBlockFlagsHasCopyDisposeHelpers
        void (*copy)(void *dst, const void *src);
        void (*dispose)(const void *);
        // requires AspectBlockFlagsHasSignature
        const char *signature;
        const char *layout;
    } *descriptor;
    // imported variables
} *AspectBlockRef;

@interface KcAspectInfo : NSObject <KcAspectInfo>
- (id)initWithInstance:(__unsafe_unretained id)instance invocation:(NSInvocation *)invocation;
@property (nonatomic, unsafe_unretained, readonly) id instance;
@property (nonatomic, strong, readonly) NSArray *arguments;
@property (nonatomic, strong, readonly) NSInvocation *originalInvocation;
@end

/// hook方法的描述 Tracks a single aspect.
@interface KcAspectIdentifier : NSObject
+ (instancetype)identifierWithSelector:(SEL)selector object:(id)object options:(KcAspectOptions)options block:(id)block error:(NSError **)error;
- (BOOL)invokeWithInfo:(id<KcAspectInfo>)info;
@property (nonatomic, assign) SEL selector;
@property (nonatomic, strong) id block;
@property (nonatomic, strong) NSMethodSignature *blockSignature;
@property (nonatomic, weak) id object;
@property (nonatomic, assign) KcAspectOptions options;
@end

// Tracks all aspects for an object/class.
@interface KcAspectsContainer : NSObject
- (void)addAspect:(KcAspectIdentifier *)aspect withOptions:(KcAspectOptions)injectPosition;
- (BOOL)removeAspect:(id)aspect;
- (BOOL)hasAspects;
@property (atomic, copy) NSArray *beforeAspects;
@property (atomic, copy) NSArray *insteadAspects;
@property (atomic, copy) NSArray *afterAspects;
@end

@interface KcAspectTracker : NSObject
- (id)initWithTrackedClass:(Class)trackedClass;
/// 包装hook方法的class
@property (nonatomic, strong) Class trackedClass;
/// hook class name
@property (nonatomic, readonly) NSString *trackedClassName;
/// 自己hook的方法name
@property (nonatomic, strong) NSMutableSet<NSString *> *selectorNames;
/// [string : set<AspectTracker>], 子类hook selector的集合, set为同一个方法hook的子类tracker
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableSet<KcAspectTracker *> *> *selectorNamesToSubclassTrackers;

/// 保存子类hook方法的tracker, 到selectorNamesToSubclassTrackers
- (void)addSubclassTracker:(KcAspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName;
/// 移除子类hook方法的tracker, 从selectorNamesToSubclassTrackers
- (void)removeSubclassTracker:(KcAspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName;
/// 是否有子类hook过selectorName这个方法
/// selectorNamesToSubclassTrackers[selectorName] != nil
- (BOOL)subclassHasHookedSelectorName:(NSString *)selectorName;
/// 子类hook这个方法
- (NSSet<KcAspectTracker *> *)subclassTrackersHookingSelectorName:(NSString *)selectorName;
@end

@interface NSInvocation (KcAspects)
- (NSArray *)kc_aspects_arguments;
@end

#define AspectPositionFilter 0x07

#define AspectError(errorCode, errorDescription) do { \
AspectLogError(@"Aspects: %@", errorDescription); \
if (error) { *error = [NSError errorWithDomain:AspectErrorDomain code:errorCode userInfo:@{NSLocalizedDescriptionKey: errorDescription}]; }}while(0)

NSString *const KcAspectErrorDomain = @"AspectErrorDomain";
static NSString *const AspectsSubclassSuffix = @"_Aspects_";
static NSString *const AspectsMessagePrefix = @"aspects_";

@implementation NSObject (KcAspects)

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Public Aspects API

+ (id<KcAspectToken>)kc_aspect_hookSelector:(SEL)selector
                      withOptions:(KcAspectOptions)options
                       usingBlock:(id)block
                            error:(NSError **)error {
    return aspect_add((id)self, selector, options, block, error);
}

/// @return A token which allows to later deregister the aspect.
- (id<KcAspectToken>)kc_aspect_hookSelector:(SEL)selector
                      withOptions:(KcAspectOptions)options
                       usingBlock:(id)block
                            error:(NSError **)error {
    return aspect_add(self, selector, options, block, error);
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Private Helper

/// 添加hook
static id aspect_add(id self, SEL selector, KcAspectOptions options, id block, NSError **error) {
    __block KcAspectIdentifier *identifier = nil;
    // 线程安全的执行
    aspect_performLocked(^{
        // 1.判断是否能hook
        if (aspect_isSelectorAllowedAndTrack(self, selector, options, error)) {
            // 2.绑定关联对象AspectsContainer
            KcAspectsContainer *aspectContainer = aspect_getContainerForObject(self, selector);
            // 3.创建hook方法的描述
            identifier = [KcAspectIdentifier identifierWithSelector:selector object:self options:options block:block error:error];
            // 4.添加hook的描述到container
            if (identifier) {
                [aspectContainer addAspect:identifier withOptions:options];

                // 5.hook方法
                aspect_prepareClassAndHookSelector(self, selector, error);
            }
        }
    });
    return identifier;
}

// 移除
static BOOL aspect_remove(KcAspectIdentifier *aspect, NSError **error) {
    __block BOOL success = NO;
    aspect_performLocked(^{
        id self = aspect.object; // strongify
        if (!self) {
            return;
        }
        // 1.获取self的关联对象, 它保存着hook方法的描述AspectIdentifier
        KcAspectsContainer *aspectContainer = aspect_getContainerForObject(self, aspect.selector);
        // 2.移除hook的描述AspectIdentifier
        success = [aspectContainer removeAspect:aspect];
        
        // 3.还原hook的class，数据清空
        aspect_cleanupHookedClassAndSelector(self, aspect.selector);
        // 4.清空aspect destroy token
        aspect.object = nil;
        aspect.block = nil;
        aspect.selector = NULL;
    });
    return success;
}

static dispatch_queue_t dispatch_get_aspect_queue() {
    static dispatch_once_t reservoir_token;
    static dispatch_queue_t backgroundSerialQueue;
    dispatch_once(&reservoir_token,
                  ^{
                      backgroundSerialQueue =
                      dispatch_queue_create("com.tencent.info.aspectqueue", DISPATCH_QUEUE_SERIAL);
                  });
    return backgroundSerialQueue;
}

// 加锁
static void aspect_performLocked(dispatch_block_t block) {
//    static OSSpinLock aspect_lock = OS_SPINLOCK_INIT;
//    OSSpinLockLock(&aspect_lock);
//    block();
//    OSSpinLockUnlock(&aspect_lock);
    
    dispatch_sync(dispatch_get_aspect_queue(), ^{
        block();
    });
}

/// hook后的方法name
static SEL aspect_aliasForSelector(SEL selector) {
    NSCParameterAssert(selector);
    return NSSelectorFromString([AspectsMessagePrefix stringByAppendingFormat:@"_%@", NSStringFromSelector(selector)]);
}

/// block的方法签名
NSMethodSignature *kc_blockMethodSignature(id block, NSError **error) {
    return aspect_blockMethodSignature(block, error);
}

/// block的方法签名
static NSMethodSignature *aspect_blockMethodSignature(id block, NSError **error) {
    AspectBlockRef layout = (__bridge void *)block;
    // 1.没有签名
    if (!(layout->flags & KcAspectBlockFlagsHasSignature)) {
        return nil;
    }
    // 2.获取descriptor
    void *desc = layout->descriptor;
    // 3.加上reserved、size的内存, 如果没有copy和dispose就为signature的内存地址
    desc += 2 * sizeof(unsigned long int);
    // 4.有copy和dispose方法, so需要加上个指针的内存, 才是signature的内存地址
    if (layout->flags & KcAspectBlockFlagsHasCopyDisposeHelpers) {
        desc += 2 * sizeof(void *);
    }
    // 5.内存地址为空, ❌
    if (!desc) {
        return nil;
    }
    // 6.获取签名
    const char *signature = (*(const char **)desc);
    return [NSMethodSignature signatureWithObjCTypes:signature];
}

static BOOL isCustomStructFromTypeEncode(NSString *typeEncode) {
    NSSet<NSString *> *set = [NSSet setWithObjects:@"CGPoint", @"CGSize", @"CGRect", @"CGVector", nil];
    
    NSString *type = typeEncode;
    if ([type hasPrefix:@"r"]) { // const
        type = [type substringFromIndex:1];
    }
    
    if ([type hasPrefix:@"^"]) { // ^type 指针
        type = [type substringFromIndex:1];
    }
    
    if ([type hasPrefix:@"["]) { // c数组 [array type]
        return true;
    } else if ([type hasPrefix:@"{"] || [type hasPrefix:@"("]) { // {name=type...}    结构体类型、(name=type...)    联合体类型
        NSArray<NSString *> *strs = [[type substringFromIndex:1] componentsSeparatedByString:@"="];
        NSString *typeName = strs.firstObject;
        
        if (![set containsObject:typeName]) {
            return true;
        }
    }
    
    return false;
}

static BOOL kc_isCustomStructWithMethod(Method method) {
    unsigned int count = method_getNumberOfArguments(method);
    
    { // 返回值
        char *returnType = method_copyReturnType(method);
        NSString *returnTypeEncode = @(returnType);
        free(returnType);
        
        if (isCustomStructFromTypeEncode(returnTypeEncode)) {
            return true;
        }
    }
    
    for (unsigned int i = 0; i < count; i++) {
//        char typeEncode[512];
//        method_getArgumentType(method, i, typeEncode, 512); // 存在溢出的风险
        
        char *typeEncode = method_copyArgumentType(method, i);
        NSString *type = @(typeEncode);
        free(typeEncode);
        
        if (isCustomStructFromTypeEncode(type)) {
            return true;
        }
    }
    return false;
}

/// 看看签名是否匹配
/// 1.block参数个数 > func参数个数 -> 不匹配; 2.block参数 > 1, 第2个参数必须是对象, 否则不匹配; 3.如果block参数 > 2, 从第3个参数开始, 要与func的第3个参数开始类型匹配
static BOOL aspect_isCompatibleBlockSignature(NSMethodSignature *blockSignature, id object, SEL selector, NSError **error) {
    BOOL signaturesMatch = YES;
//    NSMethodSignature *methodSignature;
//    NSMethodSignature *methodSignature = [[object class] instanceMethodSignatureForSelector:selector];
    
    Method method = class_getInstanceMethod([object class], selector);
    
    if (!method || kc_isCustomStructWithMethod(method)) {
        return false;
    }
    
//    NSMethodSignature *methodSignature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    
    NSMethodSignature *methodSignature;
    @try { // 由于获取NSMethodSignature可能会抛出异常
//        NSMethodSignature *methodSignature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        methodSignature = [[object class] instanceMethodSignatureForSelector:selector];
    } @catch (NSException *exception) {
        return false;
    } @finally {

    }

    if (!methodSignature) {
        return false;
    }
    
    // 1.block参数的个数 不能> 方法参数个数(最少2个, self, selector)
    if (blockSignature.numberOfArguments > methodSignature.numberOfArguments) {
        signaturesMatch = NO;
    }
    else {
        // 2.当block最少2个参数, 如果第2个参数类型不是对象 - 不匹配
        if (blockSignature.numberOfArguments > 1) {
            const char *blockType = [blockSignature getArgumentTypeAtIndex:1];
            if (blockType[0] != '@') {
                signaturesMatch = NO;
            }
        }

        // 4.当前匹配，再看看后面自定义的参数是否匹配
        if (signaturesMatch) {
            // 5.从第3个参数开始, 看看是否匹配
            for (NSUInteger idx = 2; idx < blockSignature.numberOfArguments; idx++) {
                const char *methodType = [methodSignature getArgumentTypeAtIndex:idx];
                const char *blockType = [blockSignature getArgumentTypeAtIndex:idx];
                // Only compare parameter, not the optional type data.
                if (!methodType || !blockType || methodType[0] != blockType[0]) {
                    signaturesMatch = NO; break;
                }
            }
        }
    }

    // 不匹配false
    if (!signaturesMatch) {
        return NO;
    }
    return YES;
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Class + Selector Preparation
/// 消息机制
static BOOL aspect_isMsgForwardIMP(IMP impl) {
    return impl == _objc_msgForward
#if !defined(__arm64__)
    || impl == (IMP)_objc_msgForward_stret
#endif
    ;
}

/// 返回_objc_msgForward, 到时候走消息机制
static IMP aspect_getMsgForwardIMP(NSObject *self, SEL selector) {
    IMP msgForwardIMP = _objc_msgForward;
#if !defined(__arm64__)
    // As an ugly internal runtime implementation detail in the 32bit runtime, we need to determine of the method we hook returns a struct or anything larger than id.
    // https://developer.apple.com/library/mac/documentation/DeveloperTools/Conceptual/LowLevelABI/000-Introduction/introduction.html
    // https://github.com/ReactiveCocoa/ReactiveCocoa/issues/783
    // http://infocenter.arm.com/help/topic/com.arm.doc.ihi0042e/IHI0042E_aapcs.pdf (Section 5.4)
    Method method = class_getInstanceMethod(self.class, selector);
    const char *encoding = method_getTypeEncoding(method);
    BOOL methodReturnsStructValue = encoding[0] == _C_STRUCT_B;
    if (methodReturnsStructValue) {
        @try {
            NSUInteger valueSize = 0;
            NSGetSizeAndAlignment(encoding, &valueSize, NULL);

            if (valueSize == 1 || valueSize == 2 || valueSize == 4 || valueSize == 8) {
                methodReturnsStructValue = NO;
            }
        } @catch (__unused NSException *e) {}
    }
    if (methodReturnsStructValue) {
        msgForwardIMP = (IMP)_objc_msgForward_stret;
    }
#endif
    return msgForwardIMP;
}

// MARK: - hook方法主要逻辑
/*
 1.被hook的selector的IMP被替换为：_objc_msgForward/_objc_msgForward_stret,该方法用于触发消息转发
 2.被hook的selector的本来的IMP被保存在aliasSelector中
 */
static void aspect_prepareClassAndHookSelector(NSObject *self, SEL selector, NSError **error) {
    NSCParameterAssert(selector);
    // 1.创建hookClass
    Class klass = aspect_hookClass(self, error);
    // 2.
    Method targetMethod = class_getInstanceMethod(klass, selector);
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    
    // 3.判断func的imp是不是_objc_msgForward
    if (aspect_isMsgForwardIMP(targetMethodIMP)) {
        return;
    }
    
    // 4.方法的type encode
    const char *typeEncoding = method_getTypeEncoding(targetMethod);
    // 5.hook后的方法name
    SEL aliasSelector = aspect_aliasForSelector(selector);
    // 6.没实现hook后的方法
    if (![klass instancesRespondToSelector:aliasSelector]) {
        // 7.aliasSelector的imp为原来方法的imp, 方便到时候还原
        __unused BOOL addedAlias = class_addMethod(klass, aliasSelector, method_getImplementation(targetMethod), typeEncoding);
    }
    
    // 8.- 将selector的imp -> _objc_msgForward, 这样调用它的时候就走消息机制forwardInvocation
    class_replaceMethod(klass, selector, aspect_getMsgForwardIMP(self, selector), typeEncoding);
}

/// 清理hook的class, 数据还原、清空
static void aspect_cleanupHookedClassAndSelector(NSObject *self, SEL selector) {
    // 1.获取isa
    Class klass = object_getClass(self);
    // 2.是否为元类
    BOOL isMetaClass = class_isMetaClass(klass);
    // 3.如果是元类, klass -> self, 因为元类hook的也是self, 通过aspect_hookClass得知
    if (isMetaClass) {
        klass = (Class)self;
    }
    
    // 4.获取方法的imp
    Method targetMethod = class_getInstanceMethod(klass, selector);
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    // 5.imp为消息机制
    if (aspect_isMsgForwardIMP(targetMethodIMP)) {
        // Restore the original method implementation.
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        // 5.1.获取hook方法, 它保存的是原来方法的imp
        SEL aliasSelector = aspect_aliasForSelector(selector);
        Method originalMethod = class_getInstanceMethod(klass, aliasSelector);
        IMP originalIMP = method_getImplementation(originalMethod);

        // 5.2.还原selector的imp
        class_replaceMethod(klass, selector, originalIMP, typeEncoding);
    }

    // 6.销毁selector的跟踪 Deregister global tracked selector
    aspect_deregisterTrackedSelector(self, selector);

    // Get the aspect container and check if there are any hooks remaining. Clean up if there are not.
    // 7.获取self的关联对象AspectsContainer
    KcAspectsContainer *container = aspect_getContainerForObject(self, selector);
    // 8.没有aspect, 之前方法已经移除了
    if (!container.hasAspects) {
        // Destroy the container
        // 8.1.销毁self的关联类型AspectsContainer
        aspect_destroyContainerForObject(self, selector);

        // Figure out how the class was modified to undo the changes.
        NSString *className = NSStringFromClass(klass);
        // 8.2.这个为生成新的class，并且isa改为它, 现在还原, 把isa改为原来的
        if ([className hasSuffix:AspectsSubclassSuffix]) {
            Class originalClass = NSClassFromString([className stringByReplacingOccurrencesOfString:AspectsSubclassSuffix withString:@""]);
            NSCAssert(originalClass != nil, @"Original class must exist");
            object_setClass(self, originalClass);

            // We can only dispose the class pair if we can ensure that no instances exist using our subclass.
            // Since we don't globally track this, we can't ensure this - but there's also not much overhead in keeping it around.
            //objc_disposeClassPair(object.class);
        }else {
            // 8.3.还原forwardInvocation的imp
            // Class is most likely swizzled in place. Undo that.
            if (isMetaClass) {
                aspect_undoSwizzleClassInPlace((Class)self);
            }else if (self.class != klass) {
                aspect_undoSwizzleClassInPlace(klass);
            }
        }
    }
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Hook Class

/* 返回hook class
 
 1.已经hook的直接返回
 2.对于meta, kvo的class，直接在自身上进行method swizzling
    * meta: hook的为class对象, 即传入的self对象
    * KVO: hook的为isa, 即KVO新生成的类
 3.注册一个新的class(类似于KVO) --- className_Aspects_
    * 将它的forwardInvocation方法imp指向__ASPECTS_ARE_BEING_CALLED__
    * isa为className
 */
static Class aspect_hookClass(NSObject *self, NSError **error) {
    NSCParameterAssert(self);
    // self为class、objc得到的全为class类对象
    Class statedClass = self.class;
    // 获取isa，self为objc得到class、为class得到mate class
    Class baseClass = object_getClass(self);
    NSString *className = NSStringFromClass(baseClass);

    // 1.Already subclassed - 已经hook了
    // 如果baseClass是MetaClass或者被KVO过的Class，则不必再生成subClass，直接在其自身上进行method swizzling
    if ([className hasSuffix:AspectsSubclassSuffix]) {
        return baseClass;

        // 2.元类, 说明self为class对象，这边hook是self(class)，而不是对象
    }else if (class_isMetaClass(baseClass)) {
        return aspect_swizzleClassInPlace((Class)self);
        // 3.class对象与isa不同, 比如KVO, 这边hook的isa, 即kvo的类
    } else if (statedClass != baseClass) {
        return aspect_swizzleClassInPlace(baseClass);
    }

    // 4.默认情况，动态创建子类 - 等价于KVO的原理
    
    // 4.1.获取子类的class name
    const char *subclassName = [className stringByAppendingString:AspectsSubclassSuffix].UTF8String;
    // 4.2.class name -> Class
    Class subclass = objc_getClass(subclassName);

    // 4.3.class为空，说明没有，则创建
    if (subclass == nil) {
        // 创建subclassName, baseClass为它的isa
        subclass = objc_allocateClassPair(baseClass, subclassName, 0);
        // 4.4.创建失败, failure
        if (!subclass) {
            return nil;
        }

        // 4.5.hook forwardInvocation
        aspect_swizzleForwardInvocation(subclass);
        // 4.6.把subclass的isa指向了statedClass(一个假象, self.class还是原来的类)
        aspect_hookedGetClass(subclass, statedClass);
        // 4.7.把subclass的元类的isa，也指向了statedClass
        aspect_hookedGetClass(object_getClass(subclass), statedClass);
        
        // 4.8.注册class
        objc_registerClassPair(subclass);
    }

    // 5.设置self的isa为subclass
    object_setClass(self, subclass);
    return subclass;
}

/*
 将forwardInvocation的imp改为__ASPECTS_ARE_BEING_CALLED__
 而forwardInvocation的imp给了__aspects_forwardInvocation
 */
static NSString *const AspectsForwardInvocationSelectorName = @"__aspects_forwardInvocation:";
static void aspect_swizzleForwardInvocation(Class klass) {
    NSCParameterAssert(klass);
    // 修改forwardInvocation的imp
    IMP originalImplementation = class_replaceMethod(klass, @selector(forwardInvocation:), (IMP)__ASPECTS_ARE_BEING_CALLED__, "v@:@");
    if (originalImplementation) {
        // 添加AspectsForwardInvocationSelectorName方法，imp为原来的forwardInvocation
        // 用于后面还原hook
        class_addMethod(klass, NSSelectorFromString(AspectsForwardInvocationSelectorName), originalImplementation, "v@:@");
    }
}

// 将forwardInvocation的imp还原
static void aspect_undoSwizzleForwardInvocation(Class klass) {
    NSCParameterAssert(klass);
    Method originalMethod = class_getInstanceMethod(klass, NSSelectorFromString(AspectsForwardInvocationSelectorName));
    Method objectMethod = class_getInstanceMethod(NSObject.class, @selector(forwardInvocation:));
    // There is no class_removeMethod, so the best we can do is to retore the original implementation, or use a dummy.
    IMP originalImplementation = method_getImplementation(originalMethod ?: objectMethod);
    class_replaceMethod(klass, @selector(forwardInvocation:), originalImplementation, "v@:@");

    AspectLog(@"Aspects: %@ has been restored.", NSStringFromClass(klass));
}

// 将class的isa替换为statedClass, 与系统KVO的处理类似
static void aspect_hookedGetClass(Class class, Class statedClass) {
    NSCParameterAssert(class);
    NSCParameterAssert(statedClass);
    // 1.获取class的class对象方法
    Method method = class_getInstanceMethod(class, @selector(class));
    // 2.imp返回statedClass
    IMP newIMP = imp_implementationWithBlock(^(id self) {
        return statedClass;
    });
    // 3.class的class对象方法返回statedClass
    class_replaceMethod(class, @selector(class), newIMP, method_getTypeEncoding(method));
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Swizzle Class In Place

/// 加锁执行block
static void _aspect_modifySwizzledClasses(void (^block)(NSMutableSet *swizzledClasses)) {
    // 单例 Set<String>, 存的是class name
    static NSMutableSet *swizzledClasses;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        swizzledClasses = [NSMutableSet new];
    });
    @synchronized(swizzledClasses) {
        block(swizzledClasses);
    }
}

// 改变forwardInvocation的imp
static Class aspect_swizzleClassInPlace(Class klass) {
    NSCParameterAssert(klass);
    NSString *className = NSStringFromClass(klass);

    _aspect_modifySwizzledClasses(^(NSMutableSet *swizzledClasses) {
        // 不包含这个className
        if (![swizzledClasses containsObject:className]) {
            // 修改forwardInvocation方法的imp
            aspect_swizzleForwardInvocation(klass);
            [swizzledClasses addObject:className];
        }
    });
    return klass;
}

// 还原forwardInvocation的imp
static void aspect_undoSwizzleClassInPlace(Class klass) {
    NSCParameterAssert(klass);
    NSString *className = NSStringFromClass(klass);

    _aspect_modifySwizzledClasses(^(NSMutableSet *swizzledClasses) {
        if ([swizzledClasses containsObject:className]) {
            aspect_undoSwizzleForwardInvocation(klass);
            [swizzledClasses removeObject:className];
        }
    });
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Aspect Invoke Point

// This is a macro so we get a cleaner stack trace.
#define aspect_invoke(aspects, info) \
for (KcAspectIdentifier *aspect in aspects) {\
    [aspect invokeWithInfo:info];\
    if (aspect.options & KcAspectOptionAutomaticRemoval) { \
        aspectsToRemove = [aspectsToRemove?:@[] arrayByAddingObject:aspect]; \
    } \
}

// MARK: - 执行hook后forwardInvocation的imp的逻辑
// This is the swizzled forwardInvocation: method.
// 执行hook后forwardInvocation的imp的逻辑
static void __ASPECTS_ARE_BEING_CALLED__(__unsafe_unretained NSObject *self, SEL selector, NSInvocation *invocation) {
    NSCParameterAssert(self);
    NSCParameterAssert(invocation);
    SEL originalSelector = invocation.selector;
    // 1.hook后的方法
    SEL aliasSelector = aspect_aliasForSelector(invocation.selector);
    // 2.改变selector为hook后的方法
    invocation.selector = aliasSelector;
    // 3.获取self的关联对象
    KcAspectsContainer *objectContainer = objc_getAssociatedObject(self, aliasSelector);
    // 4.获取class的关联对象, 有hook
    KcAspectsContainer *classContainer = aspect_getContainerForClass(object_getClass(self), aliasSelector);
    
    { // 特殊处理
        /*
         1.比如外面已经通过method_exchangeImplementations hook过了 pushViewController:animated: , 而Aspect还是通过`pushViewController:animated:`方法保存的数据
            * 执行逻辑的时候, 比如 [self kc_pushViewController:animated:], 传入的originalSelector = kc_pushViewController:animated:, 找不到原来实现, so crash
            * 这边兼容下, 如果找不到, 而又是需要特殊处理的方法, 就直接用对应的方法
         2.处理 kc_pushViewController:animated: -> pushViewController:animated:
         */
        if (!objectContainer && !classContainer) {
            NSMutableArray<NSString *> *specialHandleMethods = [[NSMutableArray alloc] init];
            // 导航栏方法
            [specialHandleMethods addObjectsFromArray:kc_methodNamesNavigation()];
            
            SEL originalSelector1 = originalSelector;
            NSString *originalSelectorName = NSStringFromSelector(originalSelector1);
            for (NSString *method in specialHandleMethods) {
                NSString *lowOriginalName = originalSelectorName.lowercaseString;
                NSString *lowName = method.lowercaseString;
                // 1.求出包含, originalSelectorName方法可能是 kc_pushViewController:animated: 、 method: pushViewController:animated:
                if (![lowOriginalName containsString:lowName]) {
                    continue;
                }
                // 2.如果 == -> 不需要处理
                if ([originalSelectorName isEqualToString:method]) {
                    break;
                }
                // 3.替换为method
                originalSelector1 = NSSelectorFromString(method);
                break;
            }
            
            SEL aliasSelector1 = aspect_aliasForSelector(originalSelector1);
            KcAspectsContainer *objectContainer1 = objc_getAssociatedObject(self, aliasSelector1);
            KcAspectsContainer *classContainer1 = aspect_getContainerForClass(object_getClass(self), aliasSelector1);
            
            // 替换
            if (objectContainer1 || classContainer1) {
                aliasSelector = aliasSelector1;
                invocation.selector = aliasSelector;
                objectContainer = objectContainer1;
                classContainer = classContainer1;
            }
        }
        
        // 处理 kc_pushViewController:animated: -> pushViewController:animated:
        if (!objectContainer && !classContainer) {
            SEL originalSelector2 = originalSelector;
            NSString *originalSelectorName = NSStringFromSelector(originalSelector2);
            if ([originalSelectorName containsString:@"_"]) {
                NSRange range = [originalSelectorName rangeOfString:@"_"];
                NSString *newSelectorName = [originalSelectorName substringFromIndex:range.location + range.length];
                originalSelector2 = NSSelectorFromString(newSelectorName);
                SEL aliasSelector2 = aspect_aliasForSelector(originalSelector2);
                KcAspectsContainer *objectContainer2 = objc_getAssociatedObject(self, aliasSelector2);
                KcAspectsContainer *classContainer2 = aspect_getContainerForClass(object_getClass(self), aliasSelector2);
                
                // 替换
                if (objectContainer2 || classContainer2) {
                    aliasSelector = aliasSelector2;
                    invocation.selector = aliasSelector;
                    objectContainer = objectContainer2;
                    classContainer = classContainer2;
                }
            }
        }
        
    }
    
    // 5.包装执行invoke的对象
    KcAspectInfo *info = [[KcAspectInfo alloc] initWithInstance:self invocation:invocation];
    NSArray *aspectsToRemove = nil;

    // 6.执行 Before hooks.
    aspect_invoke(classContainer.beforeAspects, info);
    aspect_invoke(objectContainer.beforeAspects, info);

    kc_push_call_record(invocation.target, invocation.selector);
    
    // 7.Instead hooks. 如果有替代method的imp的block，就执行
    CFAbsoluteTime currentTime = CFAbsoluteTimeGetCurrent();
    BOOL respondsToAlias = YES;
    if (objectContainer.insteadAspects.count || classContainer.insteadAspects.count) {
        aspect_invoke(classContainer.insteadAspects, info);
        aspect_invoke(objectContainer.insteadAspects, info);
    }else { // 执行原来的imp
        // 8.由于isa换成了hook class
        Class klass = object_getClass(invocation.target);
        do {
            // 9.aliasSelector的imp是原始func的，so执行它就是执行原来的
            if ((respondsToAlias = [klass instancesRespondToSelector:aliasSelector])) {
                [invocation invoke];
                break;
            }
        }while (!respondsToAlias && (klass = class_getSuperclass(klass)));
    }
    
    info.duration = CFAbsoluteTimeGetCurrent() - currentTime;
    
    // 因为invocation的target是assign修饰, 销毁了也不会释放指针(野指针)⚠️
    NSString *selectorName = NSStringFromSelector(invocation.selector);
    if (![selectorName hasSuffix:@"dealloc"]) {
        kc_pop_call_record(invocation.target, invocation.selector);
    }

    // 10.After hooks.
    aspect_invoke(classContainer.afterAspects, info);
    aspect_invoke(objectContainer.afterAspects, info);

    // If no hooks are installed, call original implementation (usually to throw an exception)
    // 11.没实现hook后的方法
    if (!respondsToAlias) {
        invocation.selector = originalSelector;
        // 11.1.原始的forwardInvocation方法
        SEL originalForwardInvocationSEL = NSSelectorFromString(AspectsForwardInvocationSelectorName);
        // 11.2.实现了原始的forwardInvocation, 执行
        if ([self respondsToSelector:originalForwardInvocationSEL]) {
            ((void( *)(id, SEL, NSInvocation *))objc_msgSend)(self, originalForwardInvocationSEL, invocation);
        } else {
            [self doesNotRecognizeSelector:invocation.selector];
        }
    }

    // 12.让需要执行remove hook的执行 Remove any hooks that are queued for deregistration.
    [aspectsToRemove makeObjectsPerformSelector:@selector(remove)];
}
#undef aspect_invoke

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Aspect Container Management

// Loads or creates the aspect container.
/// 绑定关联对象AspectsContainer
static KcAspectsContainer *aspect_getContainerForObject(NSObject *self, SEL selector) {
    NSCParameterAssert(self);
    // 1.hook后的方法name
    SEL aliasSelector = aspect_aliasForSelector(selector);
    // 2.给self绑定个关联对象AspectsContainer
    KcAspectsContainer *aspectContainer = objc_getAssociatedObject(self, aliasSelector);
    if (!aspectContainer) {
        aspectContainer = [KcAspectsContainer new];
        objc_setAssociatedObject(self, aliasSelector, aspectContainer, OBJC_ASSOCIATION_RETAIN);
    }
    return aspectContainer;
}

/// 获取class的关联对象, 有hook
static KcAspectsContainer *aspect_getContainerForClass(Class klass, SEL selector) {
    NSCParameterAssert(klass);
    KcAspectsContainer *classContainer = nil;
    do {
        classContainer = objc_getAssociatedObject(klass, selector);
        if (classContainer.hasAspects) break;
    }while ((klass = class_getSuperclass(klass)));

    return classContainer;
}

/// 销毁self的container关联对象
static void aspect_destroyContainerForObject(id<NSObject> self, SEL selector) {
    NSCParameterAssert(self);
    SEL aliasSelector = aspect_aliasForSelector(selector);
    objc_setAssociatedObject(self, aliasSelector, nil, OBJC_ASSOCIATION_RETAIN);
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Selector Blacklist Checking

/// [Class : AspectTracker], hook的class方法的class
static NSMutableDictionary *aspect_getSwizzledClassesDict() {
    static NSMutableDictionary *swizzledClassesDict;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        swizzledClassesDict = [NSMutableDictionary new];
    });
    return swizzledClassesDict;
}

/// 导航栏方法
static NSArray<NSString *> *kc_methodNamesNavigation() {
    NSArray<NSString *> *methods = @[
        NSStringFromSelector(@selector(pushViewController:animated:)),
        NSStringFromSelector(@selector(presentViewController:animated:completion:)),
        NSStringFromSelector(@selector(dismissViewControllerAnimated:completion:)),
        NSStringFromSelector(@selector(popViewControllerAnimated:)),
    ];
    return methods;
};

#pragma mark - 判断是否能hook

/// 允许hook的白名单
static NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *allowedClassSelectorList;

/// 是否是白名单
static BOOL kc_isWhiteClassSelectorList(id objc, SEL selector) {
    if ([allowedClassSelectorList[NSStringFromClass([objc class])] containsObject:NSStringFromSelector(selector)]) {
        return YES;
    }
    return NO;
}

/* 判断selector是否能hook
 1.黑名单(retain, release, autorelease, forwardInvocation:)不能hook
 2.dealloc只能在它执行之前添加操作
 3.没实现方法(instance method、class method)不能hook
 4.hook传入的self为objc - 可以hook
 5.hook传入的为Class
    * 已经hook, 不能再hook
    * super已经hook了方法的话, 不能hook
    * 可以hook
 */
static BOOL aspect_isSelectorAllowedAndTrack(NSObject *self, SEL selector, KcAspectOptions options, NSError **error) {
    // 0.保存不能hook的方法 - 黑名单
    static NSSet *disallowedSelectorList;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        disallowedSelectorList = [NSSet setWithObjects:@"retain", @"release", @"autorelease", @"forwardInvocation:", nil];
        allowedClassSelectorList = [@{
//            // 监听手势
//            @"UIGestureRecognizerTarget": [NSMutableSet setWithArray:@[
//                @"_sendActionWithGestureRecognizer:",
//            ]],
        } mutableCopy];
    });
    
//    // 0.1.白名单
//    if (kc_isWhiteClassSelectorList(self, selector)) {
//        return YES;
//    }

    // 1.Check against the blacklist.(黑名单)
    NSString *selectorName = NSStringFromSelector(selector);
    if ([disallowedSelectorList containsObject:selectorName]) {
        return NO;
    }

    // 2.Additional checks. - dealloc并且不是它before
    KcAspectOptions position = options & AspectPositionFilter;
    if ([selectorName isEqualToString:@"dealloc"] && position != KcAspectPositionBefore) {
        return NO;
    }

    // 3.没实现这func, respondsToSelector: 如果self为class为class方法, 为objc的话为instance方法
    // instancesRespondToSelector: self.class无论self是objc还是class得到的都是class, 是否实现对象方法
    if (![self respondsToSelector:selector] && ![self.class instancesRespondToSelector:selector]) {
        return NO;
    }

    // 4.class_isMetaClass 先判断是不是类(self的isa是元类，so self是类，而不是object)。接下来的判断都是判断元类里面能否允许被替换方法
    if (class_isMetaClass(object_getClass(self))) {
        Class klass = [self class];
        NSMutableDictionary *swizzledClassesDict = aspect_getSwizzledClassesDict();
        Class currentClass = [self class];

        // 4.1.subclassHasHookedSelectorName: 子类hook过的, 如果子类已经hook了, 不能hook
        // 比如: 先UILable hook initWithFrame, 然后再UIView hook, 这时候swizzledClassesDict[UIView].selectorNamesToSubclassTrackers有值, 不能hook
        KcAspectTracker *tracker = swizzledClassesDict[currentClass];
        if ([tracker subclassHasHookedSelectorName:selectorName]) {
            NSSet *subclassTracker = [tracker subclassTrackersHookingSelectorName:selectorName];
            NSSet *subclassNames = [subclassTracker valueForKey:@"trackedClassName"];
            return NO;
        }

        // 4.2.selectorNames: 自己hook的方法列表; 类层次已经hook了的话不能再hook, 如果super hook的话, 报错
        do {
            tracker = swizzledClassesDict[currentClass];
            if ([tracker.selectorNames containsObject:selectorName]) {
                // 当前的class hook - 直接返回
                if (klass == currentClass) {
                    // Already modified and topmost!
                    return YES;
                }
                
                // super已经hook了
                NSString *errorDescription = [NSString stringWithFormat:@"Error: %@ already hooked in %@. A method can only be hooked once per class hierarchy.", selectorName, NSStringFromClass(currentClass)];
//                AspectError(AspectErrorSelectorAlreadyHookedInClassHierarchy, errorDescription);
                return NO;
            }
        } while ((currentClass = class_getSuperclass(currentClass)));

        /* 4.3.到这说明没hook, 添加hook方法
         1.swizzledClassesDict: 不只是保存当前class、所有的superClass都会保存
         2.tracker会添加subclassTracker
         
         比如 label hook initWithFrame
         1.label tracker_label
         swizzledClassesDict = [label : tracker_label];
         tracker_label.selectorNames = ["initWithFrame"]
         
         2.view tracker_view
         swizzledClassesDict = [label : tracker_label, view : tracker_view];
         tracker_view.selectorNamesToSubclassTrackers = ["initWithFrame" : tracker_label]
         
         3.UIResponse tracker_response
          swizzledClassesDict = [label : tracker_label, view : tracker_view, UIResponse tracker_response];
         tracker_response.selectorNamesToSubclassTrackers = ["initWithFrame" : tracker_view]
         
         4. ...
         */
        // Add the selector as being modified.
        currentClass = klass;
        KcAspectTracker *subclassTracker = nil;
        do {
            // 4.3.1.获取class的tracker, 没有就创建并保存
            tracker = swizzledClassesDict[currentClass];
            if (!tracker) {
                tracker = [[KcAspectTracker alloc] initWithTrackedClass:currentClass];
                swizzledClassesDict[(id<NSCopying>)currentClass] = tracker;
            }
            // 4.3.2.有子类的tracker, 添加到tracker
            if (subclassTracker) {
                [tracker addSubclassTracker:subclassTracker hookingSelectorName:selectorName];
            } else {
                // 4.3.3.没有子类的, 添加hook的selector
                [tracker.selectorNames addObject:selectorName];
            }

            // 4.3.4.subclassTracker更新为当前的tracker
            // All superclasses get marked as having a subclass that is modified.
            subclassTracker = tracker;
            // 4.3.5.找super
        }while ((currentClass = class_getSuperclass(currentClass)));
    } else {
        return YES;
    }

    return YES;
}

/// 销毁selector的AspectTracker
static void aspect_deregisterTrackedSelector(id self, SEL selector) {
    // 1.self的isa不是元类 -> return
    if (!class_isMetaClass(object_getClass(self))) return;

    // 2.
    NSMutableDictionary *swizzledClassesDict = aspect_getSwizzledClassesDict();
    NSString *selectorName = NSStringFromSelector(selector);
    Class currentClass = [self class];
    KcAspectTracker *subclassTracker = nil;
    do {
        // 3.
        KcAspectTracker *tracker = swizzledClassesDict[currentClass];
        // 4.有sub tracker
        if (subclassTracker) {
            [tracker removeSubclassTracker:subclassTracker hookingSelectorName:selectorName];
        } else {
            // 移除这个selectorName
            [tracker.selectorNames removeObject:selectorName];
        }
        // 5.swizzledClassesDict中移除这个class
        if (tracker.selectorNames.count == 0 && tracker.selectorNamesToSubclassTrackers) {
            [swizzledClassesDict removeObjectForKey:currentClass];
        }
        // 6.它为subclassTracker
        subclassTracker = tracker;
        // 7.继续找super
    }while ((currentClass = class_getSuperclass(currentClass)));
}

@end

// MARK: - AspectTracker
@implementation KcAspectTracker

- (id)initWithTrackedClass:(Class)trackedClass {
    if (self = [super init]) {
        _trackedClass = trackedClass;
        _selectorNames = [NSMutableSet new];
        _selectorNamesToSubclassTrackers = [NSMutableDictionary new];
    }
    return self;
}

- (BOOL)subclassHasHookedSelectorName:(NSString *)selectorName {
    return self.selectorNamesToSubclassTrackers[selectorName] != nil;
}

- (void)addSubclassTracker:(KcAspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName {
    NSMutableSet *trackerSet = self.selectorNamesToSubclassTrackers[selectorName];
    if (!trackerSet) {
        trackerSet = [NSMutableSet new];
        self.selectorNamesToSubclassTrackers[selectorName] = trackerSet;
    }
    [trackerSet addObject:subclassTracker];
}
- (void)removeSubclassTracker:(KcAspectTracker *)subclassTracker hookingSelectorName:(NSString *)selectorName {
    NSMutableSet *trackerSet = self.selectorNamesToSubclassTrackers[selectorName];
    [trackerSet removeObject:subclassTracker];
    if (trackerSet.count == 0) {
        [self.selectorNamesToSubclassTrackers removeObjectForKey:selectorName];
    }
}
- (NSSet *)subclassTrackersHookingSelectorName:(NSString *)selectorName {
    NSMutableSet *hookingSubclassTrackers = [NSMutableSet new];
    for (KcAspectTracker *tracker in self.selectorNamesToSubclassTrackers[selectorName]) {
        if ([tracker.selectorNames containsObject:selectorName]) {
            [hookingSubclassTrackers addObject:tracker];
        }
        [hookingSubclassTrackers unionSet:[tracker subclassTrackersHookingSelectorName:selectorName]];
    }
    return hookingSubclassTrackers;
}
- (NSString *)trackedClassName {
    return NSStringFromClass(self.trackedClass);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %@, trackedClass: %@, selectorNames:%@, subclass selector names: %@>", self.class, self, NSStringFromClass(self.trackedClass), self.selectorNames, self.selectorNamesToSubclassTrackers.allKeys];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSInvocation (Aspects)

@implementation NSInvocation (KcAspects)

// Thanks to the ReactiveCocoa team for providing a generic solution for this.
// https://nshipster.cn/type-encodings/
- (id)kc_aspect_argumentAtIndex:(NSUInteger)index {
    const char *argType = [self.methodSignature getArgumentTypeAtIndex:index];
    // Skip const type qualifier. 为const标识
    if (argType[0] == _C_CONST) argType++;

#define WRAP_AND_RETURN(type) do { type val = 0; [self getArgument:&val atIndex:(NSInteger)index]; return @(val); } while (0)
    // 1.id、class
    if (strcmp(argType, @encode(id)) == 0 || strcmp(argType, @encode(Class)) == 0) {
        __autoreleasing id returnObj;
        [self getArgument:&returnObj atIndex:(NSInteger)index];
        return returnObj;
    // 2.sel
    } else if (strcmp(argType, @encode(SEL)) == 0) {
        SEL selector = 0;
        [self getArgument:&selector atIndex:(NSInteger)index];
        return NSStringFromSelector(selector);
    // 3.class
    } else if (strcmp(argType, @encode(Class)) == 0) {
        __autoreleasing Class theClass = Nil;
        [self getArgument:&theClass atIndex:(NSInteger)index];
        return theClass;
        // Using this list will box the number with the appropriate constructor, instead of the generic NSValue.
    // 4.char
    } else if (strcmp(argType, @encode(char)) == 0) {
        WRAP_AND_RETURN(char);
    } else if (strcmp(argType, @encode(int)) == 0) {
        WRAP_AND_RETURN(int);
    } else if (strcmp(argType, @encode(short)) == 0) {
        WRAP_AND_RETURN(short);
    } else if (strcmp(argType, @encode(long)) == 0) {
        WRAP_AND_RETURN(long);
    } else if (strcmp(argType, @encode(long long)) == 0) {
        WRAP_AND_RETURN(long long);
    } else if (strcmp(argType, @encode(unsigned char)) == 0) {
        WRAP_AND_RETURN(unsigned char);
    } else if (strcmp(argType, @encode(unsigned int)) == 0) {
        WRAP_AND_RETURN(unsigned int);
    } else if (strcmp(argType, @encode(unsigned short)) == 0) {
        WRAP_AND_RETURN(unsigned short);
    } else if (strcmp(argType, @encode(unsigned long)) == 0) {
        WRAP_AND_RETURN(unsigned long);
    } else if (strcmp(argType, @encode(unsigned long long)) == 0) {
        WRAP_AND_RETURN(unsigned long long);
    } else if (strcmp(argType, @encode(float)) == 0) {
        WRAP_AND_RETURN(float);
    } else if (strcmp(argType, @encode(double)) == 0) {
        WRAP_AND_RETURN(double);
    } else if (strcmp(argType, @encode(BOOL)) == 0) {
        WRAP_AND_RETURN(BOOL);
    } else if (strcmp(argType, @encode(bool)) == 0) {
        WRAP_AND_RETURN(BOOL);
    } else if (strcmp(argType, @encode(char *)) == 0) {
        WRAP_AND_RETURN(const char *);
    } else if (strcmp(argType, @encode(void (^)(void))) == 0) {
        __unsafe_unretained id block = nil;
        [self getArgument:&block atIndex:(NSInteger)index];
        return [block copy];
    } else {
        NSUInteger valueSize = 0;
        NSGetSizeAndAlignment(argType, &valueSize, NULL);

        unsigned char valueBytes[valueSize];
        [self getArgument:valueBytes atIndex:(NSInteger)index];

        return [NSValue valueWithBytes:valueBytes objCType:argType];
    }
    return nil;
#undef WRAP_AND_RETURN
}

- (NSArray *)kc_aspects_arguments {
    NSMutableArray *argumentsArray = [NSMutableArray array];
    for (NSUInteger idx = 2; idx < self.methodSignature.numberOfArguments; idx++) {
        [argumentsArray addObject:[self kc_aspect_argumentAtIndex:idx] ?: NSNull.null];
    }
    return [argumentsArray copy];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectIdentifier

@implementation KcAspectIdentifier

+ (instancetype)identifierWithSelector:(SEL)selector object:(id)object options:(KcAspectOptions)options block:(id)block error:(NSError **)error {
    NSCParameterAssert(block);
    NSCParameterAssert(selector);
    // block的方法签名
    NSMethodSignature *blockSignature = aspect_blockMethodSignature(block, error); // TODO: check signature compatibility, etc.
    // 参数是否对上
    if (!aspect_isCompatibleBlockSignature(blockSignature, object, selector, error)) {
        return nil;
    }

    KcAspectIdentifier *identifier = nil;
    if (blockSignature) {
        identifier = [KcAspectIdentifier new];
        identifier.selector = selector;
        identifier.block = block;
        identifier.blockSignature = blockSignature;
        identifier.options = options;
        identifier.object = object; // weak
    }
    return identifier;
}

/// 执行invoke
- (BOOL)invokeWithInfo:(id<KcAspectInfo>)info {
    NSInvocation *blockInvocation = [NSInvocation invocationWithMethodSignature:self.blockSignature];
    NSInvocation *originalInvocation = info.originalInvocation;
    // block参数个数
    NSUInteger numberOfArguments = self.blockSignature.numberOfArguments;

    // Be extra paranoid. We already check that on hook registration. 1.(容错处理: block参数个数不能大于方法参数个数)
    if (numberOfArguments > originalInvocation.methodSignature.numberOfArguments) {
        AspectLogError(@"Block has too many arguments. Not calling %@", info);
        return NO;
    }

    // The `self` of the block will be the AspectInfo. Optional. 2.(超过1个参数, 第2个参数是AspectInfo), block的第一个参数为block自己
    if (numberOfArguments > 1) {
        [blockInvocation setArgument:&info atIndex:1];
    }
    
    // 3.超过2个参数, 从第3个参数开始, 与func的第3个参数一致
    void *argBuf = NULL;
    for (NSUInteger idx = 2; idx < numberOfArguments; idx++) {
        const char *type = [originalInvocation.methodSignature getArgumentTypeAtIndex:idx];
        NSUInteger argSize;
        NSGetSizeAndAlignment(type, &argSize, NULL);
        
        if (!(argBuf = reallocf(argBuf, argSize))) {
            AspectLogError(@"Failed to allocate memory for block invocation.");
            return NO;
        }
        
        [originalInvocation getArgument:argBuf atIndex:idx];
        [blockInvocation setArgument:argBuf atIndex:idx];
    }
    
    // 4.target为block, 设置第1个参数
    [blockInvocation invokeWithTarget:self.block];
    
    if (argBuf != NULL) {
        free(argBuf);
    }
    return YES;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, SEL:%@ object:%@ options:%tu block:%@ (#%tu args)>", self.class, self, NSStringFromSelector(self.selector), self.object, self.options, self.block, self.blockSignature.numberOfArguments];
}

/// 移除hook, 恢复原来
- (BOOL)remove {
    return aspect_remove(self, NULL);
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectsContainer

@implementation KcAspectsContainer

/// 是否有hook方法
- (BOOL)hasAspects {
    return self.beforeAspects.count > 0 || self.insteadAspects.count > 0 || self.afterAspects.count > 0;
}

/// 根据不同的hook类型添加到对应的array中
- (void)addAspect:(KcAspectIdentifier *)aspect withOptions:(KcAspectOptions)options {
    NSParameterAssert(aspect);
    NSUInteger position = options&AspectPositionFilter;
    switch (position) {
        case KcAspectPositionBefore:  self.beforeAspects  = [(self.beforeAspects ?:@[]) arrayByAddingObject:aspect]; break;
        case KcAspectPositionInstead: self.insteadAspects = [(self.insteadAspects?:@[]) arrayByAddingObject:aspect]; break;
        case KcAspectPositionAfter:   self.afterAspects   = [(self.afterAspects  ?:@[]) arrayByAddingObject:aspect]; break;
    }
}

/// 移除hook的aspect(AspectIdentifier)
- (BOOL)removeAspect:(id)aspect {
    for (NSString *aspectArrayName in @[NSStringFromSelector(@selector(beforeAspects)),
                                        NSStringFromSelector(@selector(insteadAspects)),
                                        NSStringFromSelector(@selector(afterAspects))]) {
        NSArray *array = [self valueForKey:aspectArrayName];
        NSUInteger index = [array indexOfObjectIdenticalTo:aspect];
        if (array && index != NSNotFound) {
            NSMutableArray *newArray = [NSMutableArray arrayWithArray:array];
            [newArray removeObjectAtIndex:index];
            [self setValue:newArray forKey:aspectArrayName];
            return YES;
        }
    }
    return NO;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, before:%@, instead:%@, after:%@>", self.class, self, self.beforeAspects, self.insteadAspects, self.afterAspects];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectInfo

@implementation KcAspectInfo

@synthesize duration = _duration;
@synthesize arguments = _arguments;

- (id)initWithInstance:(__unsafe_unretained id)instance invocation:(NSInvocation *)invocation {
    NSCParameterAssert(instance);
    NSCParameterAssert(invocation);
    if (self = [super init]) {
        _instance = instance;
        _originalInvocation = invocation;
    }
    return self;
}

- (NSArray *)arguments {
    // Lazily evaluate arguments, boxing is expensive.
    if (!_arguments) {
        _arguments = self.originalInvocation.kc_aspects_arguments;
    }
    return _arguments;
}

@end
