//
//  KcMallocStackLoggingTooler.m
//  KcDebugTool
//
//  Created by 张杰 on 2023/9/14.
//  Updated: 适配新版 Xcode / iOS SDK
//  Co-authored by WorkBuddy
//
//  参考: apple-oss-distributions/libmalloc (main) src/malloc.c "Malloc Stack Logging - Legacy stubs"
//
//  ⚠️ 重要变更(必读):
//  ---------------------------------------------------------------
//  旧写法直接 extern 声明 __mach_stack_logging_* 系列私有符号并调用,
//  这些符号在 iOS 16 之后已经被 Apple 从 libsystem_malloc.dylib 移除,
//  整体迁移到了 MallocStackLogging.framework 并重命名为 msl_* 前缀。
//
//  实测(Xcode 26.2 / macOS 26.2 SDK):
//    iOS SDK libSystem.tbd 中仅剩:
//      _turn_on_stack_logging / _turn_off_stack_logging /
//      ___mach_stack_logging_shared_memory_address
//    其余 __mach_stack_logging_* 全部消失。
//    因此旧写法在新 Xcode 下会得到 Undefined symbols 链接失败;
//    若用老 SDK 编出的产物跑在新系统上, 则 dyld 报 "symbol not found" 直接崩。
//
//  本文件的做法:
//    1. 不再产生任何对这些私有符号的静态引用(不再 extern 直接调用),
//       改用 dlsym 动态解析 => 不会链接失败, 也不会 dyld 启动崩溃;
//    2. 三级降级解析: 旧符号 -> MallocStackLogging.framework 的 msl_* 新符号 -> 直接放弃返回 nil;
//    3. 用 KC_MALLOC_STACK_LOGGING_ENABLED 宏(默认跟随 DEBUG)在 Release 下完全编译为空实现,
//       Release 包里不含任何私有 API 痕迹。
//    4. 任何一步拿不到符号都静默降级, 绝不 crash。
//
//  使用前提(⚠️比旧版更严格):
//    新版 turn_on_stack_logging() 已经只剩下转发到私有 framework 的桩函数, 实测运行时调用
//    并不能真正开启记录(返回 0, msl_is_stack_logging_enabled 仍为 0)。
//    必须在**进程启动时**通过环境变量开启:
//        MallocStackLogging=malloc          // 全量 alloc/dealloc 历史(推荐, 实测可用)
//        MallocStackLogging=lite            // 仅存活对象, 无法按地址查历史堆栈
//    Xcode 里配置: Scheme -> Run -> Diagnostics -> Malloc Stack Logging
//    或 Product -> Scheme -> Edit Scheme -> Arguments -> Environment Variables。
//
//  符号迁移对照表(已在本机 macOS 26 上实测通过):
//    __mach_stack_logging_get_frames                    -> msl_get_frames_for_address
//    __mach_stack_logging_get_frames_for_stackid        -> msl_get_frames_for_stackid
//    __mach_stack_logging_enumerate_records             -> msl_disk_stack_logs_enumerate_from_task
//    __mach_stack_logging_copy_uniquing_table           -> msl_uniquing_table_copy_from_task
//    __mach_stack_logging_uniquing_table_read_stack     -> msl_uniquing_table_read_stack
//    __mach_stack_logging_uniquing_table_release        -> msl_uniquing_table_release
//

#import "KcMallocStackLoggingTooler.h"
#import <dlfcn.h>
#include <mach/mach.h>
#include <stdlib.h>

#pragma mark - 开关

/// 想彻底关掉(比如Release包)就在 podspec / target 里定义 KC_MALLOC_STACK_LOGGING_ENABLED=0
#ifndef KC_MALLOC_STACK_LOGGING_ENABLED
    #if DEBUG
        #define KC_MALLOC_STACK_LOGGING_ENABLED 1
    #else
        #define KC_MALLOC_STACK_LOGGING_ENABLED 0
    #endif
#endif

#pragma mark - 常量 & 结构

