//
//  KcMallocStackLoggingTooler.m
//  KcDebugTool
//
//  Created by 张杰 on 2023/9/14.
//  参考: libmalloc-317.140.5 stack_logging.h
//  iOS 写一个MallocStackLogging日志离线分析 https://juejin.cn/post/7042267275151278087

#import "KcMallocStackLoggingTooler.h"
#include <malloc/malloc.h>
#import <dlfcn.h>
#include <mach/mach.h>

#define kc_malloc_stack_logging_type_free        0
#define kc_malloc_stack_logging_type_generic    1    /* anything that is not allocation/deallocation */
#define kc_malloc_stack_logging_type_alloc    2    /* malloc, realloc, etc... */
#define kc_malloc_stack_logging_type_dealloc    4    /* free, realloc, etc... */
#define kc_malloc_stack_logging_type_vm_allocate  16      /* vm_allocate or mmap */
#define kc_malloc_stack_logging_type_vm_deallocate  32    /* vm_deallocate or munmap */
#define kc_malloc_stack_logging_type_mapped_file_or_shared_mem    128

typedef struct {
    uint64_t argument;
    uint64_t address;
    uint64_t offset;
    uint64_t flags;
} kc_stack_logging_index_event64;

typedef struct mach_stack_logging_record {
//    uint32_t        type_flags;   我猜测这里也已经是64位了
    uint64_t        type_flags;
    uint64_t        stack_identifier;
    /// 内存的大小
    uint64_t        argument;
    mach_vm_address_t    address;
} kc_mach_stack_logging_record_t;

#define KC_STACK_LOGGING_DISGUISE(address)    ((address) ^ 0x00005555) /* nicely idempotent */

extern void __mach_stack_logging_uniquing_table_release(void *);

// struct backtrace_uniquing_table
extern void *__mach_stack_logging_copy_uniquing_table(task_t task);

extern kern_return_t __mach_stack_logging_uniquing_table_read_stack(void *uniquing_table,
                                               uint64_t stackid,
                                               mach_vm_address_t *out_frames_buffer,
                                               uint32_t *out_frames_count,
                                               uint32_t max_frames);

extern kern_return_t __mach_stack_logging_enumerate_records(task_t task, mach_vm_address_t address, void enumerator(kc_mach_stack_logging_record_t, void *), void *context);

extern kern_return_t __mach_stack_logging_frames_for_uniqued_stack(task_t task, uint64_t stack_identifier, mach_vm_address_t *stack_frames_buffer, uint32_t max_stack_frames, uint32_t *count)
    API_DEPRECATED("use __mach_stack_logging_get_frames_for_stackid instead", macos(10.9, 10.13), ios(7.0, 11.0), watchos(1.0, 4.0), tvos(9.0, 11.0));
    /* Given a uniqued_stack fills stack_frames_buffer. */

extern kern_return_t __mach_stack_logging_get_frames_for_stackid(task_t task, uint64_t stack_identifier, mach_vm_address_t *stack_frames_buffer, uint32_t max_stack_frames, uint32_t *count,
                                                                     bool *last_frame_is_threadid)
    API_AVAILABLE(macos(10.13), ios(11.0), watchos(4.0), tvos(11.0));
    /* Given a uniqued_stack fills stack_frames_buffer. */

extern boolean_t turn_on_stack_logging(kc_stack_logging_mode_type mode);
extern void turn_off_stack_logging(void);

extern kern_return_t __mach_stack_logging_get_frames(task_t task, mach_vm_address_t address, mach_vm_address_t *stack_frames_buffer, uint32_t max_stack_frames, uint32_t *count);

@interface KcMallocStackLoggingTooler ()

@property (nonatomic, copy, nullable) NSString *logFilePath;

@property (nonatomic, assign) BOOL isAlloc;

@property (nonatomic, strong, nullable) NSArray<NSString *> *findArray;

@end

@implementation KcMallocStackLoggingTooler

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static KcMallocStackLoggingTooler *m;
    dispatch_once(&onceToken, ^{
        m = [[KcMallocStackLoggingTooler alloc] init];
    });
    return m;
}

+ (BOOL)turn_on_stack_logging:(kc_stack_logging_mode_type)mode {
    return turn_on_stack_logging(mode);
}

+ (void)turn_off_stack_logging {
    turn_off_stack_logging();
}

/// 获取地址的初始化堆栈
/// 这个需要打开 malloc stack logging - all allocation
+ (NSArray<NSString *> *)mallocStackLogTraceObjc:(id)objc {
    return [self mallocStackLogTraceAddress:(mach_vm_address_t)((__bridge void *)objc)];
}

typedef struct KcLLDBStackAddress {
  mach_vm_address_t *addresses;
  uint32_t count;
} KcLLDBStackAddress;   // 1

