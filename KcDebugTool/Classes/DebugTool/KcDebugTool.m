//
//  KcDebugTool.m
//  test001
//
//  Created by samzjzhang on 2020/6/18.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "KcDebugTool.h"
#import "SMCallStack.h"
#import "KcFluencyMonitor.h"
#import "KcGlobalWindowBtn.h"

@implementation KcDebugTool

/// 监听卡顿
+ (void)addObserverFluency {
    static KcFluencyMonitor *fluencyMonitor;
    if (!fluencyMonitor) {
        fluencyMonitor = [[KcFluencyMonitor alloc] init];
        fluencyMonitor.intervalTimeout = 0.3;
    }
    fluencyMonitor.blockTimeout = ^{
        NSString *callStack = [self callStackMainQueue];
        NSLog(@"👻---- 卡顿 ------ 👻 \n %@ \n 👻---- 卡顿 ------ 👻", callStack);
        
    };
    [fluencyMonitor start];
}

/// 死锁
+ (void)addObserverDeadLock {
    static KcFluencyMonitor *fluencyMonitor;
    if (!fluencyMonitor) {
        fluencyMonitor = [[KcFluencyMonitor alloc] init];
        fluencyMonitor.intervalTimeout = 5.0;
    }
    fluencyMonitor.blockTimeout = ^{
        NSString *callStack = [self callStackMainQueue];
        NSLog(@"👻---- 主线程死锁 ------ 👻 \n %@ \n 👻---- 主线程死锁 ------ 👻", callStack);
        
    };
    [fluencyMonitor start];
}

+ (NSString *)callStackMainQueue {
    NSString *callStack = [SMCallStack callStackWithType:SMCallStackTypeMain];
    return callStack;
}

+ (NSString *)callStackAll {
    return [SMCallStack callStackWithType:SMCallStackTypeAll];
}

@end

/// 添加debug的插件
__attribute__((constructor)) void kc_setupDebugPlugin() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        
        static KcGlobalWindowBtn *globalBtn;
        if (!globalBtn) {
            globalBtn = [[KcGlobalWindowBtn alloc] init];
        }
        [globalBtn start];
        
//        [KcDebugTool addObserverFluency];
//        [KcDebugTool addObserverDeadLock];
    });
}