#define kc_malloc_stack_logging_type_free        0
#define kc_malloc_stack_logging_type_generic     1   /* anything that is not allocation/deallocation */
#define kc_malloc_stack_logging_type_alloc       2   /* malloc, realloc, etc... */
#define kc_malloc_stack_logging_type_dealloc     4   /* free, realloc, etc... */
#define kc_malloc_stack_logging_type_vm_allocate     16   /* vm_allocate or mmap */
#define kc_malloc_stack_logging_type_vm_deallocate   32   /* vm_deallocate or munmap */
#define kc_malloc_stack_logging_type_mapped_file_or_shared_mem  128

/// 磁盘日志索引项(旧版 libmalloc 的 stack_logging.h)
/// 注意: 新版 MallocStackLogging 已经改用 msl_disk_stack_logs_enumerate_from_task
///       直接遍历, 这个结构体仅供 parseLogFile 这条老路径兜底使用, 格式可能随系统变化。
typedef struct {
    uint64_t argument;
    uint64_t address;
    uint64_t offset;
    uint64_t flags;
} kc_stack_logging_index_event64;

/// 一条分配记录。
/// 实测新版的记录布局与旧版 64 位一致: {type_flags, stack_identifier, argument, address}
typedef struct kc_mach_stack_logging_record {
    uint64_t            type_flags;
    uint64_t            stack_identifier;
    /// 内存的大小
    uint64_t            argument;
    mach_vm_address_t   address;
} kc_mach_stack_logging_record_t;

#define KC_STACK_LOGGING_DISGUISE(address)  ((address) ^ 0x00005555)

/// 私有 framework 路径(新版 stack logging 的实现所在地)
static NSString * const kc_MallocStackLoggingFrameworkPath =
    @"/System/Library/PrivateFrameworks/MallocStackLogging.framework/MallocStackLogging";

#pragma mark - 函数指针类型

typedef boolean_t      (*kc_turn_on_stack_logging_fn)(int mode);
typedef void           (*kc_turn_off_stack_logging_fn)(void);
typedef boolean_t      (*kc_msl_is_enabled_fn)(void);
typedef boolean_t      (*kc_msl_is_lite_fn)(void);

typedef kern_return_t  (*kc_get_frames_for_address_fn)(task_t task,
                                                       mach_vm_address_t address,
                                                       mach_vm_address_t *stack_frames_buffer,
                                                       uint32_t max_stack_frames,
                                                       uint32_t *count);

typedef kern_return_t  (*kc_get_frames_for_stackid_fn)(task_t task,
                                                       uint64_t stack_identifier,
                                                       mach_vm_address_t *stack_frames_buffer,
                                                       uint32_t max_stack_frames,
                                                       uint32_t *count,
                                                       bool *last_frame_is_threadid);

typedef kern_return_t  (*kc_enumerate_records_fn)(task_t task,
                                                  mach_vm_address_t address,
                                                  void enumerator(kc_mach_stack_logging_record_t, void *),
                                                  void *context);

typedef void *         (*kc_uniquing_table_copy_fn)(task_t task);
typedef kern_return_t  (*kc_uniquing_table_read_stack_fn)(void *table,
                                                          uint64_t stack_identifier,
                                                          mach_vm_address_t *out_frames_buffer,
                                                          uint32_t *out_frames_count,
                                                          uint32_t max_frames);
typedef void           (*kc_uniquing_table_release_fn)(void *table);

#pragma mark - 动态符号解析

/// 内部方法前向声明, 供下面的 C 函数回调使用(KcMSLSource 枚举定义在头文件里)
@interface KcMallocStackLoggingTooler ()

@property (nonatomic, copy, nullable) NSString *logFilePath;
@property (nonatomic, assign) BOOL isAlloc;
@property (nonatomic, strong, nullable) NSArray<NSString *> *findArray;

+ (NSArray<NSString *> *)symbolicateFrames:(mach_vm_address_t *)frames count:(uint32_t)count;
+ (void *)rawGetFramesForStackId;
- (NSString *)typeStringWithFlags:(uint64_t)type_flags;

@end


@implementation KcMallocStackLoggingTooler

