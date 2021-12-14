//
//  NSObject+KcRuntimeExtension.m
//  OCTest
//
//  Created by samzjzhang on 2020/7/21.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "NSObject+KcRuntimeExtension.h"
#import <objc/message.h>
#import "NSObject+KcMethodExtension.h"
#import <malloc/malloc.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>

#if __arm64__
#define Kc_ISA_MASK        0x0000000ffffffff8ULL
#define Kc_ISA_MAGIC_MASK  0x000003f000000001ULL
#define Kc_ISA_MAGIC_VALUE 0x000001a000000001ULL
#elif __x86_64__
#define Kc_ISA_MASK        0x00007ffffffffff8ULL
#define Kc_ISA_MAGIC_MASK  0x001f800000000001ULL
#define Kc_ISA_MAGIC_VALUE 0x001d800000000001ULL
#else
//#error unknown architecture for packed isa
#define Kc_ISA_MASK         0
#define Kc_ISA_MAGIC_MASK   0
#define Kc_ISA_MAGIC_VALUE  0
#endif

@implementation NSObject (KcRuntimeExtension)

/// 是否是自定义的class
bool kc_classIsCustomClass(Class aClass);

/// hook
+ (void)kc_hookSelectorName:(NSString *)selectorName swizzleSelectorName:(NSString *)swizzleSelectorName {
    Method originMethod = class_getInstanceMethod(self, NSSelectorFromString(selectorName));
    Method swizzleMethod = class_getInstanceMethod(self, NSSelectorFromString(swizzleSelectorName));
    if (!originMethod || !swizzleMethod) {
        return;
    }
    
    if (class_addMethod(self, NSSelectorFromString(selectorName), method_getImplementation(swizzleMethod), method_getTypeEncoding(swizzleMethod))) {
        class_replaceMethod(self, NSSelectorFromString(swizzleSelectorName), method_getImplementation(originMethod), method_getTypeEncoding(originMethod));
    } else {
        method_exchangeImplementations(originMethod, swizzleMethod);
    }
}

#pragma mark - 获取方法列表

/// 获取方法列表
+ (NSArray<NSString *> *)kc_instanceMethodListWithContainSuper:(BOOL)isContainSuper {
    NSMutableSet<NSString *> *methodList = [[NSMutableSet alloc] init];
    
    if (isContainSuper) {
        Class superClass = class_getSuperclass(self);
        while (superClass && kc_classIsCustomClass(superClass)) { // ![superClass isEqual:[NSObject class]]
            NSArray<NSString *> *superMethodList = [superClass kc_instanceMethodListWithContainSuper:isContainSuper];
            [methodList addObjectsFromArray:superMethodList];
            
            superClass = class_getSuperclass(superClass);
        }
    }
    
     unsigned int count;
     Method *methods = class_copyMethodList(self, &count);
    
     for (NSInteger i = 0; i < count; i++) {
         NSString *name = NSStringFromSelector(method_getName(methods[i]));
         if (!name || [name isEqualToString:@""]) {
             continue;
         }
         [methodList addObject:name];
     }
     
     free(methods);
     
     return [methodList allObjects];
}

+ (NSArray<NSString *> *)kc_classMethodListWithContainSuper:(BOOL)isContainSuper {
    Class cls;
    cls = class_isMetaClass(self) ? self : object_getClass(self);
    return [cls kc_instanceMethodListWithContainSuper:isContainSuper];
}

