//
//  KcAllocBigMemoryMonitor.h
//  KcDebugTool_Example
//
//  Created by 张杰 on 2022/9/26.
//  Copyright © 2022 张杰. All rights reserved.
//  监听大内存分配 https://mp.weixin.qq.com/s/ke9bMHTfe1Ioq0eVfAxr2A

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 监听大内存分配
@interface KcAllocBigMemoryMonitor : NSObject

+ (void)beginMonitor;

+ (void)endMonitor;

/// 堆栈
+ (NSArray<NSString *> *)backtrace;

@end

NS_ASSUME_NONNULL_END