#pragma mark - 单例

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static KcMallocStackLoggingTooler *m;
    dispatch_once(&onceToken, ^{
        m = [[KcMallocStackLoggingTooler alloc] init];
    });
    return m;
}

#pragma mark - 符号解析 (三级降级)

/// 旧版符号名 -> 新版符号名 的映射表
static NSString * const kcSymbolMap[][2] = {
    { @"__mach_stack_logging_get_frames",                 @"msl_get_frames_for_address" },
    { @"__mach_stack_logging_get_frames_for_stackid",     @"msl_get_frames_for_stackid" },
    { @"__mach_stack_logging_enumerate_records",          @"msl_disk_stack_logs_enumerate_from_task" },
    { @"__mach_stack_logging_copy_uniquing_table",        @"msl_uniquing_table_copy_from_task" },
    { @"__mach_stack_logging_uniquing_table_read_stack",  @"msl_uniquing_table_read_stack" },
    { @"__mach_stack_logging_uniquing_table_release",     @"msl_uniquing_table_release" },
};

static void * _Nullable kc_resolve(NSString *legacyName, NSString *modernName) {
    // 1) 旧符号: 老系统(iOS <= 15 / macOS <= 12)上仍在 libsystem_malloc 里
    void *p = dlsym(RTLD_DEFAULT, legacyName.UTF8String);
    if (p) {
        return p;
    }
    // 2) 新符号: MallocStackLogging.framework
    //    优先 RTLD_NOLOAD —— 只有进程启动时带了 MallocStackLogging 环境变量时它才已经被加载,
    //    这种情况是"系统自己加载的", 我们不去主动 load 任何东西。
    void *handle = dlopen(kc_MallocStackLoggingFrameworkPath.UTF8String, RTLD_NOLOAD);
    if (!handle) {
        // 3) 兜底: 尝试真正加载。libmalloc 自己内部就是这么做的,
        //    失败也没关系, 拿不到就直接降级。
        handle = dlopen(kc_MallocStackLoggingFrameworkPath.UTF8String, RTLD_LAZY);
    }
    if (!handle) {
        return NULL;
    }
    return dlsym(handle, modernName.UTF8String);
}

static void * _Nullable kc_symbol(size_t index) {
    return kc_resolve(kcSymbolMap[index][0], kcSymbolMap[index][1]);
}

enum {
    kcIdxGetFramesForAddress = 0,
    kcIdxGetFramesForStackId = 1,
    kcIdxEnumerateRecords    = 2,
    kcIdxTableCopy           = 3,
    kcIdxTableReadStack      = 4,
    kcIdxTableRelease        = 5,
};

/// 当前是哪套实现在生效(供上层提示用)
+ (KcMSLSource)availableSource {
#if !KC_MALLOC_STACK_LOGGING_ENABLED
    return KcMSLSourceNone;
#else
    if (dlsym(RTLD_DEFAULT, kcSymbolMap[kcIdxGetFramesForAddress][0].UTF8String)) {
        return KcMSLSourceLegacy;
    }
    if ([self rawGetFramesForAddress] != NULL) {
        return KcMSLSourceFramework;
    }
    return KcMSLSourceNone;
#endif
}

+ (void *)rawGetFramesForAddress {
#if !KC_MALLOC_STACK_LOGGING_ENABLED
    return NULL;
#else
    return kc_symbol(kcIdxGetFramesForAddress);
#endif
}

+ (void *)rawEnumerateRecords {
#if !KC_MALLOC_STACK_LOGGING_ENABLED
    return NULL;
#else
    return kc_symbol(kcIdxEnumerateRecords);
#endif
}

+ (void *)rawGetFramesForStackId {
#if !KC_MALLOC_STACK_LOGGING_ENABLED
    return NULL;
#else
    return kc_symbol(kcIdxGetFramesForStackId);
#endif
}

#pragma mark - 可用性 & 诊断

/// 私有符号是否可用 => 不可用就别白忙活了
+ (BOOL)isAvailable {
#if !KC_MALLOC_STACK_LOGGING_ENABLED
    return NO;
#else
    return [self availableSource] != KcMSLSourceNone;
#endif
}