+ (NSArray<NSString *> *)kc_instanceMethodListWithInfo:(KcMethodInfo *)info {
    NSArray<NSString *> *methods = [self kc_instanceMethodListWithContainSuper:info.isHookSuperClass];
    NSMutableSet<NSString *> *results = [NSMutableSet setWithArray:methods];
    
    // 黑名单
    [results minusSet:[NSSet setWithArray:[KcMethodInfo defaultBlackSelectorNames]]];
    if (info.blackSelectors) {
        [results minusSet:[NSSet setWithArray:info.blackSelectors]];
    }
    
    // get方法
    NSArray<NSString *> *ivarList = [self kc_ivarListWithClass:self];
    if (!info.isHookGetMethod) {
        [results minusSet:[NSSet setWithArray:ivarList]];
    }
    
    // set方法
    if (!info.isHookSetMethod) {
        NSMutableSet<NSString *> *setMethods = [NSMutableSet set];
        for (NSInteger i = 0; i < ivarList.count; i++) {
            NSString *ivarName = ivarList[i];
            [setMethods addObject:[NSString stringWithFormat:@"set%@%@:", [[ivarName substringToIndex:1] uppercaseString], [ivarName substringFromIndex:1]]];
        }
        [results minusSet:setMethods];
    }
    
    // 白名单
    if (info.whiteSelectors) {
        [results addObjectsFromArray:info.whiteSelectors];
    }
    
    return results.allObjects;
}

#pragma mark - protocol

/// 获取Protocol方法列表
+ (NSSet<NSString *> *)kc_protocolMethodListWithProtocol:(Protocol *)protocol
                                               configure:(KcProtocolMethodsConfigure *)configure {
    NSMutableSet<NSString *> *selectors = [NSMutableSet set];
    
    // 遍历protocol方法列表
    void(^forEachProtocolMethods)(BOOL isInstanceMethod) = ^(BOOL isInstanceMethod) {
        unsigned int protocolMethodCount = 0;
        struct objc_method_description *pMethods = protocol_copyMethodDescriptionList(protocol, configure.isRequiredMethod, isInstanceMethod, &protocolMethodCount);
        
        for (unsigned int i = 0; i < protocolMethodCount; ++i) {
            struct objc_method_description method = pMethods[i];
            NSString *methodName = NSStringFromSelector(method.name);
            
            if (configure.filterMethodBlock && configure.filterMethodBlock(method)) {
                [selectors addObject:methodName];
            } else if ([configure.whiteMethods containsObject:methodName]) {
                [selectors addObject:methodName];
            } else if (![configure.blackMethods containsObject:methodName]) {
                [selectors addObject:methodName];
            }
        }
                
        free(pMethods);
    };
    
    BOOL containProtocol = false;
    if ([configure.whiteProtocols containsObject:NSStringFromProtocol(protocol)] ||
        ![configure.blackProtocols containsObject:NSStringFromProtocol(protocol)]) {
        containProtocol = true;
    }
    
    if (containProtocol) {
        if (configure.hasInstanceMethod) {
            forEachProtocolMethods(true);
        }
        if (configure.hasClassMethod) {
            forEachProtocolMethods(false);
        }
    }
    
    if (configure.isContainSuper) {
        unsigned int numberOfBaseProtocols = 0;
        Protocol * __unsafe_unretained * pSubprotocols = protocol_copyProtocolList(protocol, &numberOfBaseProtocols);

        for (unsigned int i = 0; i < numberOfBaseProtocols; ++i) {
            [selectors unionSet:[self kc_protocolMethodListWithProtocol:pSubprotocols[i] configure:configure]];
        }
        
        free(pSubprotocols);
    }
    
    return selectors;
}

//+ (NSArray<NSString *> *)kc_instanceMethodListWithInfo:(KcMethodInfo *)info {
//    NSArray<NSString *> *methods = [self kc_instanceMethodListWithContainSuper:info.isHookSuperClass];
//    NSMutableArray<NSString *> *results = [NSMutableArray arrayWithArray:methods];
//
//    // 黑名单
//    [results removeObjectsInArray:[KcMethodInfo defaultBlackSelectorNames]];
//    if (info.blackSelectors) {
//        [results removeObjectsInArray:info.blackSelectors];
//    }
//
//    // get方法
//    NSArray<NSString *> *ivarList = [self kc_ivarListWithClass:self];
//    if (!info.isHookGetMethod) {
//        [results removeObjectsInArray:ivarList];
//    }
//
//    // set方法
//    if (!info.isHookSetMethod) {
//        NSMutableSet<NSString *> *setMethods = [NSMutableSet set];
//        for (NSInteger i = 0; i < ivarList.count; i++) {
//            NSString *ivarName = ivarList[i];
//            [setMethods addObject:[NSString stringWithFormat:@"set%@%@:", [[ivarName substringToIndex:1] uppercaseString], [ivarName substringFromIndex:1]]];
//        }
//        [results removeObjectsInArray:setMethods.allObjects];
//    }
//
//    // 白名单
//    if (info.whiteSelectors) {
//        [results addObjectsFromArray:info.whiteSelectors];
//    }
//
//    return [NSSet setWithArray:results].allObjects;
//}

