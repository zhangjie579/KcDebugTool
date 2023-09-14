//
//  KcCThreadInfo.h
//  KcDebugTool
//
//  Created by 张杰 on 2023/9/9.
//

#ifndef KcCThreadInfo_h
#define KcCThreadInfo_h

#ifdef __cplusplus
extern "C" {
#endif

#include <stdio.h>
#include <sys/types.h>
#include <stdbool.h>
#include <pthread.h>
#include <mach/mach.h>

bool kc_ksmem_isMemoryReadable(const void* const memory, const int byteCount);

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
bool kc_ksthread_getQueueName(const thread_t thread, char* const buffer, int bufLength);

#ifdef __cplusplus
}
#endif

#endif /* KcCThreadInfo_h */