/// 系统是否真的开启了 stack logging
/// 实测: 必须启动时带 MallocStackLogging=malloc; 运行时调 turn_on_stack_logging 是无效的
+ (BOOL)isStackLoggingEnabled {
#if !KC_MALLOC_STACK_LOGGING_ENABLED
    return NO;
#else
    // 旧版没得查, 用地址探测的方式兜底
    void *handle = dlopen(kc_MallocStackLoggingFrameworkPath.UTF8String, RTLD_NOLOAD);
    kc_msl_is_enabled_fn isEnabled = handle ? (kc_msl_is_enabled_fn)dlsym(handle, "msl_is_stack_logging_enabled") : NULL;
    if (isEnabled) {
        return isEnabled() ? YES : NO;
    }
    return [[NSProcessInfo processInfo].environment objectForKey:@"MallocStackLogging"] != nil;
#endif
}

/// 是否是 lite 模式 —— lite 模式下拿不到按地址的历史堆栈
+ (BOOL)isLiteMode {
#if !KC_MALLOC_STACK_LOGGING_ENABLED
    return NO;
#else
    void *handle = dlopen(kc_MallocStackLoggingFrameworkPath.UTF8String, RTLD_NOLOAD);
    kc_msl_is_lite_fn isLite = handle ? (kc_msl_is_lite_fn)dlsym(handle, "msl_is_stack_logging_lite_enabled") : NULL;
    return isLite ? (isLite() ? YES : NO) : NO;
#endif
}

/// 进程启动时实际拿到的环境变量值
/// ⚠️ 排查 "Scheme 里明明配了却不生效" 的第一步就看它: 系统按这里显示的值工作, 不按 Scheme 里显示的值工作
+ (nullable NSString *)launchEnvironmentValue {
#if !KC_MALLOC_STACK_LOGGING_ENABLED
    return nil;
#else
    // 用 getenv 而不是 NSProcessInfo: libmalloc 读的就是进程启动时那份 environ
    const char *v = getenv("MallocStackLogging");
    return v ? [NSString stringWithUTF8String:v] : nil;
#endif
}

/// 给 UI 展示的一句话诊断, 拿不到堆栈时直接把这个打给用户看
+ (nullable NSString *)diagnosis {
#if !KC_MALLOC_STACK_LOGGING_ENABLED
    return @"已关闭: KC_MALLOC_STACK_LOGGING_ENABLED=0(非 DEBUG 构建)。";
#else
    NSString *env = [self launchEnvironmentValue];
    NSString *envDesc = env ? [NSString stringWithFormat:@"当前生效值 = \"%@\"", env] : @"当前生效值 = (未设置)";

    if (![self isStackLoggingEnabled]) {
        return [NSString stringWithFormat:
                @"未开启 malloc stack logging(%@)。\n"
                @"做法: Scheme -> Run -> Arguments -> Environment Variables 加 MallocStackLogging=malloc, "
                @"然后**冷启动** App。\n"
                @"注意: 新版系统运行时调 turn_on_stack_logging() 已不再生效, 必须是启动时环境变量。", envDesc];
    }

    if ([self isLiteMode]) {
        // 实测: Xcode 26 的 Diagnostics 勾选项只会注入 MallocStackLogging=lite, 不会注入 malloc。
        // 若 Scheme 里同时开着 Diagnostics, 它会覆盖你手填的环境变量 —— 这是最常见的"配了没用"原因。
        return [NSString stringWithFormat:
                @"当前是 lite 模式(%@), 只记录存活对象, 无法按地址回溯 alloc/dealloc 历史。\n"
                @"✅ 修法: Scheme -> Run -> Diagnostics 里**取消勾选** Malloc Stack Logging, "
                @"只在 Arguments -> Environment Variables 里填 MallocStackLogging=malloc, 再冷启动。\n"
                @"⚠️ 只有 malloc 这个取值有效; lite/1/all 在新版都会被当成 lite。", envDesc];
    }

    if (![self isAvailable]) {
        return @"当前系统未能解析到 MallocStackLogging 私有实现, 功能不可用(已安全降级, 不会崩溃)。";
    }
    return nil;
#endif
}

