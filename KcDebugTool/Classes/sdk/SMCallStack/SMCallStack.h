//
//  SMCallStack.h
//
//  Created by DaiMing on 2017/6/22.
//  Copyright © 2017年 Starming. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SMCallLib.h"

typedef NS_ENUM(NSUInteger, SMCallStackType) {
    SMCallStackTypeAll,     //全部线程
    SMCallStackTypeMain,    //主线程
    SMCallStackTypeCurrent  //当前线程
};



@interface SMCallStack : NSObject

/// 线程调用堆栈, isRunning = false
+ (NSString *)callStackWithType:(SMCallStackType)type;

/// 线程调用堆栈
/// - Parameters:
///   - type: 类型
///   - isRunning: 是否要CPU运行中的线程, CPU使用率 > 0表示在运行
///   - isFilterCurrentThread: 是否过滤当前线程
+ (NSString *)callStackWithType:(SMCallStackType)type
                      isRunning:(BOOL)isRunning
          isFilterCurrentThread:(BOOL)isFilterCurrentThread;

/// 获取当前线程id
+ (uint64_t)currentThreadID;

/// 获取线程id, thread_t currentThread = mach_thread_self(); (返回值为0说明error)
/// @param thread mach_thread_self()
+ (uint64_t)threadIDWithThread:(thread_t)thread;

extern NSString *smStackOfThread(thread_t thread);

@end
