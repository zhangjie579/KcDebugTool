//
//  KC_NSZombie_Objc.m
//  KcDebugTool
//
//  Created by 张杰 on 2023/9/18.
//

#import "KC_NSZombie_Objc.h"
#import <objc/message.h>

@implementation KC_NSZombie_Objc

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    NSMethodSignature* sig = [super methodSignatureForSelector:@selector(init)];
    return sig;
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    // 让它崩溃
    abort();
}

+ (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    NSMethodSignature* sig = [super methodSignatureForSelector:@selector(alloc)];
    return sig;
}

+ (void)forwardInvocation:(NSInvocation *)anInvocation {
    // 让它崩溃
    abort();
}

/// 对象所需的size
+ (NSInteger)zombieInstanceSize {
    NSInteger size = class_getInstanceSize(self);
    return size < 16 ? 16 : size;
}

- (Class)class {
    [self kc_default_handle];
    return nil;
}

+ (Class)class {
    [self kc_default_handle];
    return nil;
}

- (BOOL)isEqual:(id)object {
    [self kc_default_handle];
    return false;
}

- (id)performSelector:(SEL)aSelector {
    [self kc_default_handle];
    return nil;
}
- (id)performSelector:(SEL)aSelector withObject:(id)object {
    [self kc_default_handle];
    return nil;
}

- (id)performSelector:(SEL)aSelector withObject:(id)object1 withObject:(id)object2 {
    [self kc_default_handle];
    return nil;
}

- (BOOL)isProxy {
    [self kc_default_handle];
    return false;
}

- (BOOL)isKindOfClass:(Class)aClass {
    [self kc_default_handle];
    return false;
}

- (BOOL)isMemberOfClass:(Class)aClass {
    [self kc_default_handle];
    return false;
}

- (BOOL)conformsToProtocol:(Protocol *)aProtocol {
    [self kc_default_handle];
    return false;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    [self kc_default_handle];
    return false;
}

- (id)copy {
    [self kc_default_handle];
    return nil;
}

- (id)mutableCopy {
    [self kc_default_handle];
    return nil;
}

- (void)kc_default_handle {
    abort();
    
}

+ (void)kc_default_handle {
    abort();
}

@end
