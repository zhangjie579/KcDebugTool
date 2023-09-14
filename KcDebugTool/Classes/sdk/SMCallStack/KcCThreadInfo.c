//
//  KcCThreadInfo.c
//  KcDebugTool
//
//  Created by 张杰 on 2023/9/9.
//

#include "KcCThreadInfo.h"
#include <dispatch/dispatch.h>
#include <sys/sysctl.h>
#include <stdio.h>

static inline int copySafely(const void* restrict const src, void* restrict const dst, const int byteCount)
{
    vm_size_t bytesCopied = 0;
    kern_return_t result = vm_read_overwrite(mach_task_self(),
                                             (vm_address_t)src,
                                             (vm_size_t)byteCount,
                                             (vm_address_t)dst,
                                             &bytesCopied);
    if(result != KERN_SUCCESS)
    {
        return 0;
    }
    return (int)bytesCopied;
}

static char g_memoryTestBuffer[10240];
static inline bool isMemoryReadable(const void* const memory, const int byteCount)
{
    const int testBufferSize = sizeof(g_memoryTestBuffer);
    int bytesRemaining = byteCount;
    
    while(bytesRemaining > 0)
    {
        int bytesToCopy = bytesRemaining > testBufferSize ? testBufferSize : bytesRemaining;
        if(copySafely(memory, g_memoryTestBuffer, bytesToCopy) != bytesToCopy)
        {
            break;
        }
        bytesRemaining -= bytesToCopy;
    }
    return bytesRemaining == 0;
}

bool kc_ksmem_isMemoryReadable(const void* const memory, const int byteCount)
{
    return isMemoryReadable(memory, byteCount);
}

bool kc_ksthread_getQueueName(const thread_t thread, char* const buffer, int bufLength)
{
    // WARNING: This implementation is no longer async-safe!
    
    integer_t infoBuffer[THREAD_IDENTIFIER_INFO_COUNT] = {0};
    thread_info_t info = infoBuffer;
    mach_msg_type_number_t inOutSize = THREAD_IDENTIFIER_INFO_COUNT;
    kern_return_t kr = 0;
    
    kr = thread_info((thread_t)thread, THREAD_IDENTIFIER_INFO, info, &inOutSize);
    if(kr != KERN_SUCCESS)
    {
        printf("Error getting thread_info with flavor THREAD_IDENTIFIER_INFO from mach thread : %s", mach_error_string(kr));
        return false;
    }
    
    thread_identifier_info_t idInfo = (thread_identifier_info_t)info;
    if(!kc_ksmem_isMemoryReadable(idInfo, sizeof(*idInfo)))
    {
//        printf("Thread %p has an invalid thread identifier info %p", thread, idInfo);
        return false;
    }
    dispatch_queue_t* dispatch_queue_ptr = (dispatch_queue_t*)idInfo->dispatch_qaddr;
    if(!kc_ksmem_isMemoryReadable(dispatch_queue_ptr, sizeof(*dispatch_queue_ptr)))
    {
//        printf("Thread %p has an invalid dispatch queue pointer %p", thread, dispatch_queue_ptr);
        return false;
    }
    //thread_handle shouldn't be 0 also, because
    //identifier_info->dispatch_qaddr =  identifier_info->thread_handle + get_dispatchqueue_offset_from_proc(thread->task->bsd_info);
    if(dispatch_queue_ptr == NULL || idInfo->thread_handle == 0 || *dispatch_queue_ptr == NULL)
    {
//        printf("This thread doesn't have a dispatch queue attached : %p", thread);
        return false;
    }
    
    dispatch_queue_t dispatch_queue = *dispatch_queue_ptr;
    const char* queue_name = dispatch_queue_get_label(dispatch_queue);
    if(queue_name == NULL)
    {
//        printf("Error while getting dispatch queue name : %p", dispatch_queue);
        return false;
    }
//    printf("Dispatch queue name: %s", queue_name);
    int length = (int)strlen(queue_name);
    
    // Queue label must be a null terminated string.
    int iLabel;
    for(iLabel = 0; iLabel < length + 1; iLabel++)
    {
        if(queue_name[iLabel] < ' ' || queue_name[iLabel] > '~')
        {
            break;
        }
    }
    if(queue_name[iLabel] != 0)
    {
        // Found a non-null, invalid char.
//        printf("Queue label contains invalid chars");
        return false;
    }
    bufLength = MIN(length, bufLength - 1);//just strlen, without null-terminator
    strncpy(buffer, queue_name, bufLength);
    buffer[bufLength] = 0;//terminate string
//    printf("Queue label = %s", buffer);
    return true;
}
