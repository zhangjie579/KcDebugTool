//
//  KcMallocStackLoggingTooler.h
//  KcDebugTool
//
//  Created by 张杰 on 2023/9/14.
//  malloc stack工具
//
//  ⚠️ 关于新版Xcode下的适配:
//  本类原本依赖 libsystem_malloc.dylib 里的 __mach_stack_logging_* 私有符号,
//  这套符号在 iOS 16 之后已被 Apple 迁移到 MallocStackLogging.framework
//  并改名为 msl_* 前缀, libsystem_malloc 里只剩下一堆转发桩。
//  现改为 dlsym 动态解析 + 三级降级, 拿不到符号就安全返回 nil, 不会崩溃。
//
//  使用前置条件(必须)⚠️:
//    Scheme -> Run -> Arguments -> Environment Variables 里加 MallocStackLogging=malloc, 并**冷启动** App。
//    新版系统已经不支持运行时 turn_on_stack_logging() 开启了。
//
//  ⚠️ 三个实测踩坑点:
//  1. 只有 malloc 这个取值有效。lite / 1 / all / true 在新版系统上都退化成 lite,
//     拿不到按地址的历史堆栈(msl_get_frames_for_address 返回 KERN_FAILURE=5)。
//  2. 不要同时勾选 Scheme -> Diagnostics -> Malloc Stack Logging。
//     Xcode 26 只会注入 MallocStackLogging=lite, 且会覆盖你手填的环境变量 —— 这是
//     "Scheme 里配了 malloc 却没效果" 的最常见原因。
//  3. 必须是冷启动。环境变量只在进程启动时被 libmalloc 读一次, Attach 到已运行进程无效。
//
//  注意: 依赖私有实现, 仅供 Debug 期内存调试使用。
//        Release 构建默认通过 KC_MALLOC_STACK_LOGGING_ENABLED 宏整体失效。
//

#import <Foundation/Foundation.h>
#include <mach/mach.h>

NS_ASSUME_NONNULL_BEGIN

typedef enum {
    kc_stack_logging_mode_none = 0,
    kc_stack_logging_mode_all,
    kc_stack_logging_mode_malloc,
    kc_stack_logging_mode_vm,
    kc_stack_logging_mode_lite,
    kc_stack_logging_mode_vmlite
} kc_stack_logging_mode_type;

/// 当前解析到的是哪套实现
typedef NS_ENUM(NSUInteger, KcMSLSource) {
    KcMSLSourceNone = 0,       ///< 不可用, 所有方法会自动降级返回 nil
    KcMSLSourceLegacy,         ///< 老系统: libsystem_malloc 的 __mach_stack_logging_*
    KcMSLSourceFramework       ///< 新系统: MallocStackLogging.framework 的 msl_*
};

/* 使用
 ✅ 修法: Scheme -> Run -> Diagnostics 里**取消勾选** Malloc Stack Logging
 只在 Arguments -> Environment Variables 里填 MallocStackLogging=malloc, 再冷启动
 
 // ⚠️ turn_on_stack_logging() 在新版系统上只是转发桩, 实测返回 NO 且不生效,
 //    必须在 Scheme 环境变量里配 MallocStackLogging=malloc 并冷启动。
 // 先看一眼诊断: 它会告诉你是"没开"还是"被 Xcode 覆盖成了 lite"。
 NSString *mslDiagnosis = [KcMallocStackLoggingTooler diagnosis];
 NSLog(@"[MSL] env=%@ available=%d enabled=%d lite=%d diagnosis=%@",
       [KcMallocStackLoggingTooler launchEnvironmentValue] ?: @"(未设置)",
       [KcMallocStackLoggingTooler isAvailable],
       [KcMallocStackLoggingTooler isStackLoggingEnabled],
       [KcMallocStackLoggingTooler isLiteMode],
       mslDiagnosis ?: @"OK");

 id data = [KcMallocStackLoggingTooler mallocStackLogTraceObjc:application];
 */
@interface KcMallocStackLoggingTooler : NSObject

+ (instancetype)sharedInstance;

#pragma mark - 可用性诊断

/// 私有实现是否可用(拿不到符号就是 NO, 此时所有查询都会返回 nil 而不会崩)
+ (BOOL)isAvailable;

/// 当前解析到哪套实现
+ (KcMSLSource)availableSource;

/// 系统是否真的开启了 stack logging(需要启动时带环境变量)
+ (BOOL)isStackLoggingEnabled;

/// 是否 lite 模式 —— lite 模式拿不到按地址的历史堆栈
+ (BOOL)isLiteMode;

/// 进程启动时实际拿到的 MallocStackLogging 环境变量值(拿不到返回 nil)
/// 排查"Scheme 里明明配了却不生效"时先看这个: 这里显示什么, 系统就按什么工作
+ (nullable NSString *)launchEnvironmentValue;

/// 一句话诊断: 拿不到堆栈时直接展示给用户; 一切正常返回 nil
+ (nullable NSString *)diagnosis;

#pragma mark - 开关

/// ⚠️ 新版系统上这只是一个转发桩, 实测返回 NO 且不生效。
///    真正生效的方式是启动时环境变量 MallocStackLogging=malloc。
+ (BOOL)turn_on_stack_logging:(kc_stack_logging_mode_type)mode;

+ (void)turn_off_stack_logging;

#pragma mark - 查询

/// 获取地址的初始化堆栈
/// 需要启动时 MallocStackLogging=malloc
+ (nullable NSArray<NSString *> *)mallocStackLogTraceAddress:(mach_vm_address_t)addr;

/// 获取对象的初始化堆栈
/// 需要启动时 MallocStackLogging=malloc
+ (nullable NSArray<NSString *> *)mallocStackLogTraceObjc:(id)objc;

/// 获取address的alloc/dealloc的堆栈
/// 通过新版 msl_disk_stack_logs_enumerate_from_task(旧 __mach_stack_logging_enumerate_records) 遍历记录
/* 说明
 存在问题⚠️:
 1、由于address这块内存可能被alloc、dealloc很多次，这就导致不知道取的是那一次的值
 2、对于还存活的对象
    * alloc取的是最后一个
    * dealloc 没值，如果你硬要取，那获取到的堆栈也是使用这个address的其他对象的free堆栈
 3、对于已经free的对象
    * alloc不知道取的是哪一次，因为这个address可能已经被其他对象使用了，这就导致又alloc了，而且可能alloc了很多次，so你不知道取哪一次
    * dealloc跟alloc一样也是同样的问题
 4、遍历接口不知道有多少个匹配stack，这就导致使用效率很低，因为存在很多次分配释放内存

 使用说明🐶🐶🐶:
 1、观察dealloc - 开启xcode的zombie objects使用。就能准确观察到dealloc
    * 因为zombie objects观察野指针, 原理是最后不调用free, 那么这块内存就一直不会被其他重复使用, 那么dealloc就一定是最后一个的堆栈, 一定是准确的
 */
- (nullable NSArray<NSString *> *)enumerateMallocStackLoggingRecordsTraceAddress:(uintptr_t)address isAlloc:(BOOL)isAlloc;

/// 手动解析 /tmp 下的 stack-logs.* 磁盘 index 文件
/// ⚠️ 依赖私有二进制格式，新版系统随时可能失效；优先用上面的遍历接口
- (nullable NSArray<NSString *> *)traceAddress:(uintptr_t)address isAlloc:(BOOL)isAlloc;

@end

NS_ASSUME_NONNULL_END