#pragma mark - ivar

/// 当前class的ivar names
+ (NSArray<NSString *> *)kc_ivarListNoSuperClassWithClass:(Class)cls {
    NSMutableArray<NSString *> *ivarNames = [[NSMutableArray alloc] init];
    unsigned int ivarCount;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);

    for (NSInteger i = 0; i < ivarCount; i++) {
        NSString *name = [NSString stringWithUTF8String:ivar_getName(ivars[i])];
        if (!name || [name isEqualToString:@""]) {
         continue;
        }
        if ([name hasPrefix:@"_"]) {
         name = [name substringFromIndex:1];
        }
        [ivarNames addObject:name];
    }

    free(ivars);
     
    return ivarNames.copy;
}

+ (NSArray<NSString *> *)kc_ivarListWithClass:(Class)cls {
     NSMutableSet<NSString *> *ivarNames = [[NSMutableSet alloc] init];
     
     Class superClass = class_getSuperclass(cls);
     while (superClass && kc_classIsCustomClass(superClass)) { // ![superClass isEqual:[NSObject class]]
         NSArray<NSString *> *superIvarNames = [self kc_ivarListWithClass:superClass];
         [ivarNames addObjectsFromArray:superIvarNames];
         
         superClass = class_getSuperclass(superClass);
     }
    
    NSArray<NSString *> *ivarList = [self kc_ivarListNoSuperClassWithClass:cls];
    [ivarNames addObjectsFromArray:ivarList];
     
     return [ivarNames allObjects];
}

- (NSArray<NSString *> *)kc_logAllIvars {
    NSMutableArray<NSString *> *result = @[].mutableCopy;
    unsigned int count;
    // 遍历ivar
    Ivar *ivars = class_copyIvarList([self class], &count);
    for (unsigned int i = 0; i < count; i++) {
        Ivar ivar = ivars[i];

        const char *name = ivar_getName(ivar);
        const char *type = ivar_getTypeEncoding(ivar);
        ptrdiff_t offset = ivar_getOffset(ivar);

        if (strncmp(type, @encode(char), 1) == 0) {
            char value = *(char *)((uintptr_t)self + offset);
            [result addObject: [NSString stringWithFormat:@"%s = %c", name, value]];
        }
        else if (strncmp(type, @encode(int), 1) == 0) {
            int value = *(int *)((uintptr_t)self + offset);
            [result addObject: [NSString stringWithFormat:@"%s = %d", name, value]];
        }
        else if (strncmp(type, @encode(short), 1) == 0) {
            short value = *(short *)((uintptr_t)self + offset);
            [result addObject: [NSString stringWithFormat:@"%s = %hd", name, value]];
        }
        else if (strncmp(type, @encode(long), 1) == 0) {
            long value = *(long *)((uintptr_t)self + offset);
            [result addObject: [NSString stringWithFormat:@"%s = %ld", name, value]];
        }
        else if (strncmp(type, @encode(long long), 1) == 0) {
            long long value = *(long long *)((uintptr_t)self + offset);
            [result addObject: [NSString stringWithFormat:@"%s = %lld", name, value]];
        }
        else if (strncmp(type, @encode(unsigned char), 1) == 0) {
            unsigned char value = *(unsigned char *)((uintptr_t)self + offset);
            [result addObject: [NSString stringWithFormat:@"%s = %c", name, value]];
        }
        else if (strncmp(type, @encode(unsigned int), 1) == 0) {
            unsigned int value = *(unsigned int *)((uintptr_t)self + offset);
            [result addObject: [NSString stringWithFormat:@"%s = %u", name, value]];
        }
        else if (strncmp(type, @encode(unsigned short), 1) == 0) {
            unsigned short value = *(unsigned short *)((uintptr_t)self + offset);
            [result addObject: [NSString stringWithFormat:@"%s = %hu", name, value]];
        }
        else if (strncmp(type, @encode(unsigned long), 1) == 0) {
            unsigned long value = *(unsigned long *)((uintptr_t)self + offset);
            [result addObject: [NSString stringWithFormat:@"%s = %lu", name, value]];
        }
        else if (strncmp(type, @encode(unsigned long long), 1) == 0) {
            unsigned long long value = *(unsigned long long *)((uintptr_t)self + offset);
            [result addObject: [NSString stringWithFormat:@"%s = %llu", name, value]];
        }
        else if (strncmp(type, @encode(float), 1) == 0) {
            float value = *(float *)((uintptr_t)self + offset);
            [result addObject: [NSString stringWithFormat:@"%s = %f", name, value]];
        }
        else if (strncmp(type, @encode(double), 1) == 0) {
            double value = *(double *)((uintptr_t)self + offset);
            [result addObject: [NSString stringWithFormat:@"%s = %e", name, value]];
        }
        else if (strncmp(type, @encode(bool), 1) == 0) {
            bool value = *(bool *)((uintptr_t)self + offset);
            [result addObject: [NSString stringWithFormat:@"%s = %d", name, value]];
        }
        else if (strncmp(type, @encode(char *), 1) == 0) {
            char * value = *(char * *)((uintptr_t)self + offset);
            [result addObject: [NSString stringWithFormat:@"%s = %s", name, value]];
        }
        else if (strncmp(type, @encode(id), 1) == 0) {
            id value = object_getIvar(self, ivar);
            [result addObject: [NSString stringWithFormat:@"%s = %@", name, value]];
        }
        else if (strncmp(type, @encode(Class), 1) == 0) {
            id value = object_getIvar(self, ivar);
            [result addObject: [NSString stringWithFormat:@"%s = %@", name, value]];
        }
        // todo
        // SEL
        // struct
        // array
        // union
        // bit
        // field of num bits
        // pointer to type
    }
    free(ivars);
    return [result copy];
}