/// 获取地址的初始化堆栈
/// 这个需要打开 malloc stack logging - all allocation
+ (NSArray<NSString *> *)mallocStackLogTraceAddress:(mach_vm_address_t)addr {
    KcLLDBStackAddress stackaddress; // 2
    __unused mach_vm_address_t address = (mach_vm_address_t)addr;
    __unused task_t task = mach_task_self_;  // 3
    stackaddress.count = 0;
    stackaddress.addresses = (mach_vm_address_t *)calloc(100, sizeof(mach_vm_address_t));
  
    // remote_task_file_streams *remote_fd = retain_file_streams_for_task(task, 0);
    // 从这可以看出读的是file, 必须打开包含free的log才会写日志
    kern_return_t err = __mach_stack_logging_get_frames(task,
                                                        address,
                                                        stackaddress.addresses,
                                                        100,
                                                        &stackaddress.count); // 5
    if (err == 0) {
        
        NSMutableArray<NSString *> *symbols = [[NSMutableArray alloc] init];
        
        for (int i = 0; i < stackaddress.count; i++) {
            vm_address_t addr = stackaddress.addresses[i];
            Dl_info info;
            dladdr((void *)addr, &info);
            
            NSString *moduleName = [@(info.dli_fname) lastPathComponent];
            
            NSString *symbol = [NSString stringWithFormat:@"frame #%d : 0x%lx %@`%s + %ld", i, addr, moduleName, info.dli_sname, addr - (uintptr_t)info.dli_saddr];
            
            [symbols addObject:symbol];
        }
        
        free(stackaddress.addresses); // 7
        stackaddress.addresses = nil;
        
        return symbols;
    } else {
        free(stackaddress.addresses); // 7
        stackaddress.addresses = nil;
        
        return nil;
    }
}

static void enumerator_malloc_stack_logging_record(kc_mach_stack_logging_record_t record, void *context) {
    
    KcMallocStackLoggingTooler *tooler = (__bridge KcMallocStackLoggingTooler *)context;
    
    NSString *type = [tooler typeStringWithFlags:record.type_flags];
    NSArray<NSString *> *findTypes = tooler.isAlloc ? @[@"alloc"] : @[@"free", @"dealloc"];
    
//    NSLog(@"---------------------------");
    NSLog(@"%@: %llu, %llu, address: %llu", type, record.type_flags, record.argument, record.address);
    
    if (![findTypes containsObject:type]) {
        return;
    }
    
    mach_vm_address_t frames[512];
    uint32_t frames_count;
    kern_return_t result;
    if (@available(iOS 11.0, *)) {
        result = __mach_stack_logging_get_frames_for_stackid(mach_task_self(), record.stack_identifier, frames, 512, &frames_count, nil);
    } else {
        result = __mach_stack_logging_frames_for_uniqued_stack(mach_task_self(), record.stack_identifier, frames, 512, &frames_count);
    }
    
    if (result == KERN_SUCCESS && frames_count > 0) {
        NSMutableArray<NSString *> *symbols = [[NSMutableArray alloc] init];
        for (int i = 0; i < frames_count; i++) {
            vm_address_t addr = frames[i];
            Dl_info info;
            dladdr((void *)addr, &info);
            
            NSString *moduleName = [@(info.dli_fname) lastPathComponent];
            
            NSString *symbol = [NSString stringWithFormat:@"frame #%d : 0x%lx %@`%s + %ld", i, addr, moduleName, info.dli_sname, addr - (uintptr_t)info.dli_saddr];
            
            [symbols addObject:symbol];
        }
        
        tooler.findArray = symbols;
        
        NSLog(@"%@", symbols);
    }
}

/// 获取address的alloc/dealloc的堆栈
/// 通过 __mach_stack_logging_enumerate_records 遍历记录
/* 说明
 存在问题⚠️:
 1、由于address这块内存可能被alloc、dealloc很多次，这就导致不知道取的是那一次的值
 2、对于还存活的对象
    * alloc取的是最后一个
    * dealloc 没值
 3、对于已经free的对象
    * alloc不知道取的是哪一次，因为这个address可能已经被其他对象使用了，这就导致又alloc了，而且可能alloc了很多次，so你不知道取那一次
    * dealloc跟alloc一样也是同样的问题
 4、__mach_stack_logging_enumerate_records接口，传入的回调函数，不知道有多少个匹配stack，这就导致使用效率很低，因为存在很多次分配释放内存
    * 取巧做法: 调用2次__mach_stack_logging_enumerate_records方法，第一次在回调函数中记录count数量，第2次根据count判断才取值；可__mach_stack_logging_enumerate_records存在file读的问题，可能调用2次性能更差。
 */
- (nullable NSArray<NSString *> *)enumerateMallocStackLoggingRecordsTraceAddress:(uintptr_t)address isAlloc:(BOOL)isAlloc {
    self.isAlloc = isAlloc;
    self.findArray = nil;
    
    kern_return_t ret = __mach_stack_logging_enumerate_records(mach_task_self(), address, enumerator_malloc_stack_logging_record, (__bridge void *)self);
    
    NSArray<NSString *> *symbols = self.findArray.copy;
    self.findArray = nil;
    
    return ret == KERN_SUCCESS ? symbols : nil;
}

#pragma mark - 分析log file

