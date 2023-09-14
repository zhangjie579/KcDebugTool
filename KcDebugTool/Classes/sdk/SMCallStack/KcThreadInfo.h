//
//  KcThreadInfo.h
//  Pods
//
//  Created by 张杰 on 2023/9/9.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KcThreadInfo : NSObject

/// 获取当前线程id
+ (uint64_t)currentThreadID;

/// 获取线程id, thread_t currentThread = mach_thread_self(); (返回值为0说明error)
/// @param thread mach_thread_self()
+ (uint64_t)threadIDWithThread:(thread_t)thread;

/** Get the name of a thread's dispatch queue. Internally, a queue name will
 * never be more than 64 characters long.
 *
 * @param thread The thread whose queue name to get.
 *
 * @oaram buffer Buffer to hold the name.
 *
 * @param bufLength The length of the buffer.
 *
 * @return true if a name or label was found.
 */
+ (bool)getQueueName:(const thread_t)thread buffer:(char *)buffer bufLength:(int)bufLength;

/** Get a thread's name. Internally, a thread name will
 * never be more than 64 characters long.
 *
 * @param thread The thread whose name to get.
 *
 * @oaram buffer Buffer to hold the name.
 *
 * @param bufLength The length of the buffer.
 *
 * @return true if a name was found.
 */
+ (bool)getThreadName:(const thread_t)thread buffer:(char *)buffer bufLength:(int)bufLength;

+ (uintptr_t)thread_self;

@end

NS_ASSUME_NONNULL_END