/// 求出ivar的address
- (UInt64)kc_ivarAddressWithName:(NSString *)ivarName {
    UInt64 address = -1;
    
    NSString *propertyName = ivarName.copy;
    if ([propertyName hasPrefix:@"_"]) {
        propertyName = [propertyName substringFromIndex:1];
    }
    
    unsigned int count;
    // 遍历ivar
    Ivar *ivars = class_copyIvarList([self class], &count);
    for (unsigned int i = 0; i < count; i++) {
        Ivar ivar = ivars[i];

        NSString *name = @(ivar_getName(ivar));
        if ([name hasPrefix:@"_"]) {
            name = [name substringFromIndex:1];
        }
        
//        const char *type = ivar_getTypeEncoding(ivar);
        ptrdiff_t offset = ivar_getOffset(ivar);
        
        if ([propertyName isEqualToString:name]) {
            address = (UInt64)self + offset;
            break;
        }
    }
    
    free(ivars);
    
    return address;
}

/// 根据内存偏移量求值
+ (id)kc_valueWithContentObjc:(NSObject *)objc offset:(UInt64)offset {
    void *pointer = *(void **)((UInt64)objc + offset);
    
    return (__bridge id)pointer;
}

/// log ivar的属性
/// 比如: char *value = *(char **)((uintptr_t)self + offset)
- (NSString *)kc_ivarInfoWithName:(NSString *)ivarName {
    NSMutableString *mutableString = [NSMutableString string];
    
    if ([ivarName hasPrefix:@"_"]) {
        ivarName = [ivarName substringFromIndex:1];
    }
    
    unsigned int count;
    // 遍历ivar
    Ivar *ivars = class_copyIvarList([self class], &count);
    for (unsigned int i = 0; i < count; i++) {
        Ivar ivar = ivars[i];

        NSString *name = @(ivar_getName(ivar));
        if ([name hasPrefix:@"_"]) {
            name = [name substringFromIndex:1];
        }
        
        if (![ivarName isEqualToString:name]) {
            continue;
        }
        
        const char *type = ivar_getTypeEncoding(ivar);
        ptrdiff_t offset = ivar_getOffset(ivar);

        [mutableString appendFormat:@"name: %@, type: %s, offset: %td, address: %lu ", name, type, offset, (uintptr_t)self + offset];
        
        if (strncmp(type, @encode(char), 1) == 0) {
            char value = *(char *)((uintptr_t)self + offset);
            [mutableString appendFormat:@"value = %c", value];
        }
        else if (strncmp(type, @encode(int), 1) == 0) {
            int value = *(int *)((uintptr_t)self + offset);
            [mutableString appendFormat:@"value = %d", value];
        }
        else if (strncmp(type, @encode(short), 1) == 0) {
            short value = *(short *)((uintptr_t)self + offset);
            [mutableString appendFormat:@"value = %hd", value];
        }
        else if (strncmp(type, @encode(long), 1) == 0) {
            long value = *(long *)((uintptr_t)self + offset);
            [mutableString appendFormat:@"value = %ld", value];
        }
        else if (strncmp(type, @encode(long long), 1) == 0) {
            long long value = *(long long *)((uintptr_t)self + offset);
            [mutableString appendFormat:@"value = %lld", value];
        }
        else if (strncmp(type, @encode(unsigned char), 1) == 0) {
            unsigned char value = *(unsigned char *)((uintptr_t)self + offset);
            [mutableString appendFormat:@"value = %c", value];
        }
        else if (strncmp(type, @encode(unsigned int), 1) == 0) {
            unsigned int value = *(unsigned int *)((uintptr_t)self + offset);
            [mutableString appendFormat:@"value = %u", value];
        }
        else if (strncmp(type, @encode(unsigned short), 1) == 0) {
            unsigned short value = *(unsigned short *)((uintptr_t)self + offset);
            [mutableString appendFormat:@"value = %hu", value];
        }
        else if (strncmp(type, @encode(unsigned long), 1) == 0) {
            unsigned long value = *(unsigned long *)((uintptr_t)self + offset);
            [mutableString appendFormat:@"value = %lu", value];
        }
        else if (strncmp(type, @encode(unsigned long long), 1) == 0) {
            unsigned long long value = *(unsigned long long *)((uintptr_t)self + offset);
            [mutableString appendFormat:@"value = %llu", value];
        }
        else if (strncmp(type, @encode(float), 1) == 0) {
            float value = *(float *)((uintptr_t)self + offset);
            [mutableString appendFormat:@"value = %f", value];
        }
        else if (strncmp(type, @encode(double), 1) == 0) {
            double value = *(double *)((uintptr_t)self + offset);
            [mutableString appendFormat:@"value = %e", value];
        }
        else if (strncmp(type, @encode(bool), 1) == 0) {
            bool value = *(bool *)((uintptr_t)self + offset);
            [mutableString appendFormat:@"value = %d", value];
        }
        else if (strncmp(type, @encode(char *), 1) == 0) {
            char * value = *(char * *)((uintptr_t)self + offset);
            [mutableString appendFormat:@"value = %s", value];
        }
        else if (strncmp(type, @encode(id), 1) == 0) {
            id value = object_getIvar(self, ivar);
            [mutableString appendFormat:@"value = %@", value];
        }
        else if (strncmp(type, @encode(Class), 1) == 0) {
            id value = object_getIvar(self, ivar);
            [mutableString appendFormat:@"value = %@", value];
        }
        // todo
        // SEL
        // struct
        // array
        // union
        // bit
        // field of num bits
        // pointer to type
        
        break;
    }
    free(ivars);
    return mutableString.copy;
}