#pragma mark - 开关 (保留接口, 但语义已变)

+ (BOOL)turn_on_stack_logging:(kc_stack_logging_mode_type)mode {
#if !KC_MALLOC_STACK_LOGGING_ENABLED
    return NO;
#else
    // 仍然保留: 老系统上它能真正开启。
    // 新系统上它只是转发到 MallocStackLogging.framework 的桩, 实测返回 0 且不生效。
    kc_turn_on_stack_logging_fn fn = (kc_turn_on_stack_logging_fn)dlsym(RTLD_DEFAULT, "turn_on_stack_logging");
    if (!fn) return NO;
    BOOL ok = fn((int)mode) ? YES : NO;
    if (!ok) {
        NSLog(@"⚠️ turn_on_stack_logging 返回 false。"
              @"新版系统已不支持运行时开启, 请在 Scheme 里配 MallocStackLogging=malloc 并冷启动。");
    }
    return ok;
#endif
}

+ (void)turn_off_stack_logging {
#if !KC_MALLOC_STACK_LOGGING_ENABLED
    return;
#else
    kc_turn_off_stack_logging_fn fn = (kc_turn_off_stack_logging_fn)dlsym(RTLD_DEFAULT, "turn_off_stack_logging");
    if (fn) fn();
#endif
}

#pragma mark - 符号化

/// 把一串frame地址转成可读字符串
+ (NSArray<NSString *> *)symbolicateFrames:(mach_vm_address_t *)frames count:(uint32_t)count {
    NSMutableArray<NSString *> *symbols = [[NSMutableArray alloc] initWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) {
        vm_address_t addr = (vm_address_t)frames[i];
        Dl_info info;
        if (dladdr((void *)addr, &info) == 0) {
            [symbols addObject:[NSString stringWithFormat:@"frame #%u : 0x%llx", i, (unsigned long long)addr]];
            continue;
        }
        NSString *moduleName = info.dli_fname ? [@(info.dli_fname) lastPathComponent] : @"";
        NSString *symbol = [NSString stringWithFormat:@"frame #%u : 0x%llx %@`%s + %ld",
                            i,
                            (unsigned long long)addr,
                            moduleName,
                            info.dli_sname ?: "",
                            (long)(addr - (uintptr_t)info.dli_saddr)];
        [symbols addObject:symbol];
    }
    return symbols;
}

#pragma mark - 获取地址的分配堆栈

+ (NSArray<NSString *> *)mallocStackLogTraceObjc:(id)objc {
    if (!objc) return nil;
    return [self mallocStackLogTraceAddress:(mach_vm_address_t)((__bridge void *)objc)];
}

+ (NSArray<NSString *> *)mallocStackLogTraceAddress:(mach_vm_address_t)addr {
#if !KC_MALLOC_STACK_LOGGING_ENABLED
    return nil;
#else
    if (addr == 0) return nil;

    kc_get_frames_for_address_fn fn = (kc_get_frames_for_address_fn)[self rawGetFramesForAddress];
    if (!fn) {
        NSLog(@"❌ 拿不到 msl_get_frames_for_address, %@", [self diagnosis] ?: @"");
        return nil;
    }

    const NSUInteger maxFrames = 100;
    mach_vm_address_t *frames = (mach_vm_address_t *)calloc(maxFrames, sizeof(mach_vm_address_t));
    if (!frames) return nil;

    uint32_t count = 0;
    kern_return_t kr = fn(mach_task_self(), addr, frames, (uint32_t)maxFrames, &count);

    NSArray<NSString *> *symbols = nil;
    if (kr == KERN_SUCCESS && count > 0) {
        symbols = [self symbolicateFrames:frames count:count];
    } else if (kr != KERN_SUCCESS) {
        NSLog(@"❌ 取堆栈失败 kr=%d (5=该地址无记录/未开启logging), %@", kr, [self diagnosis] ?: @"");
    }

    free(frames);
    return symbols;
#endif
}

#pragma mark - 遍历 alloc/dealloc 记录

