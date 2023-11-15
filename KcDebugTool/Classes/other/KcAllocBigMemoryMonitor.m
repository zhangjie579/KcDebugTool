//
//  KcAllocBigMemoryMonitor.m
//  KcDebugTool_Example
//
//  Created by 张杰 on 2022/9/26.
//  Copyright © 2022 张杰. All rights reserved.
//

#import "KcAllocBigMemoryMonitor.h"
#import <malloc/malloc.h>
#import <mach/mach.h>
#import "KCLoggerInternal.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <execinfo.h>
//#import "fishhook.h"

#define KC_USE_PRIVATE_API 1

typedef void (malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t num_hot_frames_to_skip);
//定义函数bba_malloc_stack_logger
void kc_hook_malloc_stack_logger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t backtrace_to_skip);

extern malloc_logger_t *malloc_logger;
//extern malloc_logger_t *__syscall_logger;
#ifdef KC_USE_PRIVATE_API
static malloc_logger_t **syscall_logger;
#endif

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

#define kc_memory_logging_type_mapped_file_or_shared_mem 128

//#define memory_logging_type_free 0
//#define memory_logging_type_generic 1 /* anything that is not allocation/deallocation */
//#define memory_logging_type_alloc 2 /* malloc, realloc, etc... */
//#define memory_logging_type_dealloc 4 /* free, realloc, etc... */
//#define memory_logging_type_vm_allocate 16 /* vm_allocate or mmap */
//#define memory_logging_type_vm_deallocate 32 /* vm_deallocate or munmap */
//#define MAP_FAILED      ((void *)-1)    /* [MF|SHM] mmap failed */


//__disk_stack_logging_log_stack(uint32_t type_flags, uintptr_t zone_ptr, uintptr_t arg2, uintptr_t arg3, uintptr_t return_val, uint32_t num_hot_to_skip)


// kc_hook_malloc_stack_logger具体实现
void kc_hook_malloc_stack_logger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t backtrace_to_skip)
{
    if (orig_malloc_logger != NULL) {
        orig_malloc_logger(type, arg1, arg2, arg3, result, backtrace_to_skip);
    }
    
//    uint32_t alias = 0;
//    VM_GET_FLAGS_ALIAS(type, alias);
//    // skip all VM allocation events from malloc_zone
//    if (alias >= VM_MEMORY_MALLOC && alias <= VM_MEMORY_MALLOC_NANO) {
//        return;
//    }

    // skip allocation events from mapped_file
    if (type & kc_memory_logging_type_mapped_file_or_shared_mem) {
        return;
    }
    
//    kc_thread_info_for_logging_t thread_info;
//    thread_info.value = kc_current_thread_info_for_logging();
//
//    if (thread_info.detail.is_ignore) {
//        // Prevent a thread from deadlocking against itself if vm_allocate() or malloc()
//        // is called below here, from woking thread or dumping thread
//        return;
//    }
    
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
        uintptr_t ptr_arg = arg2; // the original pointer
        if (ptr_arg == result) {
            return; // realloc had no effect, skipping
        }
        if (ptr_arg == 0) { // // realloc(NULL, size) same as malloc(size)
            // type ^= memory_logging_type_dealloc;
        } else {
            // arg3 为分配内存大小
            handle_malloc_observer(arg3);
        }
    } else if (type == (MALLOC_LOG_TYPE_DEALLOCATE | MALLOC_LOG_TYPE_HAS_ZONE)) { // malloc_zone_free
        //        uintptr_t size = arg3;
        //        uintptr_t ptr_arg = arg2;
        //        if (ptr_arg == 0) {
        //            return; // free(nil)
        //        }
    } else if (type & stack_logging_type_vm_allocate) { // vm_allocate or mmap
        // vm_allocate 没走这个⚠️
        if (result == 0 || result == (uintptr_t)((void *)-1)) { // -1是MAP_FAILED
            return;
        }
        handle_malloc_observer(arg2);
    }
}

//void kc_hook_malloc_stack_logger(uint32_t type_flags, uintptr_t zone_ptr, uintptr_t arg2, uintptr_t arg3, uintptr_t return_val, uint32_t num_hot_to_skip) {
//    uintptr_t size = 0;
//    uintptr_t ptr_arg = 0;
//    bool is_alloc = false;
//
//    uint32_t alias = 0;
//    VM_GET_FLAGS_ALIAS(type_flags, alias);
//    // skip all VM allocation events from malloc_zone
//    if (alias >= VM_MEMORY_MALLOC && alias <= VM_MEMORY_MALLOC_NANO) {
//        return;
//    }
//
//    // skip allocation events from mapped_file
//    if (type_flags & kc_memory_logging_type_mapped_file_or_shared_mem) {
//        return;
//    }
//
//    // check incoming data
//    if ((type_flags & memory_logging_type_alloc) && (type_flags & memory_logging_type_dealloc)) {
//        size = arg3;
//        ptr_arg = arg2; // the original pointer
//        if (ptr_arg == return_val) {
//            return; // realloc had no effect, skipping
//        }
//        if (ptr_arg == 0) { // realloc(NULL, size) same as malloc(size)
//            type_flags ^= memory_logging_type_dealloc;
//        } else {
//            // realloc(arg1, arg2) -> result is same as free(arg1); malloc(arg2) -> result
////            __memory_event_callback(memory_logging_type_dealloc, zone_ptr, ptr_arg, (uintptr_t)0, (uintptr_t)0, num_hot_to_skip + 1);
////            __memory_event_callback(memory_logging_type_alloc, zone_ptr, size, (uintptr_t)0, return_val, num_hot_to_skip + 1);
//            handle_malloc_observer(size);
//            return;
//        }
//    }
//    if ((type_flags & memory_logging_type_dealloc) || (type_flags & memory_logging_type_vm_deallocate)) {
//        size = arg3;
//        ptr_arg = arg2;
//        if (ptr_arg == 0) {
//            return; // free(nil)
//        }
//    }
//    if ((type_flags & memory_logging_type_alloc) || (type_flags & memory_logging_type_vm_allocate)) {
//        if (return_val == 0 || return_val == (uintptr_t)MAP_FAILED) {
//            return;
//        }
//        size = arg2;
//        is_alloc = true;
//    }
//
//    //type_flags &= memory_logging_valid_type_flags;
//
//    // gather stack, only alloc type
//    if (is_alloc) {
//
//    } else {
//        // compaction
//    }
//
//    handle_malloc_observer(size);
//}

