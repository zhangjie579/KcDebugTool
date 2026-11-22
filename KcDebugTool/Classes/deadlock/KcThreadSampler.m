#import "KcThreadSampler.h"
#import "KcDeadlockInternal.h"
#import <mach/mach.h>
#import <pthread.h>
#import <dlfcn.h>
#if __has_include(<ptrauth.h>)
#import <ptrauth.h>
#endif

NSDictionary<NSString *, NSString *> *KcCurrentExecutionContext(void) {
    char buffer[256] = {0};
    pthread_getname_np(pthread_self(), buffer, sizeof(buffer));
    NSString *name = NSThread.currentThread.name;
    if (!name.length) name = [NSString stringWithUTF8String:buffer];
    if (!name.length) name = NSThread.isMainThread ? @"main" : @"<unnamed>";
    const char *label = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    NSString *queueLabel = label ? [NSString stringWithUTF8String:label] : @"";
    NSString *operationName = NSOperationQueue.currentQueue.name;
    return @{@"threadName": [name copy], @"dispatchQueueLabel": queueLabel ?: @"",
             @"operationQueueName": [operationName copy] ?: @""};
}

static uintptr_t KcCodeAddress(uintptr_t address) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)address, ptrauth_key_return_address);
#else
    return address;
#endif
}

// 不 suspend：暂停持有 malloc/ObjC runtime 锁的线程后再符号化，可能把监控线程一起锁死。
// 栈随时变化，故仅提供 best-effort 快照；读取失败/优化省略 FP 时保留已有帧。
static NSArray<NSString *> *KcReadStack(thread_t thread) {
    uintptr_t pc = 0, fp = 0, lr = 0;
    kern_return_t result = KERN_FAILURE;
#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    result = thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count);
    if (result == KERN_SUCCESS) {
        pc = arm_thread_state64_get_pc(state);
        fp = arm_thread_state64_get_fp(state);
        lr = arm_thread_state64_get_lr(state);
    }
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    result = thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &count);
    if (result == KERN_SUCCESS) { pc = state.__rip; fp = state.__rbp; }
#elif defined(__arm__)
    arm_thread_state_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE_COUNT;
    result = thread_get_state(thread, ARM_THREAD_STATE, (thread_state_t)&state, &count);
    if (result == KERN_SUCCESS) { pc = state.__pc; fp = state.__r[7]; lr = state.__lr; }
#elif defined(__i386__)
    x86_thread_state32_t state;
    mach_msg_type_number_t count = x86_THREAD_STATE32_COUNT;
    result = thread_get_state(thread, x86_THREAD_STATE32, (thread_state_t)&state, &count);
    if (result == KERN_SUCCESS) { pc = state.__eip; fp = state.__ebp; }
#endif
    if (result != KERN_SUCCESS) {
        return @[[NSString stringWithFormat:@"<thread_get_state unavailable: %d>", result]];
    }
    uintptr_t addresses[64];
    NSUInteger length = 0;
    if (pc) addresses[length++] = KcCodeAddress(pc);
    if (lr) addresses[length++] = KcCodeAddress(lr);
    while (fp && length < 64) {
        if (fp % sizeof(uintptr_t)) break;
        struct { uintptr_t previous, address; } frame;
        vm_size_t copied = 0;
        result = vm_read_overwrite(mach_task_self(), (vm_address_t)fp, sizeof(frame), (vm_address_t)&frame, &copied);
        if (result != KERN_SUCCESS || copied != sizeof(frame)) break;
        if (frame.address) addresses[length++] = KcCodeAddress(frame.address);
        if (frame.previous <= fp || frame.previous - fp > 1024 * 1024) break;
        fp = frame.previous;
    }
    NSMutableArray *symbols = [NSMutableArray array];
    for (NSUInteger i = 0; i < length; i++) {
        Dl_info info = {0};
        uintptr_t address = addresses[i];
        // 返回地址可能位于函数边界，查询其前一个字节以定位调用者。
        dladdr((void *)(i && address ? address - 1 : address), &info);
        NSString *image = info.dli_fname ? [@(info.dli_fname) lastPathComponent] : @"?";
        [symbols addObject:[NSString stringWithFormat:@"%02lu %@ base=0x%llx 0x%llx %s + %llu",
                            (unsigned long)i, image, (unsigned long long)(uintptr_t)info.dli_fbase,
                            (unsigned long long)address, info.dli_sname ?: "<unsymbolicated>",
                            (unsigned long long)(info.dli_saddr ? address - (uintptr_t)info.dli_saddr : 0)]];
    }
    if (!symbols.count) [symbols addObject:@"<no frames available>"];
    return symbols;
}

NSDictionary<NSNumber *, NSDictionary *> *KcSampleThreads(void) {
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    kern_return_t result = task_threads(mach_task_self(), &threads, &count);
    if (result != KERN_SUCCESS) return @{};
    uint64_t current = 0;
    pthread_threadid_np(NULL, &current);
    NSMutableDictionary *snapshots = [NSMutableDictionary dictionary];
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        thread_identifier_info_data_t identity;
        mach_msg_type_number_t identityCount = THREAD_IDENTIFIER_INFO_COUNT;
        thread_basic_info_data_t basic;
        mach_msg_type_number_t basicCount = THREAD_BASIC_INFO_COUNT;
        if (thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&identity, &identityCount) == KERN_SUCCESS &&
            identity.thread_id != current &&
            thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&basic, &basicCount) == KERN_SUCCESS) {
            double CPUTime = basic.user_time.seconds + basic.system_time.seconds +
                (basic.user_time.microseconds + basic.system_time.microseconds) / 1000000.0;
            thread_extended_info_data_t extended = {0};
            mach_msg_type_number_t extendedCount = THREAD_EXTENDED_INFO_COUNT;
            thread_info(threads[i], THREAD_EXTENDED_INFO, (thread_info_t)&extended, &extendedCount);
            NSString *name = [NSString stringWithUTF8String:extended.pth_name] ?: @"";
            snapshots[@(identity.thread_id)] = @{@"threadID": @(identity.thread_id), @"name": name,
                @"CPUTime": @(CPUTime), @"state": @(basic.run_state), @"stack": KcReadStack(threads[i])};
        }
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
    return snapshots;
}
