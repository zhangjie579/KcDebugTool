//
//  KcAllocBigMemoryMonitor.m
//  KcDebugTool_Example
//
//  Created by 张杰 on 2022/9/26.
//  Copyright © 2022 张杰. All rights reserved.
//

#import "KcAllocBigMemoryMonitor.h"
#import <malloc/malloc.h>

typedef void (malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t num_hot_frames_to_skip);
//定义函数bba_malloc_stack_logger
void kc_hook_malloc_stack_logger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t backtrace_to_skip);

extern malloc_logger_t *malloc_logger;
//extern malloc_logger_t *__syscall_logger;

static malloc_logger_t *orig_malloc_logger;

@implementation KcAllocBigMemoryMonitor

//malloc_logger赋值为自定义函数bba_malloc_stack_logger
//malloc_logger = (malloc_logger_t *)bba_malloc_stack_logger;

#define stack_logging_type_free        0
#define stack_logging_type_generic    1    /* anything that is not allocation/deallocation */
#define stack_logging_type_alloc    2    /* malloc, realloc, etc... */
#define stack_logging_type_dealloc    4    /* free, realloc, etc... */
#define stack_logging_type_vm_allocate  16      /* vm_allocate or mmap */
#define stack_logging_type_vm_deallocate  32    /* vm_deallocate or munmap */
#define stack_logging_type_mapped_file_or_shared_mem    128

// The valid flags include those from VM_FLAGS_ALIAS_MASK, which give the user_tag of allocated VM regions.
#define stack_logging_valid_type_flags ( \
stack_logging_type_generic | \
stack_logging_type_alloc | \
stack_logging_type_dealloc | \
stack_logging_type_vm_allocate | \
stack_logging_type_vm_deallocate | \
stack_logging_type_mapped_file_or_shared_mem | \
VM_FLAGS_ALIAS_MASK);

// Following flags are absorbed by stack_logging_log_stack()
#define    stack_logging_flag_zone        8    /* NSZoneMalloc, etc... */
#define stack_logging_flag_cleared    64    /* for NewEmptyHandle */

#define MALLOC_LOG_TYPE_ALLOCATE stack_logging_type_alloc
#define MALLOC_LOG_TYPE_DEALLOCATE stack_logging_type_dealloc
#define MALLOC_LOG_TYPE_HAS_ZONE stack_logging_flag_zone
#define MALLOC_LOG_TYPE_CLEARED stack_logging_flag_cleared

// kc_hook_malloc_stack_logger具体实现
void kc_hook_malloc_stack_logger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t backtrace_to_skip)
{
    if (orig_malloc_logger != NULL) {
        orig_malloc_logger(type, arg1, arg2, arg3, result, backtrace_to_skip);
    }
    
    //大块内存监控
    
    if (type == (MALLOC_LOG_TYPE_ALLOCATE | MALLOC_LOG_TYPE_HAS_ZONE)) { // malloc_zone_malloc
        // arg2 为分配内存大小
        handle_malloc_observer(arg2);
    } else if (type == (MALLOC_LOG_TYPE_ALLOCATE | MALLOC_LOG_TYPE_HAS_ZONE | MALLOC_LOG_TYPE_CLEARED)) { // malloc_zone_calloc
        // arg2 为分配内存大小
        handle_malloc_observer(arg2);
    } else if (type == (MALLOC_LOG_TYPE_ALLOCATE | MALLOC_LOG_TYPE_HAS_ZONE)) { // malloc_zone_valloc - 分配内存给一个对象
        // arg2 为分配内存大小
        handle_malloc_observer(arg2);
    } else if (type == (MALLOC_LOG_TYPE_ALLOCATE | MALLOC_LOG_TYPE_DEALLOCATE | MALLOC_LOG_TYPE_HAS_ZONE)) { // malloc_zone_realloc 重新分配内存
        // arg3 为分配内存大小
        handle_malloc_observer(arg3);
    } else if (type == (MALLOC_LOG_TYPE_DEALLOCATE | MALLOC_LOG_TYPE_HAS_ZONE)) { // malloc_zone_free
        
    }
}

static void handle_malloc_observer(uintptr_t memorySize) {
    // 这个可以视情况而定
    uintptr_t thresholdSize = thresholdSizeOfBigMemory();
    
    // 是大内存分配
    if (memorySize >= thresholdSize) {
        
        //返回值depth表示实际上获取的堆栈的深度，stacks用来存储堆栈地址信息，20表示指定堆栈深度。
//        size_t depth = backtrace((void**)stacks, 20);
        
//        NSString *callStack = [SMCallStack callStackWithType:SMCallStackTypeCurrent];
//        if (callStack.length > 0) {
//            NSLog(@"xx --- %@", callStack);
//        }
        
        NSArray *callStack = [KcAllocBigMemoryMonitor backtrace];
//        NSArray<StackSymbol *> *callStack = [RCBacktrace callstack:NSThread.currentThread];
        if (callStack.count > 0) {
            NSLog(@"------- ❎ 大块内存分配 ❎-------");
            NSLog(@"🐶🐶🐶 memorySize: %0.3f", memorySize / (1024.0 * 1024.0));
            NSLog(@"xx --- %@", callStack.description);
            NSLog(@"------- ❎ 大块内存分配 ❎-------");
        }
    }
}

/// 内存阈值
static inline uintptr_t thresholdSizeOfBigMemory() {
    return 8 * 1024 * 1024;
}

+ (void)beginMonitor {
    /// malloc_logger本身就是一个hook函数，如果需要的话，只给其指定一个实现即可。
    /// 注意：不要影响了系统对其的实现。所以要先保存系统的，然后在自定义的实现中调用系统的。
    if (malloc_logger && malloc_logger != kc_hook_malloc_stack_logger) {
        orig_malloc_logger = malloc_logger;
    }
    malloc_logger = (malloc_logger_t *)kc_hook_malloc_stack_logger;
}

+ (void)endMonitor {
    if (malloc_logger && malloc_logger == kc_hook_malloc_stack_logger) {
        malloc_logger = orig_malloc_logger;
    }
}

int backtrace(void *, int);
char **backtrace_symbols(void *, int);

/// 堆栈
+ (NSArray<NSString *> *)backtrace {
    //定义一个指针数组
    void* callstack[20];
    //该函数用于获取当前线程的调用堆栈,获取的信息将会被存放在callstack中。
    //参数128用来指定callstack中可以保存多少个void* 元素。
    //函数返回值是实际获取的指针个数,最大不超过128大小在callstack中的指针实际是从堆栈中获取的返回地址,每一个堆栈框架有一个返回地址。
    int frames = backtrace(callstack, 20);
    //backtrace_symbols将从backtrace函数获取的信息转化为一个字符串数组.
    //参数callstack应该是从backtrace函数获取的数组指针,frames是该数组中的元素个数(backtrace的返回值)
    //函数返回值是一个指向字符串数组的指针,它的大小同callstack相同.每个字符串包含了一个相对于callstack中对应元素的可打印信息.
    char **strs = backtrace_symbols(callstack, frames);

    NSMutableArray<NSString *> *backtrace = [NSMutableArray arrayWithCapacity:frames];

    for (int i = 0; i < frames; i++) {
        [backtrace addObject:[NSString stringWithUTF8String:strs[i]]];
    }
    //注意释放
    free(strs);
    return backtrace;
}

@end
