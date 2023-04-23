//
//  KCLoggerInternal.h
//  KcDebugTool_Example
//
//  Created by 张杰 on 2023/4/11.
//  Copyright © 2023 张杰. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define __malloc_printf(FORMAT, ...)                              \
    do {                                                          \
        char msg[256] = { 0 };                                    \
        sprintf(msg, FORMAT, ##__VA_ARGS__);                      \
        kc_log_internal(__FILE_NAME__, __LINE__, __FUNCTION__, msg); \
    } while (0)

typedef union {
    uint64_t value;

    struct {
        uint32_t t_id;
        bool is_ignore;
    } detail;
} kc_thread_info_for_logging_t;

uint64_t kc_current_thread_info_for_logging(void);

bool kc_is_thread_ignoring_logging(void);

void kc_set_curr_thread_ignore_logging(bool ignore);

mach_port_t kc_current_thread_id(void);

// log
void kc_log_internal(const char *file, int line, const char *funcname, char *msg);

NS_ASSUME_NONNULL_END
