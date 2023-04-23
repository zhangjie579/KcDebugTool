//
//  KcAllocBigMemoryMonitor.h
//  KcDebugTool_Example
//
//  Created by 张杰 on 2022/9/26.
//  Copyright © 2022 张杰. All rights reserved.
//  监听大内存分配 https://mp.weixin.qq.com/s/ke9bMHTfe1Ioq0eVfAxr2A

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
 OOMDetector
 
 https://blog.51cto.com/u_15082365/5471209
 
 hook malloc之类的方法
 https://github.com/wzpziyi1/MemoryDetector
 
 这种方式的问题: 堆栈与实际对象可能失去联系了, 大部分都是系统堆栈, 看不到自己写的代码
 */

/// 监听大内存分配
@interface KcAllocBigMemoryMonitor : NSObject

+ (void)beginMonitor;

+ (void)endMonitor;

/// 堆栈
+ (NSArray<NSString *> *)backtrace;

@end

NS_ASSUME_NONNULL_END
