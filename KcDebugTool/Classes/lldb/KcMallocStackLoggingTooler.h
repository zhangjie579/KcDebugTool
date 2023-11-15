//
//  KcMallocStackLoggingTooler.h
//  KcDebugTool
//
//  Created by 张杰 on 2023/9/14.
//  malloc stack工具

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef enum {
    kc_stack_logging_mode_none = 0,
    kc_stack_logging_mode_all,
    kc_stack_logging_mode_malloc,
    kc_stack_logging_mode_vm,
    kc_stack_logging_mode_lite,
    kc_stack_logging_mode_vmlite
} kc_stack_logging_mode_type;

@interface KcMallocStackLoggingTooler : NSObject

+ (instancetype)sharedInstance;

+ (BOOL)turn_on_stack_logging:(kc_stack_logging_mode_type)mode;

+ (void)turn_off_stack_logging;

/// 获取地址的初始化堆栈
/// 这个需要打开 malloc stack logging - all allocation
+ (NSArray<NSString *> *)mallocStackLogTraceAddress:(mach_vm_address_t)addr;

/// 获取地址的初始化堆栈
/// 这个需要打开 malloc stack logging - all allocation
+ (NSArray<NSString *> *)mallocStackLogTraceObjc:(id)objc;

/// 获取address的alloc/dealloc的堆栈
/// 通过 __mach_stack_logging_enumerate_records 遍历记录
/* 说明
 存在问题⚠️:
 1、由于address这块内存可能被alloc、dealloc很多次，这就导致不知道取的是那一次的值
 2、对于还存活的对象
    * alloc取的是最后一个
    * dealloc 没值，如果你硬要取，那获取到的堆栈也是使用这个address的其他对象的free堆栈
 3、对于已经free的对象
    * alloc不知道取的是哪一次，因为这个address可能已经被其他对象使用了，这就导致又alloc了，而且可能alloc了很多次，so你不知道取哪一次
    * dealloc跟alloc一样也是同样的问题
 4、__mach_stack_logging_enumerate_records接口，传入的回调函数，不知道有多少个匹配stack，这就导致使用效率很低，因为存在很多次分配释放内存
    * 取巧做法: 调用2次__mach_stack_logging_enumerate_records方法，第一次在回调函数中记录count数量，第2次根据count判断才取值；可__mach_stack_logging_enumerate_records存在file读的问题，可能调用2次性能更差。
 
 使用说明🐶🐶🐶:
 1、观察dealloc - 开启xcode的zombie objects使用。就能准确观察到dealloc
    * 因为zombie objects观察野指针, 原理是最后不调用free, 那么这块内存就一直不会被其他重复使用, 那么dealloc就一定是最后一个的堆栈, 一定是准确的
 */
- (nullable NSArray<NSString *> *)enumerateMallocStackLoggingRecordsTraceAddress:(uintptr_t)address isAlloc:(BOOL)isAlloc;

@end

NS_ASSUME_NONNULL_END
