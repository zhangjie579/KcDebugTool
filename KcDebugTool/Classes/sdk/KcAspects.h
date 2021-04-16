//
//  Aspects.h
//  Aspects - A delightful, simple library for aspect oriented programming.
//
//  Copyright (c) 2014 Peter Steinberger. Licensed under the MIT license.
//

#import <Foundation/Foundation.h>

typedef NS_OPTIONS(NSUInteger, KcAspectOptions) {
    KcAspectPositionAfter   = 0,            /// Called after the original implementation (default)
    KcAspectPositionInstead = 1,            /// Will replace the original implementation.
    KcAspectPositionBefore  = 2,            /// Called before the original implementation.
    
    KcAspectOptionAutomaticRemoval = 1 << 3 /// Will remove the hook after the first execution.
};

/// Opaque Aspect Token that allows to deregister the hook.
@protocol KcAspectToken <NSObject>

/// Deregisters an aspect.
/// @return YES if deregistration is successful, otherwise NO.
/// 恢复hook之前
- (BOOL)remove;

@end

/// The AspectInfo protocol is the first parameter of our block syntax.
@protocol KcAspectInfo <NSObject>

/// The instance that is currently hooked.
- (id)instance;

/// The original invocation of the hooked method.
- (NSInvocation *)originalInvocation;

/// All method arguments, boxed. This is lazily evaluated.
- (NSArray *)arguments;

/// 方法执行时间
@property (nonatomic) double duration;

@end

/**
 Aspects uses Objective-C message forwarding to hook into messages. This will create some overhead. Don't add aspects to methods that are called a lot. Aspects is meant for view/controller code that is not called a 1000 times per second.

 Adding aspects returns an opaque token which can be used to deregister again. All calls are thread safe.
 */
@interface NSObject (KcAspects)

/// Adds a block of code before/instead/after the current `selector` for a specific class. (这种方式会影响所有class的对象, 影响范围比较大)
///
/// @param block Aspects replicates the type signature of the method being hooked.
/// The first parameter will be `id<AspectInfo>`, followed by all parameters of the method.
/// These parameters are optional and will be filled to match the block signature.
/// You can even use an empty block, or one that simple gets `id<AspectInfo>`.
///
/// @note Hooking static methods is not supported.
/// @return A token which allows to later deregister the aspect.
+ (id<KcAspectToken>)kc_aspect_hookSelector:(SEL)selector
                           withOptions:(KcAspectOptions)options
                            usingBlock:(id)block
                                 error:(NSError **)error;

/// Adds a block of code before/instead/after the current `selector` for a specific instance. (这种方式会只影响当前objc对象, 影响范围小) 👍
- (id<KcAspectToken>)kc_aspect_hookSelector:(SEL)selector
                           withOptions:(KcAspectOptions)options
                            usingBlock:(id)block
                                 error:(NSError **)error;

@end

//typedef NS_ENUM(NSUInteger, AspectErrorCode) {
//    AspectErrorSelectorBlacklisted,                   /// Selectors like release, retain, autorelease are blacklisted.
//    AspectErrorDoesNotRespondToSelector,              /// Selector could not be found.
//    AspectErrorSelectorDeallocPosition,               /// When hooking dealloc, only AspectPositionBefore is allowed.
//    AspectErrorSelectorAlreadyHookedInClassHierarchy, /// Statically hooking the same method in subclasses is not allowed.
//    AspectErrorFailedToAllocateClassPair,             /// The runtime failed creating a class pair.
//    AspectErrorMissingBlockSignature,                 /// The block misses compile time signature info and can't be called.
//    AspectErrorIncompatibleBlockSignature,            /// The block signature does not match the method or is too large.
//
//    AspectErrorRemoveObjectAlreadyDeallocated = 100   /// (for removing) The object hooked is already deallocated.
//};

extern NSString *const KcAspectErrorDomain;

/// block的方法签名
NSMethodSignature *kc_blockMethodSignature(id block, NSError **error);

// MARK: - 总结👍
/*
 1.新建1个class继承自当前className， name: 前缀 + 当前className
    * 并把class的isa改为new class
 2.保存block
 3.新建method，name为 前缀 + method
    * imp为 origin imp
    * origin func的imp改为_objc_msgForward会走消息机制, 即会走forwardInvocation
        * 有替换imp的block就执行block
        * 没有替换的block，就执行原来的imp
 4.hook forwardInvocation
    * 并且也用一个新的方法保存了它的imp
 
 判断selector是否能hook
     1.黑名单(retain, release, autorelease, forwardInvocation:)不能hook
     2.dealloc只能在它执行之前添加操作
     3.没实现方法(instance method、class method)不能hook
     4.hook传入的self为objc - 可以hook(由于objc hook只影响自己, 不会影响其他的对象, so不存在super hook、自己hook的情况)
     5.hook传入的为Class - (影响这个class的所有对象)
        * 已经hook, 不能再hook
        * super已经hook了方法的话, 不能hook
        * 可以hook

 hook逻辑
    1.已经hook的直接返回
    2.对于meta, kvo的class，直接在自身上进行method swizzling
       * meta: hook的为class对象, 即传入的self对象 - 修改forwardInvocation的imp (影响范围: 所有class的对象)
       * KVO: hook的为isa, 即KVO新生成的类 - - 修改forwardInvocation的imp
    3.注册一个新的class(类似于KVO) --- className_Aspects_  (影响范围: 只是当前的对象) 👻
       * 将它的forwardInvocation方法imp指向__ASPECTS_ARE_BEING_CALLED__
       * 改对象的isa改为新class
 
 修改SEL
     1.改SEL的imp改为_objc_msgForward, 这样就会走消息机制方法
     2.新建aspect_原始方法, 用来保存origin方法的imp, 执行forwardInvocation的方法, 就能执行原始的imp
 
 KVO也是这个思路，重写了set方法，调用了didChangeValue
 */
