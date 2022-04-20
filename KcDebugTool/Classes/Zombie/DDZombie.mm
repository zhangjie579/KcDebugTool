////  HYZombie.m
//  DDZombieDetector
//
//  Created by Alex Ting on 2018/7/14.
//  Copyright © 2018年 Alex. All rights reserved.
//

#if __has_feature(objc_arc)
#error This file must be compiled without ARC. Use -fno-objc-arc flag.
#endif

#import "DDZombie.h"
#import "DDZombieMonitor.h"
#import "DDThreadStack.h"

#import <objc/runtime.h>

@interface DDZombie ()

@property (nonatomic, assign)DDThreadStack *threadStack;

@end

@implementation DDZombie

+ (Class)zombieIsa
{
    return [self class];
}

/// 对象所需的size
+ (NSInteger)zombieInstanceSize
{
    return class_getInstanceSize([DDZombie zombieIsa]);
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    @autoreleasepool {
        DDThreadStack* zombieStack = hy_getCurrentStack();
        [self handleZombieWithSelector:NSStringFromSelector(aSelector) zombieStack:zombieStack deallocStack:self.threadStack];
        delete zombieStack;
    }
    return nil;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    NSMethodSignature* sig = [super methodSignatureForSelector:@selector(doNothing)];
    return sig;
}

- (void)doNothing
{
    NSLog(@"我只是保护一下crash，什么也不干");
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
    [self doNothing];
}

-(void)dealloc {
    @autoreleasepool {
        DDThreadStack* zombieStack = hy_getCurrentStack();
        [self handleZombieWithSelector:NSStringFromSelector(_cmd) zombieStack:zombieStack deallocStack:self.threadStack];
        delete zombieStack;
    }
    [super dealloc];
}

-(instancetype)retain
{
    @autoreleasepool {
        DDThreadStack* zombieStack = hy_getCurrentStack();
        [self handleZombieWithSelector:NSStringFromSelector(_cmd) zombieStack:zombieStack deallocStack:self.threadStack];
        delete zombieStack;
    }
    return nil;
}

- (id)copy
{
    @autoreleasepool {
        DDThreadStack* zombieStack = hy_getCurrentStack();
        [self handleZombieWithSelector:NSStringFromSelector(_cmd) zombieStack:zombieStack deallocStack:self.threadStack];
        delete zombieStack;
    }
    return nil;
}

- (id)mutableCopy
{
    @autoreleasepool {
        DDThreadStack* zombieStack = hy_getCurrentStack();
        [self handleZombieWithSelector:NSStringFromSelector(_cmd) zombieStack:zombieStack deallocStack:self.threadStack];
        delete zombieStack;
    }
    return nil;
}

-(oneway void)release{
    @autoreleasepool {
        DDThreadStack* zombieStack = hy_getCurrentStack();
        [self handleZombieWithSelector:NSStringFromSelector(_cmd) zombieStack:zombieStack deallocStack:self.threadStack];
        delete zombieStack;
    }
}

- (instancetype)autorelease{
    @autoreleasepool {
        DDThreadStack* zombieStack = hy_getCurrentStack();
        [self handleZombieWithSelector:NSStringFromSelector(_cmd) zombieStack:zombieStack deallocStack:self.threadStack];
        delete zombieStack;
    }
    return nil;
}

/// 处理野指针对象的方法调用
/// @param selectorName 调用的方法
/// @param zombieStack 调用方法的堆栈
/// @param deallocStack 野指针对象dealloc的堆栈
- (void)handleZombieWithSelector:(NSString *)selectorName
                     zombieStack:(DDThreadStack *)zombieStack
                    deallocStack:(DDThreadStack *)deallocStack
{
    @autoreleasepool {
        if ([DDZombieMonitor sharedInstance].handle) {
            NSString *deallocStackInfo = nil;
            NSString *zombieStackInfo = nil;
            if (deallocStack) {
                deallocStackInfo = [[NSString alloc]initWithUTF8String:deallocStack->currentStackInfo().c_str()];
            }
            if (zombieStack) {
                zombieStackInfo = [[NSString alloc]initWithUTF8String:zombieStack->currentStackInfo().c_str()];
            }
            
            
            [DDZombieMonitor sharedInstance].handle(NSStringFromClass(self.realClass),
                                                    self,
                                                    selectorName,
                                                    deallocStackInfo,
                                                    zombieStackInfo);
        }
    }
    
    if ([DDZombieMonitor sharedInstance].crashWhenDetectedZombie) {
        assert(0); ///如果不保护，刚直接进入assert中断程序
    }
}

// MARK: - threadStack (为了兼容swift, 不能将class DDThreadStack 暴露出去)

- (void)updateThreadStack:(void *)threadStack {
    _threadStack = (DDThreadStack *)threadStack;
}

/// DDThreadStack *
- (void *)getThreadStack {
    return _threadStack;
}

- (void)deleteThreadStack {
    delete _threadStack;
    _threadStack = NULL;
}

- (size_t)occupyMemorySize {
    return _threadStack->occupyMemorySize();
}

@end
