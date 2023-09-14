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

/// 线程调用堆栈, isRunning = false, isFilterCurrentThread = false
+ (NSString *)callStackWithType:(SMCallStackType)type;

/// 线程调用堆栈
/// - Parameters:
///   - type: 类型
///   - isRunning: 是否要CPU运行中的线程, CPU使用率 > 0表示在运行
///   - isFilterCurrentThread: 是否过滤当前线程
+ (NSString *)callStackWithType:(SMCallStackType)type
                      isRunning:(BOOL)isRunning
          isFilterCurrentThread:(BOOL)isFilterCurrentThread;

extern NSString *smStackOfThread(thread_t thread);

@end
