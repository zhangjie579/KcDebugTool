//
//  KcThreadInfo.m
//  Pods
//
//  Created by 张杰 on 2023/9/9.
//

#import "KcThreadInfo.h"
#import <mach/mach.h>
#import <pthread.h>
#import "KcCThreadInfo.h"

@implementation KcThreadInfo

/// 获取当前线程id
+ (uint64_t)currentThreadID {
    return [self threadIDWithThread:mach_thread_self()];
}

/// 获取当前线程id, thread_t currentThread = mach_thread_self();
+ (uint64_t)threadIDWithThread:(thread_t)thread {
    thread_info_data_t current_info;
    mach_msg_type_number_t inOutSize;
    kern_return_t kr = thread_info((thread_t)thread, THREAD_IDENTIFIER_INFO, current_info, &inOutSize);
    uint64_t current_thread_id = 0;
    if (kr == KERN_SUCCESS) {
        thread_identifier_info_t idInfo = (thread_identifier_info_t)current_info;
        // https://juejin.cn/post/7036299565565214728
//            current_queue_name = [MrcUtil threadNameWithThreadInfo:idInfo];
//            dispatch_queue_t* dispatch_queue_ptr = (dispatch_queue_t*)idInfo->dispatch_qaddr;
//            dispatch_queue_t dispatch_queue = *dispatch_queue_ptr;
//            const char* queue_name = dispatch_queue_get_label(dispatch_queue);
        current_thread_id = idInfo->thread_id;
        
        return current_thread_id;
    } else {
        return 0;
    }
}

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
+ (bool)getQueueName:(const thread_t)thread buffer:(char *)buffer bufLength:(int)bufLength {
    return kc_ksthread_getQueueName(thread, buffer, bufLength);
}

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
+ (bool)getThreadName:(const thread_t)thread buffer:(char *)buffer bufLength:(int)bufLength {
    // WARNING: This implementation is no longer async-safe!
    
    const pthread_t pthread = pthread_from_mach_thread_np((thread_t)thread);
    return pthread_getname_np(pthread, buffer, (unsigned)bufLength) == 0;
}

+ (uintptr_t)thread_self {
    // 一个“反问”引发的内存反思：https://blog.csdn.net/killer1989/article/details/106674973
    thread_t thread_self = mach_thread_self();
    mach_port_deallocate(mach_task_self(), thread_self);
    return thread_self;
}

@end
