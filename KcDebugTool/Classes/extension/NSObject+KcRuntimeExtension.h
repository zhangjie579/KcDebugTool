//
//  NSObject+KcRuntimeExtension.h
//  OCTest
//
//  Created by samzjzhang on 2020/7/21.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "KcHookModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface KcProtocolMethodsConfigure : NSObject

@property (nonatomic) BOOL isContainSuper;
@property (nonatomic) BOOL isRequiredMethod;
@property (nonatomic) BOOL hasInstanceMethod;
@property (nonatomic) BOOL hasClassMethod;

/// 包含的话 -> true
@property (nonatomic, nullable) BOOL(^filterMethodBlock)(struct objc_method_description method);

// 黑白名单 method name
@property (nonatomic, copy, nullable) NSArray<NSString *> *blackMethods;
@property (nonatomic, copy, nullable) NSArray<NSString *> *whiteMethods;

// 黑白名单protocol name
@property (nonatomic, copy, nullable) NSArray<NSString *> *blackProtocols;
@property (nonatomic, copy, nullable) NSArray<NSString *> *whiteProtocols;

/// 默认配置 - 只有hasInstanceMethod为true
+ (instancetype)defaultConfigure;

@end

#pragma mark - 观察dealloc

@interface KcDeallocObserver : NSObject

@property (nonatomic) void(^deallocBlock)(void);

- (instancetype)initWithBlock:(void(^)(void))deallocBlock;

@end

@interface NSObject (KcRuntimeExtension)

+ (void)kc_hookSelectorName:(NSString *)selectorName swizzleSelectorName:(NSString *)swizzleSelectorName;

#pragma mark - 获取方法列表

/// 获取方法列表
+ (NSArray<NSString *> *)kc_instanceMethodListWithContainSuper:(BOOL)isContainSuper;

+ (NSArray<NSString *> *)kc_classMethodListWithContainSuper:(BOOL)isContainSuper;

+ (NSArray<NSString *> *)kc_instanceMethodListWithInfo:(KcMethodInfo *)info;

#pragma mark - protocol

/// 获取Protocol方法列表
+ (NSSet<NSString *> *)kc_protocolMethodListWithProtocol:(Protocol *)protocol
                                               configure:(KcProtocolMethodsConfigure *)configure;

#pragma mark - ivar

/// 当前class的ivar names
+ (NSArray<NSString *> *)kc_ivarListNoSuperClassWithClass:(Class)cls;

+ (NSArray<NSString *> *)kc_ivarListWithClass:(Class)cls;

- (NSArray<NSString *> *)kc_logAllIvars;

/// 根据内存偏移量求值
+ (id)kc_valueWithContentObjc:(NSObject *)objc offset:(UInt64)offset;

/// 求出ivar的address
- (UInt64)kc_ivarAddressWithName:(NSString *)ivarName;

/// log ivar的属性
/// 比如: char *value = *(char **)((uintptr_t)self + offset)
- (NSString *)kc_ivarInfoWithName:(NSString *)ivarName;

#pragma mark - dealloc

/// hook dealloc
+ (void)kc_hook_dealloc:(NSArray<NSString *> *)classNames block:(void(^)(KcHookAspectInfo *info))block;

+ (void)kc_hook_deallocWithBlock:(void(^)(KcHookAspectInfo *info))block;

- (KcDeallocObserver *)kc_deallocObserverWithBlock:(void(^)(void))block;


#pragma mark - help

/// 是否是元类
+ (BOOL)kc_isMetaClass:(id)object;
/// 是否是class
+ (BOOL)kc_isClass:(id)object;
/// 是否是swift class
+ (BOOL)kc_isSwiftClass:(id)objc;
/// 是否是swift值类型
+ (BOOL)kc_isSwiftValueWithObjc:(id)objc;
/// 是否是swift 对象
/// 注意⚠️: 不管是swift struct还是class强转NSObject都success
+ (BOOL)kc_isSwiftObjc:(id)objc;
/// 是否是自定义的class
+ (BOOL)kc_isCustomClass:(Class)cls;

/// 是类或者子类
- (BOOL)kc_isClassOrSubClass:(NSSet<NSString *> *)classNames;

/// 指针是否是一个objc对象
+ (BOOL)kc_isObjcObject:(const void *)inPtr;
/// 指针是否是一个objc对象
+ (BOOL)kc_isObjcObject:(const void *)inPtr
             allClasses:(_Nonnull const Class *_Nonnull)allClasses
             classCount:(int)classCount;

/// 默认的黑名单
+ (NSArray<NSString *> *)kc_defaultBlackSelectorName;

#pragma mark - 调试方法 dump

///// 所有方法(包括层级)
//+ (NSString *)kc_dump_allMethodDescription;
///// 所有自定义方法
//+ (NSString *)kc_dump_allCustomMethodDescription;
///// 某个class的方法描述
//+ (NSString *)kc_dump_methodDescriptionForClass:(Class)cls;
//
///// 所有属性的描述
//+ (NSString *)kc_dump_allPropertyDescription;
//+ (NSString *)kc_dump_propertyDescriptionForClass:(Class)cls;
//
///// 获取所有成员变量
//- (NSString *)kc_dump_allIvarDescription;
//- (NSString *)kc_dump_ivarDescriptionForClass:(Class)cls;

+ (id)kc_performSelector:(NSString *)selectorName;
- (id)kc_performSelector:(NSString *)selectorName;

@end

NS_ASSUME_NONNULL_END