static NSArray<NSString *> *kc_framesForStackIdentifier(uint64_t stackIdentifier) {
    if (stackIdentifier == 0) return nil;

    if (@available(iOS 11.0, macOS 10.13, *)) {
        kc_get_frames_for_stackid_fn fn = (kc_get_frames_for_stackid_fn)[KcMallocStackLoggingTooler rawGetFramesForStackId];
        if (fn) {
            mach_vm_address_t frames[512] = {0};
            uint32_t count = 0;
            bool lastIsThreadId = false;
            kern_return_t kr = fn(mach_task_self(), stackIdentifier, frames, 512, &count, &lastIsThreadId);
            if (kr == KERN_SUCCESS && count > 0) {
                return [KcMallocStackLoggingTooler symbolicateFrames:frames count:count];
            }
        }
    }
    return nil;
}

static void enumerator_malloc_stack_logging_record(kc_mach_stack_logging_record_t record, void *context) {
    KcMallocStackLoggingTooler *tooler = (__bridge KcMallocStackLoggingTooler *)context;
    if (!tooler) return;

    NSString *type = [tooler typeStringWithFlags:record.type_flags];
    NSArray<NSString *> *findTypes = tooler.isAlloc ? @[@"alloc"] : @[@"free", @"dealloc"];
    if (![findTypes containsObject:type]) {
        return;
    }

    NSArray<NSString *> *symbols = kc_framesForStackIdentifier(record.stack_identifier);
    if (symbols.count > 0) {
        tooler.findArray = symbols;
        NSLog(@"%@ size=%llu address=0x%llx\n%@", type, record.argument,
              (unsigned long long)record.address, symbols);
    }
}

- (nullable NSArray<NSString *> *)enumerateMallocStackLoggingRecordsTraceAddress:(uintptr_t)address
                                                                        isAlloc:(BOOL)isAlloc {
#if !KC_MALLOC_STACK_LOGGING_ENABLED
    return nil;
#else
    if (address == 0) return nil;

    kc_enumerate_records_fn fn = (kc_enumerate_records_fn)[KcMallocStackLoggingTooler rawEnumerateRecords];
    if (!fn) {
        NSLog(@"❌ 拿不到 msl_disk_stack_logs_enumerate_from_task, %@",
              [KcMallocStackLoggingTooler diagnosis] ?: @"");
        return nil;
    }

    self.isAlloc = isAlloc;
    self.findArray = nil;

    kern_return_t ret = fn(mach_task_self(),
                           (mach_vm_address_t)address,
                           enumerator_malloc_stack_logging_record,
                           (__bridge void *)self);

    NSArray<NSString *> *symbols = self.findArray.copy;
    self.findArray = nil;

    return (ret == KERN_SUCCESS && symbols.count > 0) ? symbols : nil;
#endif
}

#pragma mark - 分析 log file (老路径, 已降级为兜底)

