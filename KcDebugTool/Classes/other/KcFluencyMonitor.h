//
//  KcFluencyMonitor.h
//  RunLoopDemo03
//
//  Created by samzjzhang on 2020/6/30.
//  Copyright © 2020 Haley. All rights reserved.
//  监听卡顿、串行线程死锁

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KcFluencyMonitor : NSObject

/// 被监听的线程(只能处理串行线程), 默认是主线程
@property (nonatomic) dispatch_queue_t queueBeListening;
@property (nonatomic) double intervalTimeout;
@property (nonatomic) void(^blockTimeout)(void);

+ (instancetype)shared;

- (void)start;
- (void)end;

@end

NS_ASSUME_NONNULL_END