static void handle_malloc_observer(uintptr_t memorySize) {
    // 这个可以视情况而定
    uintptr_t thresholdSize = thresholdSizeOfBigMemory();
    
    // 这里用了malloc的话就会出现死循环, 应该使用不监听的malloc zone
    // OOMDetector 也是通过条件来判断处理, 而不是直接在外部就使用了会调用malloc的方法, 比如size的条件
    
//    printf("xx --- %ld\n", memorySize);
    
    // 是大内存分配
    if (memorySize >= thresholdSize) {
        
        //返回值depth表示实际上获取的堆栈的深度，stacks用来存储堆栈地址信息，20表示指定堆栈深度。
//        size_t depth = backtrace((void**)stacks, 20);
        
//        NSString *callStack = [SMCallStack callStackWithType:SMCallStackTypeCurrent];
//        if (callStack.length > 0) {
//            NSLog(@"xx --- %@", callStack);
//        }
        
        NSArray *callStack = [KcAllocBigMemoryMonitor backtrace];
        if (callStack.count > 0) {
            NSLog(@"------- ❎ 大块内存分配 ❎-------");
            NSLog(@"🐶🐶🐶 memorySize: %0.3fM", memorySize / (1024.0 * 1024.0));
            NSLog(@"xx --- %@", callStack.description);
            NSLog(@"------- ❎ 大块内存分配 ❎-------");
        }
    }
}

/// 内存阈值
static inline uintptr_t thresholdSizeOfBigMemory(void) {
    return 4 * 1024 * 1024;
}

static bool isPaused = false;

+ (void)beginMonitor {
    /// malloc_logger本身就是一个hook函数，如果需要的话，只给其指定一个实现即可。
    /// 注意：不要影响了系统对其的实现。所以要先保存系统的，然后在自定义的实现中调用系统的。
    if (malloc_logger && malloc_logger != kc_hook_malloc_stack_logger) {
        orig_malloc_logger = malloc_logger;
    }
    malloc_logger = (malloc_logger_t *)kc_hook_malloc_stack_logger;
    
#ifdef KC_USE_PRIVATE_API
    // __syscall_logger - 这个是vm
    syscall_logger = (malloc_logger_t **)dlsym(RTLD_DEFAULT, "__syscall_logger");
    if (syscall_logger != NULL) {
        *syscall_logger = kc_hook_malloc_stack_logger;
    }
#endif
    
    isPaused = false;
    
//    rebind_symbols((struct rebinding[1]) {
//        {"vm_allocate",(void*)kc_vm_allocate,(void**)&orig_vm_allocate}}, 1);
}

+ (void)endMonitor {
    if (malloc_logger && malloc_logger == kc_hook_malloc_stack_logger) {
        malloc_logger = orig_malloc_logger;
    }
    
#ifdef KC_USE_PRIVATE_API
    if (syscall_logger != NULL) {
        *syscall_logger = NULL;
    }
#endif
    
    isPaused = true;
}

//extern int backtrace(void *, int);
/*
 存在两个问题
 1.方法具有线程属性，必须要在获取堆栈信息的当前线程调用；
 2.耗时严重，实测在中高端机(iPhone8以上)有30ms耗时，在低端机(iPhone8以下)有100ms的耗时。
 
 如果大块内存是在主线程分配的，上述耗时会引起主线程卡顿问题，故此方案无法针在线上生产环境使用。
 */
//extern char **backtrace_symbols(void *, int);

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
                   
#pragma mark - vm_allocate

static kern_return_t (*orig_vm_allocate)(vm_map_t target_task, vm_address_t *address, vm_size_t size, int flags);

/*
 场景:
 1. -[UIView drawRect] 重写这个方法
 */
kern_return_t kc_vm_allocate(vm_map_t target_task, vm_address_t *address, vm_size_t size, int flags) {
    kern_return_t rt = orig_vm_allocate(target_task, address, size, flags);
    if (!isPaused) {
        handle_malloc_observer(size);
    }

    return rt;
}
                

static void executeBlockInIgnoringLogging(void(^_Nullable block)(void)) {
    if (!block) {
        return;
    }
    
    if (kc_is_thread_ignoring_logging()) {
        block();
    } else {
        kc_set_curr_thread_ignore_logging(true);
        block();
        kc_set_curr_thread_ignore_logging(false);
    }
}

+ (void)executeBlockInIgnoringLogging:(void(^_Nullable)(void))block {
    if (!block) {
        return;
    }
    
    if (kc_is_thread_ignoring_logging()) {
        block();
    } else {
        kc_set_curr_thread_ignore_logging(true);
        block();
        kc_set_curr_thread_ignore_logging(false);
    }
}

@end