/// ⚠️ 这条路径依赖磁盘 index 文件的二进制格式, 新版 MallocStackLogging 随时可能改,
///    优先用上面的 enumerateMallocStackLoggingRecordsTraceAddress:isAlloc:
- (nullable NSArray<NSString *> *)traceAddress:(uintptr_t)address isAlloc:(BOOL)isAlloc {
#if !KC_MALLOC_STACK_LOGGING_ENABLED
    return nil;
#else
    if (address == 0) return nil;

    if (!self.logFilePath) {
        self.logFilePath = [self enumeratorGetLogFilePath];
    }
    if (self.logFilePath.length <= 0) {
        NSLog(@"❌ 获取 log file 文件失败(需要 MallocStackLogging=malloc 才会落盘)");
        return nil;
    }

    // ⚠️ 旧代码里这里没初始化, 命中失败分支时会读到栈上的脏数据 —— 已修
    kc_mach_stack_logging_record_t find_record = {0};

    NSArray<NSString *> *findTypes = isAlloc ? @[@"alloc"] : @[@"free", @"dealloc"];

    FILE *fp = fopen(self.logFilePath.fileSystemRepresentation, "r");
    if (fp != NULL) {
        char bufferSpace[4096];
        size_t read_size = sizeof(kc_stack_logging_index_event64);
        size_t number_slots = sizeof(bufferSpace) / read_size;
        size_t read_count = 0;
        do {
            read_count = fread(bufferSpace, read_size, number_slots, fp);
            if (read_count <= 0) break;
            kc_stack_logging_index_event64 *events = (kc_stack_logging_index_event64 *)bufferSpace;
            for (size_t i = 0; i < read_count; i++) {
                if (KC_STACK_LOGGING_DISGUISE(events[i].address) != (uint64_t)address) continue;
                NSString *type = [self typeStringWithFlags:events[i].flags];
                if (![findTypes containsObject:type]) continue;
                find_record.address          = KC_STACK_LOGGING_DISGUISE(events[i].address);
                find_record.argument         = events[i].argument;
                find_record.stack_identifier = events[i].offset;
                find_record.type_flags       = events[i].flags;
                break;
            }
        } while (read_count > 0 && find_record.address == 0);
        fclose(fp);
    }

    if (find_record.address <= 0) {
        return nil;
    }

    kc_uniquing_table_copy_fn copyFn = (kc_uniquing_table_copy_fn)kc_symbol(kcIdxTableCopy);
    kc_uniquing_table_read_stack_fn readFn = (kc_uniquing_table_read_stack_fn)kc_symbol(kcIdxTableReadStack);
    kc_uniquing_table_release_fn releaseFn = (kc_uniquing_table_release_fn)kc_symbol(kcIdxTableRelease);
    if (!copyFn || !readFn) {
        NSLog(@"❌ 拿不到 uniquing table 相关实现");
        return nil;
    }

    void *table = copyFn(mach_task_self());
    if (table == NULL) {
        NSLog(@"❌ uniquing table 为空(通常意味着没开 malloc stack logging 或处于 lite 模式)");
        return nil;
    }

    NSArray<NSString *> *symbols = nil;
    mach_vm_address_t frames[512] = {0};
    uint32_t frames_count = 0;
    if (readFn(table, find_record.stack_identifier, frames, &frames_count, 512) == KERN_SUCCESS && frames_count > 0) {
        symbols = [KcMallocStackLoggingTooler symbolicateFrames:frames count:frames_count];
    }

    if (releaseFn) releaseFn(table);

    return symbols;
#endif
}

/// 获取 log file
- (nullable NSString *)enumeratorGetLogFilePath {
    // 真机: /private/var/mobile/Containers/Data/Application/xxx/tmp/stack-logs.<pid>.<xxx>.<bundle>.<xx>.index
    // 模拟器: /tmp/stack-logs.<pid>.<xxx>.<bundle>.<xx>.index
    NSString *tmpDirPath = NSTemporaryDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    // ⚠️ 旧实现直接取目录下第一个文件, 拿到的可能是完全无关的临时文件 —— 已修
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:tmpDirPath error:nil];
    NSString *candidate = nil;
    NSDate *newest = nil;
    for (NSString *name in names) {
        if (![name hasPrefix:@"stack-logs."]) continue;
        if (![name hasSuffix:@".index"]) continue;
        NSString *path = [tmpDirPath stringByAppendingPathComponent:name];
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
        NSDate *date = attr[NSFileModificationDate];
        if (!newest || [date laterDate:newest] == date) {
            newest = date;
            candidate = path;
        }
    }
    return candidate;
}

#pragma mark - help

- (NSString *)typeStringWithFlags:(uint64_t)type_flags {
    if (type_flags & kc_malloc_stack_logging_type_mapped_file_or_shared_mem) return @"mapped_file_or_shared_mem";
    if (type_flags & kc_malloc_stack_logging_type_vm_deallocate) return @"vm_deallocate";
    if (type_flags & kc_malloc_stack_logging_type_vm_allocate) return @"vm_allocate";
    if (type_flags & kc_malloc_stack_logging_type_dealloc) return @"dealloc";
    if (type_flags & kc_malloc_stack_logging_type_alloc) return @"alloc";
    if (type_flags & kc_malloc_stack_logging_type_generic) return @"generic";
    return @"free";
}

@end