#pragma mark - dealloc

/// hook dealloc
+ (void)kc_hook_dealloc:(NSArray<NSString *> *)classNames block:(void(^)(KcHookAspectInfo *info))block {
    [self kc_hook_selector:NSSelectorFromString(@"dealloc") classNames:classNames block:block];
}

+ (void)kc_hook_deallocWithBlock:(void(^)(KcHookAspectInfo *info))block {
    id<KcAspectable> manager = KcHookTool.manager;
    [manager kc_hookWithObjc:self selector:NSSelectorFromString(@"dealloc") withOptions:KcAspectTypeBefore usingBlock:block error:nil];
}

- (KcDeallocObserver *)kc_deallocObserverWithBlock:(void(^)(void))block {
    KcDeallocObserver *observer = objc_getAssociatedObject(self, _cmd);
    if (!observer) {
        observer = [[KcDeallocObserver alloc] initWithBlock:^{
            if (block) {
                block();
            }
        }];
        objc_setAssociatedObject(self, _cmd, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return observer;
}

#pragma mark - help

/// 是否是元类
+ (BOOL)kc_isMetaClass:(id)object {
    return class_isMetaClass(object);
}

/// 是否是class
+ (BOOL)kc_isClass:(id)object {
    return object_isClass(object);
}

/// 是否是swift class (不包括值类型struct、enum)
+ (BOOL)kc_isSwiftClass:(id)objc {
    NSString *className = NSStringFromClass([objc class]);
    if (!className) {
        return YES;
    }
    
    // _TtGC7RxCocoa13GestureTargetCSo22UITapGestureRecognizer_  这种情况没有处理⚠️
    BOOL isSwiftClass = [className containsString:@"."];
    return isSwiftClass;
}

/// 是否是swift值类型
+ (BOOL)kc_isSwiftValueWithObjc:(id)objc {
    NSString *className = NSStringFromClass([objc class]);
    if (!className) {
        return NO;
    }
    
    if ([className isEqualToString:@"__SwiftValue"]) { // struct、enum、tuple
        return YES;
    }
    
    return NO;
}

/// 是否是swift 对象
/// 注意⚠️: 不管是swift struct还是class强转NSObject都success
+ (BOOL)kc_isSwiftObjc:(id)objc {
    if ([self kc_isSwiftValueWithObjc:objc]) {
        return YES;
    }
    
    if ([self kc_isSwiftClass:objc]) {
        return YES;
    }
    
    return NO;
}

/// 是否是自定义的class
+ (BOOL)kc_isCustomClass:(Class)cls {
    // var/containers/Bundle/Application/CB0D354B-DD08-4845-A084-A22FF01097FE/Example.app
    NSString *mainBundlePath = [NSBundle mainBundle].bundlePath;
    //var/containers/Bundle/Application/CB0D354B-DD08-4845-A084-A22FF01097FE/Example.app/Frameworks/Baymax.framework
    NSString *clsBundlePath = [NSBundle bundleForClass:cls].bundlePath;
    
    // 如果是动态库的话, 不会在app内
    
    return cls && mainBundlePath && clsBundlePath && [clsBundlePath hasPrefix:mainBundlePath];
}

/// 是否是自定义的class
bool kc_classIsCustomClass(Class aClass) {
    NSCParameterAssert(aClass);
    if (!aClass) {
        return false;
    }
    
//    NSString *bundlePath = [[NSBundle bundleForClass:aClass] bundlePath];
//    if ([bundlePath rangeOfString:@"/System/Library/"].length != 0) {
//        return false;
//    }
//    if ([bundlePath rangeOfString:@"/usr/"].length != 0) {
//        return false;
//    }
//    return true;
    return [NSBundle bundleForClass:aClass] == NSBundle.mainBundle;
}

/// 是类或者子类
- (BOOL)kc_isClassOrSubClass:(NSSet<NSString *> *)classNames {
    for (NSString *className in classNames) {
        if ([self isKindOfClass:NSClassFromString(className)]) {
            return true;
        }
    }
    return false;
}

/// 指针是否是一个objc对象
+ (BOOL)kc_isObjcObject:(const void *)inPtr {
    unsigned int classCount;
    Class *allClasses = objc_copyClassList(&classCount);
    
    BOOL isObjc = [NSObject kc_isObjcObject:inPtr allClasses:allClasses classCount:classCount];
    
    free(allClasses);
    
    return isObjc;
}

// 参考: https://blog.timac.org/2016/1124-testing-if-an-arbitrary-pointer-is-a-valid-objective-c-object/
// 注意：去除了`IsObjcTaggedPointer`的判断
/**
 Test if a pointer is an Objective-C object (指针是否是一个objc对象)

 @param inPtr is the pointer to check
 @return true if the pointer is an Objective-C object
 */
+ (BOOL)kc_isObjcObject:(const void *)inPtr
             allClasses:(const Class *)allClasses
             classCount:(int)classCount {
    if (classCount <= 0 || allClasses == nil) {
        return false;
    }
    
    //
    // NULL pointer is not an Objective-C object
    //
    if (inPtr == NULL) {
        return false;
    }

    //
    // Check for tagged pointers
    //
    //    if(IsObjcTaggedPointer(inPtr, NULL))
    //    {
    //        return true;
    //    }

    // Check if the pointer is aligned 指针对齐
    if (((uintptr_t)inPtr % sizeof(uintptr_t)) != 0) {
        return false;
    }

    // From LLDB:
    // Objective-C runtime has a rule that pointers in a class_t will only have bits 0 thru 46 set
    // so if any pointer has bits 47 thru 63 high we know that this is not a valid isa
    // See http://llvm.org/svn/llvm-project/lldb/trunk/examples/summaries/cocoa/objc_runtime.py
    if (((uintptr_t)inPtr & 0xFFFF800000000000) != 0) {
        return false;
    }

    // Check if the memory is valid and readable
    if (!isValidReadableMemory(inPtr)) {
        return false;
    }

    //
    // Get the Class from the pointer
    // From http://www.sealiesoftware.com/blog/archive/2013/09/24/objc_explain_Non-pointer_isa.html :
    // If you are writing a debugger-like tool, the Objective-C runtime exports some variables
    // to help decode isa fields. objc_debug_isa_class_mask describes which bits are the class pointer:
    // (isa & class_mask) == class pointer.
    // objc_debug_isa_magic_mask and objc_debug_isa_magic_value describe some bits that help
    // distinguish valid isa fields from other invalid values:
    // (isa & magic_mask) == magic_value for isa fields that are not raw class pointers.
    // These variables may change in the future so do not use them in application code.
    //
    //
    uintptr_t isa = (*(uintptr_t *)inPtr);
    Class ptrClass = NULL;

    if ((isa & ~Kc_ISA_MASK) == 0) {
        ptrClass = (__bridge Class)(void *)isa;
    } else {
        // jerrychu: 即使是non-pointer isa, isa & isa_magic_mask == isa_magic_value 条件也不成立，先取消判断。
        // isa & isa_magic_mask != isa_magic_value
        ptrClass = (__bridge Class)(void *)(isa & Kc_ISA_MASK);
//        if ((isa & Kc_ISA_MAGIC_MASK) == Kc_ISA_MAGIC_VALUE) {
//            ptrClass = (Class)(isa & Kc_ISA_MASK);
//        } else {
//            ptrClass = (Class)isa;
//        }
    }

    if (ptrClass == NULL) {
        return false;
    }

    // Verifies that the found Class is a known class.
    bool isKnownClass = false;
    for (int i = 0; i < classCount; i++) {
        if (allClasses[i] == ptrClass) {
            isKnownClass = true;
            break;
        }
    }

    if (!isKnownClass) {
        return false;
    }

    // From Greg Parker
    // https://twitter.com/gparker/status/801894068502433792
    // You can filter out some false positives by checking malloc_size(obj) >= class_getInstanceSize(cls).
    size_t pointerSize = malloc_size(inPtr);
    if (pointerSize > 0 && pointerSize < class_getInstanceSize(ptrClass)) {
        return false;
    }

    return true;
}

/**
 Test if the pointer points to readable and valid memory.

 @param inPtr is the pointer
 @return true if the pointer points to readable and valid memory.
 */
static bool isValidReadableMemory(const void *inPtr) {
    kern_return_t error = KERN_SUCCESS;

    // Check for read permissions
    bool hasReadPermissions = false;

    vm_size_t vmsize;
    vm_address_t address = (vm_address_t)inPtr;
    vm_region_basic_info_data_t info;
    mach_msg_type_number_t info_count = VM_REGION_BASIC_INFO_COUNT_64;

    memory_object_name_t object;

    error = vm_region_64(mach_task_self(), &address, &vmsize, VM_REGION_BASIC_INFO, (vm_region_info_t)&info, &info_count, &object);
    if(error != KERN_SUCCESS) {
        // vm_region/vm_region_64 returned an error
        hasReadPermissions = false;
    } else {
        hasReadPermissions = (info.protection & VM_PROT_READ);
    }

    if(!hasReadPermissions) {
        return false;
    }

    // Read the memory
    vm_offset_t readMem = 0;
    mach_msg_type_number_t size = 0;
    error = vm_read(mach_task_self(), (vm_address_t)inPtr, sizeof(uintptr_t), &readMem, &size);
    if(error != KERN_SUCCESS) {
        // vm_read returned an error
        return false;
    }

    return true;
}

#pragma mark - 调试方法
// (lldb) image lookup -rn NSObject\(IvarDescription\)

///// 所有方法(包括层级)
//+ (NSString *)kc_dump_allMethodDescription {
//    return [self kc_performSelector:@"_methodDescription"];
//}
//
///// 所有自定义方法
//+ (NSString *)kc_dump_allCustomMethodDescription {
//    return [self kc_performSelector:@"_shortMethodDescription"];
//}
//
///// 某个class的方法描述
//+ (NSString *)kc_dump_methodDescriptionForClass:(Class)cls {
//    #pragma clang diagnostic push
//    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
//    NSString *description = [self performSelector:NSSelectorFromString(@"__methodDescriptionForClass:") withObject:cls];
//    #pragma clang diagnostic pop
//    return description;
//}
//
///// 所有属性的描述
//+ (NSString *)kc_dump_allPropertyDescription {
//    return [self kc_performSelector:@"_propertyDescription"];
//}
//
//+ (NSString *)kc_dump_propertyDescriptionForClass:(Class)cls {
//    #pragma clang diagnostic push
//    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
//    NSString *description = [self performSelector:NSSelectorFromString(@"__propertyDescriptionForClass:") withObject:cls];
//    #pragma clang diagnostic pop
//    return description;
//}
//
///// 获取所有成员变量
//- (NSString *)kc_dump_allIvarDescription {
//    return [self kc_performSelector:@"_ivarDescription"];
//}
//
//- (NSString *)kc_dump_ivarDescriptionForClass:(Class)cls {
//    #pragma clang diagnostic push
//    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
//    NSString *description = [self performSelector:NSSelectorFromString(@"__ivarDescriptionForClass:") withObject:cls];
//    #pragma clang diagnostic pop
//    return description;
//}

+ (id)kc_performSelector:(NSString *)selectorName {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [self performSelector:NSSelectorFromString(selectorName)];
    #pragma clang diagnostic pop
}

- (id)kc_performSelector:(NSString *)selectorName {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [self performSelector:NSSelectorFromString(selectorName)];
    #pragma clang diagnostic pop
}

/// 默认的黑名单
+ (NSArray<NSString *> *)kc_defaultBlackSelectorName {
    return @[
        @".cxx_construct",
        @".cxx_destruct",
        @"dealloc",
        @"init",
        @"initWithFrame:",
        @"initWithCoder:",
        @"encodeWithCoder:",
    ];
}

@end

#pragma mark - KcProtocolMethodsConfigure

@implementation KcProtocolMethodsConfigure

/// 默认配置 - 只有hasInstanceMethod为true
+ (instancetype)defaultConfigure {
    KcProtocolMethodsConfigure *configure = [[KcProtocolMethodsConfigure alloc] init];
    configure.isContainSuper = false;
    configure.isRequiredMethod = false;
    configure.hasInstanceMethod = true;
    configure.hasClassMethod = false;
    
    return configure;
}

@end

#pragma mark - KcDeallocObserver

@implementation KcDeallocObserver

- (instancetype)initWithBlock:(void(^)(void))deallocBlock {
    if (self = [super init]) {
        self.deallocBlock = deallocBlock;
    }
    return self;
}

- (void)dealloc {
    if (self.deallocBlock) {
        self.deallocBlock();
    }
}

@end
