//
//  KCLoggerInternal.m
//  KcDebugTool_Example
//
//  Created by 张杰 on 2023/4/11.
//  Copyright © 2023 张杰. All rights reserved.
//

#import "KCLoggerInternal.h"
#import <malloc/malloc.h>
//#import <libkern/OSAtomic.h>
#import <os/lock.h>
#import <pthread/pthread.h>
#import <sys/mman.h>

typedef os_unfair_lock malloc_lock_s;

__attribute__((always_inline)) inline malloc_lock_s __malloc_lock_init() {
    return OS_UNFAIR_LOCK_INIT;
}

__attribute__((always_inline)) inline void __malloc_lock_lock(malloc_lock_s *lock) {
    os_unfair_lock_lock(lock);
}

__attribute__((always_inline)) inline bool __malloc_lock_trylock(malloc_lock_s *lock) {
    return os_unfair_lock_trylock(lock);
}

__attribute__((always_inline)) inline void __malloc_lock_unlock(malloc_lock_s *lock) {
    os_unfair_lock_unlock(lock);
}

static pthread_key_t s_thread_info_key = 1001;
static malloc_lock_s shared_lock = OS_UNFAIR_LOCK_INIT;
//static malloc_zone_t *inter_zone = malloc_create_zone(1 << 20, 0);
static malloc_zone_t *inter_zone;

// Will lock these mapped memory while App is in background
static void *mapped_mem[32] = { NULL };
static size_t mapped_size[32] = { 0 };
static bool app_is_in_backgound = false;

#pragma mark Thread Info

uint64_t kc_current_thread_info_for_logging(void) {
    uint64_t value = (uintptr_t)pthread_getspecific(s_thread_info_key);

    if (value == 0) {
        kc_thread_info_for_logging_t thread_info;
        thread_info.detail.is_ignore = false;
        thread_info.detail.t_id = pthread_mach_thread_np(pthread_self());
        pthread_setspecific(s_thread_info_key, (void *)(uintptr_t)thread_info.value);
        return thread_info.value;
    }

    return value;
}

mach_port_t kc_current_thread_id(void) {
    kc_thread_info_for_logging_t thread_info;
    thread_info.value = kc_current_thread_info_for_logging();
    return thread_info.detail.t_id;
}

void kc_set_curr_thread_ignore_logging(bool ignore) {
    kc_thread_info_for_logging_t thread_info;
    thread_info.value = kc_current_thread_info_for_logging();
    thread_info.detail.is_ignore = ignore;
    pthread_setspecific(s_thread_info_key, (void *)(uintptr_t)thread_info.value);
}

bool kc_is_thread_ignoring_logging(void) {
//    inter_zone = malloc_create_zone(1 << 20, 0);
    
    kc_thread_info_for_logging_t thread_info;
    thread_info.value = kc_current_thread_info_for_logging();
    return thread_info.detail.is_ignore;
}

#pragma mark Allocation/Deallocation Function without Logging

BOOL kc_logger_internal_init(void) {
    return pthread_key_create(&s_thread_info_key, NULL) == 0;
}

void *kc_inter_malloc(size_t size) {
    if (kc_is_thread_ignoring_logging()) {
        return inter_zone->malloc(inter_zone, size);
    } else {
        kc_set_curr_thread_ignore_logging(true);
        void *newMem = inter_zone->malloc(inter_zone, size);
        kc_set_curr_thread_ignore_logging(false);
        return newMem;
    }
}

void *kc_inter_calloc(size_t num_items, size_t size) {
    if (kc_is_thread_ignoring_logging()) {
        return inter_zone->calloc(inter_zone, num_items, size);
    } else {
        kc_set_curr_thread_ignore_logging(true);
        void *newMem = inter_zone->calloc(inter_zone, num_items, size);
        kc_set_curr_thread_ignore_logging(false);
        return newMem;
    }
}

void *kc_inter_realloc(void *oldMem, size_t newSize) {
    if (kc_is_thread_ignoring_logging()) {
        return inter_zone->realloc(inter_zone, oldMem, newSize);
    } else {
        kc_set_curr_thread_ignore_logging(true);
        void *newMem = inter_zone->realloc(inter_zone, oldMem, newSize);
        kc_set_curr_thread_ignore_logging(false);
        return newMem;
    }
}

void kc_inter_free(void *ptr) {
    if (kc_is_thread_ignoring_logging()) {
        inter_zone->free(inter_zone, ptr);
    } else {
        kc_set_curr_thread_ignore_logging(true);
        inter_zone->free(inter_zone, ptr);
        kc_set_curr_thread_ignore_logging(false);
    }
}

size_t inter_malloc_zone_statistics(void) {
    malloc_zone_pressure_relief(inter_zone, 0);
    malloc_statistics_t stat = { 0 };
    malloc_zone_statistics(inter_zone, &stat);
    return stat.size_in_use;
}

void __add_mapped_mem(void *mem, size_t size) {
    __malloc_lock_lock(&shared_lock);

    for (int i = 0; i < sizeof(mapped_mem) / sizeof(void *); ++i) {
        if (mapped_mem[i] == NULL) {
            mapped_mem[i] = mem;
            mapped_size[i] = size;
            break;
        }
    }
    if (app_is_in_backgound) {
        mlock(mem, size);
    }

    __malloc_lock_unlock(&shared_lock);
}

void __remove_mapped_mem(void *mem, size_t size) {
    __malloc_lock_lock(&shared_lock);

    for (int i = 0; i < sizeof(mapped_mem) / sizeof(void *); ++i) {
        if (mapped_mem[i] == mem && mapped_size[i] == size) {
            mapped_mem[i] = NULL;
            mapped_size[i] = 0;
            break;
        }
    }
    if (app_is_in_backgound) {
        munlock(mem, size);
    }

    __malloc_lock_unlock(&shared_lock);
}

void *inter_mmap(void *start, size_t length, int prot, int flags, int fd, off_t offset) {
    void *mappedMem = NULL;

    if (kc_is_thread_ignoring_logging()) {
        mappedMem = mmap(start, length, prot, flags, fd, offset);
    } else {
        kc_set_curr_thread_ignore_logging(true);
        mappedMem = mmap(start, length, prot, flags, fd, offset);
        kc_set_curr_thread_ignore_logging(false);
    }

    __add_mapped_mem(mappedMem, length);

    return mappedMem;
}

int inter_munmap(void *start, size_t length) {
    __remove_mapped_mem(start, length);

    if (kc_is_thread_ignoring_logging()) {
        int ret = munmap(start, length);
        if (ret != 0) {
            __malloc_printf("munmap fail, %s, errno: %d", strerror(errno), errno);
        }
        return ret;
    } else {
        kc_set_curr_thread_ignore_logging(true);
        int ret = munmap(start, length);
        if (ret != 0) {
            __malloc_printf("munmap fail, %s, errno: %d", strerror(errno), errno);
        }
        kc_set_curr_thread_ignore_logging(false);

        return ret;
    }
}

static mach_port_t ignore_thread_id = 0;

void kc_log_internal(const char *file, int line, const char *funcname, char *msg) {
    if (ignore_thread_id == kc_current_thread_id()) {
        return;
    }

    kc_set_curr_thread_ignore_logging(true);
//    MatrixLogInternal(MXLogLevelInfo, "MemStat", file, line, funcname, @"INFO: ", @"%s", msg);
    NSLog(@"file: %s, line: %d, funcname: %s, msg: %s", file, line, funcname, msg);
    kc_set_curr_thread_ignore_logging(false);
}

void log_internal_without_this_thread(mach_port_t t_id) {
    ignore_thread_id = t_id;
}