- (nullable NSArray<NSString *> *)traceAddress:(uintptr_t)address isAlloc:(BOOL)isAlloc {
    if (!self.logFilePath) {
        // 获取的log file不一定是这一次生成的⚠️, 因为目录下可能存在多个
        self.logFilePath = [self enumeratorGetLogFilePath];
    }
    
    if (!self.logFilePath || self.logFilePath.length <= 0) {
        NSLog(@"❌ 获取 log file 文件失败");
        return nil;
    }
    
    const char *path = [self.logFilePath cStringUsingEncoding:4];
    FILE *fp = fopen(path,  "r");
    
    char bufferSpace[4096];
    size_t read_count = 0;
    size_t read_size = sizeof(kc_stack_logging_index_event64);
    size_t number_slots = (size_t)(4096 / read_size);

    //最后一条person的内存分配记录
    kc_mach_stack_logging_record_t find_record;
    
    NSArray<NSString *> *findTypes = isAlloc ? @[@"alloc"] : @[@"free", @"dealloc"];
    
    if (fp != NULL) {
        do {
            read_count = fread(bufferSpace, read_size, number_slots, fp);
            if (read_count > 0) {
                kc_stack_logging_index_event64 *target_64_index = (kc_stack_logging_index_event64 *)bufferSpace;
                for (int i = 0; i < read_count; i++) {
                    kc_stack_logging_index_event64 index_event = target_64_index[i];
                    kc_mach_stack_logging_record_t pass_record;
                    pass_record.address = KC_STACK_LOGGING_DISGUISE(index_event.address);
                    pass_record.argument = target_64_index[i].argument;
                    pass_record.stack_identifier = index_event.offset;
                    pass_record.type_flags = index_event.flags;
                    
                    NSString *type = [self typeStringWithFlags:pass_record.type_flags];
                    if (pass_record.address == address && [findTypes containsObject:type]) {
                        find_record = pass_record;
                        break;
                    }
                }
            }
        } while (read_count > 0);
        
        fclose(fp);
    }
    
    if (find_record.address <= 0) {
        return nil;
    }
    
    //用系统api拷贝一份哈希表出来
    void *table = __mach_stack_logging_copy_uniquing_table(mach_task_self());
    if (table == NULL) {
        return nil;
    }
    
    NSMutableArray<NSString *> *symbols = [[NSMutableArray alloc] init];
    
    //用系统api 使用stack_id 查找 堆栈信息
    mach_vm_address_t frames[512];
    uint32_t frames_count;
    // 从表中查询 堆栈
    kern_return_t ret = __mach_stack_logging_uniquing_table_read_stack(table, find_record.stack_identifier, frames, &frames_count, 512);
    if (ret == KERN_SUCCESS) {
        if (frames_count > 0) {
            for (int i = 0; i < frames_count; i++) {
                vm_address_t addr = frames[i];
                Dl_info info;
                dladdr((void *)addr, &info);
                
                NSString *moduleName = [@(info.dli_fname) lastPathComponent];
                
                NSString *symbol = [NSString stringWithFormat:@"frame #%d : 0x%lx %@`%s + %ld", i, addr, moduleName, info.dli_sname, addr - (uintptr_t)info.dli_saddr];
                
                [symbols addObject:symbol];
            }
        }
    } else {
        NSLog(@"__mach_stack_logging_uniquing_table_read_stack 调用失败❎");
    }
    
    //释放哈希表
    __mach_stack_logging_uniquing_table_release(table);
    
    return symbols;
}

/// 获取log file
- (nullable NSString *)enumeratorGetLogFilePath {

    // 真机: /private/var/mobile/Containers/Data/Application/D10B3C05-C58E-4DFD-8CDB-40A5A866CAE6/tmp/stack-logs.31597.10508c000.KcDebugTool_Example.b6910H.index
    // 模拟器: /tmp/stack-logs.66911.103004000.KcDebugTool_Example.sI2X6i.index
    // 里面有很多文件, 根本不知道哪个是这次的
    NSString *tmpDirPath = NSTemporaryDirectory();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *dirEnum = [fm enumeratorAtPath:tmpDirPath];
    NSString *fileName;
    NSString *filePath;
    while ((fileName = [dirEnum nextObject]) != nil) {
        filePath = [NSString stringWithFormat:@"%@%@",tmpDirPath,fileName];
//        NSLog(@"aa --- %@", filePath);
        break;
    }
    return filePath;
}

#pragma mark - help

- (NSString *)typeStringWithFlags:(uint64_t)type_flags {
    if (type_flags & kc_malloc_stack_logging_type_free) return @"free";
    if (type_flags & kc_malloc_stack_logging_type_generic) return @"generic";
    if (type_flags & kc_malloc_stack_logging_type_alloc) return @"alloc";
    if (type_flags & kc_malloc_stack_logging_type_dealloc) return @"dealloc";
    if (type_flags & kc_malloc_stack_logging_type_vm_allocate) return @"vm_allocate";
    if (type_flags & kc_malloc_stack_logging_type_vm_deallocate) return @"vm_deallocate";
    if (type_flags & kc_malloc_stack_logging_type_mapped_file_or_shared_mem) return @"mapped_file_or_shared_mem";
    return @"unknow";
}

@end
