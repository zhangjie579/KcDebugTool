//
//  KcFluencyMonitor.m
//  RunLoopDemo03
//
//  Created by samzjzhang on 2020/6/30.
//  Copyright © 2020 Haley. All rights reserved.
//

#import "KcFluencyMonitor.h"

@interface KcFluencyMonitor ()

@property (nonatomic) dispatch_semaphore_t semaphore;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) BOOL monitoring;

@end

@implementation KcFluencyMonitor

static KcFluencyMonitor *kc_monitor_objc = nil;

+ (instancetype)shared {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!kc_monitor_objc) {
            kc_monitor_objc = [[KcFluencyMonitor alloc] init];
        }
    });
    return kc_monitor_objc;
}

- (instancetype)init {
    if (self = [super init]) {
        self.intervalTimeout = 0.3;
        self.queueBeListening = dispatch_get_main_queue();
    }
    return self;
}

- (void)start {
    if (self.monitoring) {
        return;
    }
    self.monitoring = true;
    
    dispatch_async(self.queue, ^{
        
        while (self.monitoring) {
            __block BOOL timeout = true;
            dispatch_async(self.queueBeListening, ^{
                timeout = false;
                dispatch_semaphore_signal(self.semaphore);
            });
            [NSThread sleepForTimeInterval:self.intervalTimeout];
            if (timeout) { // 卡顿、主线程死锁
                [self handleTimeout];
            }
            
            dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
        }
    });
}

- (void)end {
    self.monitoring = false;
}

- (void)setIntervalTimeout:(double)intervalTimeout {
    if (intervalTimeout <= 0) {
        _intervalTimeout = 0.3;
    } else {
        _intervalTimeout = intervalTimeout;
    }
}

#pragma mark - private

- (void)handleTimeout {
    if (self.blockTimeout) {
        self.blockTimeout();
    }
}

#pragma mark - 懒加载

- (dispatch_semaphore_t)semaphore {
    if (!_semaphore) {
        _semaphore = dispatch_semaphore_create(0);
    }
    return _semaphore;
}

- (dispatch_queue_t)queue {
    if (!_queue) {
        _queue = dispatch_queue_create("com.kc.monitor.queue", 0);
    }
    return _queue;
}

@end
