//
//  KcHeapObjcManager.h
//  Pods
//
//  Created by 张杰 on 2023/9/6.
//  堆上对象

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KcHeapObjcManager : NSObject

+ (NSArray<id> *)instancesOfClass:(Class)cls;
/// 搜索这个class指针的所有对象
+ (NSArray<id> *)instancesOfClassAddress:(uintptr_t)classAddress;
+ (NSArray<id> *)instancesOfClassWithName:(NSString *)className;

+ (NSArray<id> *)instancesOfAllClassWithName:(NSString *)className;
+ (NSArray<id> *)instancesOfAllClass:(Class)cls;

+ (NSArray<id> *)subclassesOfClassWithName:(NSString *)className;

+ (NSArray<id> *)instancesOfClasses:(NSArray<Class> *)classes;
+ (NSArray<id> *)instancesOfClasses:(NSArray<Class> *)classes filterBlock:(BOOL(^ _Nullable)(id objc))filterBlock;

+ (void)enumerateLiveObjectsUsingBlock:(void (^)(__unsafe_unretained id object, __unsafe_unretained Class actualClass))block;

+ (NSArray<Class> *)getAllSubclasses:(Class)cls includeSelf:(BOOL)includeSelf;

/// 是否是堆对象
+ (BOOL)isHeapAddress:(uintptr_t)address;

/// 堆对象的信息
+ (nullable NSString *)heapObjcInfoWithAddress:(uintptr_t)address;

@end

NS_ASSUME_NONNULL_END
