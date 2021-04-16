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

#pragma mark - dealloc

/// hook dealloc
+ (void)kc_hookDealloc:(NSArray<NSString *> *)classNames block:(void(^)(KcHookAspectInfo *info))block {
    [self kc_hookSelector:NSSelectorFromString(@"dealloc") classNames:classNames block:block];
}

- (KcDeallocObserver *)kc_deallocObserverWithBlock:(void(^)(void))block {
    KcDeallocObserver *observer = objc_getAssociatedObject(self, _cmd);
    if (!observer) {
        observer = [[KcDeallocObserver alloc] initWithBlock:^{
            if (block) {
                block();
            }
        }];
        objc_setAssociatedObject(self, _cmd, observer, OBJC_ASSOCIATION_COPY_NONATOMIC);
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

#pragma mark - 调试方法

/// 所有方法(包括层级)
+ (NSString *)kc_allMethods {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSString *description = [self performSelector:NSSelectorFromString(@"_methodDescription")];
    #pragma clang diagnostic pop
    NSLog(@"%@", description);
    return description;
}

/// 所有自定义方法
+ (NSString *)kc_allCustomMethods {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSString *description = [self performSelector:NSSelectorFromString(@"_shortMethodDescription")];
    #pragma clang diagnostic pop
    NSLog(@"%@", description);
    return description;
}

/// 获取所有成员变量
- (NSString *)kc_allIvars {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    // _ivarDescription
    NSString *description = [self performSelector:NSSelectorFromString(@"_ivarDescription")];
    #pragma clang diagnostic pop
    NSLog(@"%@", description);
    return description;
}

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
