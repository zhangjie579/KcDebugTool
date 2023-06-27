//
//  KcEnergyMonitor.m
//  Pods
//
//  Created by 张杰 on 2023/6/26.
//

#import "KcEnergyMonitor.h"
#import <mach/mach.h>
#import "SMCallStack.h"

@interface KcEnergyMonitor ()

@property (nonatomic, strong) NSThread *thread;

/// 休眠时间
@property (nonatomic, assign) float sleepTime;

@property (atomic, assign) BOOL isMonitor;

//@property (nonatomic, strong) NSMutableArray<NSNumber *> *CPUDatas;

@property (nonatomic, assign) float *CPUDatas;

/// 游标, 当前写入位置
@property (nonatomic, assign) NSInteger currentIndex;

@end

@implementation KcEnergyMonitor

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    static KcEnergyMonitor *monitor;
    dispatch_once(&onceToken, ^{
        monitor = [[KcEnergyMonitor alloc] init];
    });
    return monitor;
}

- (instancetype)init {
    if (self = [super init]) {
        self.sleepTime = 1;
        self.isMonitor = false;
        self.CPUDatas = calloc(8, sizeof(float));
        self.currentIndex = 0;
        self.thresholdUsedCPU = 0.8;
    }
    return self;
}

- (void)dealloc {
    free(self.CPUDatas);
    self.CPUDatas = nil;
}

- (void)start {
//    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, <#dispatchQueue#>);
//    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, <#intervalInSeconds#> * NSEC_PER_SEC, <#leewayInSeconds#> * NSEC_PER_SEC);
//    dispatch_source_set_event_handler(timer, ^{
//        <#code to be executed when timer fires#>
//    });
//    dispatch_resume(timer);
    if (self.isMonitor) {
        return;
    }
    
    self.isMonitor = true;
    
    NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(observerCPU) object:nil];
    self.thread = thread;
    
    [thread start];
}

- (void)observerCPU {
    while (self.isMonitor) {
        // CPU的情况 - 满足5/8窗口，抓取堆栈
        float usedCPU = [KcEnergyMonitor cpuUsageForApp];
        if (usedCPU >= self.thresholdUsedCPU) {
            NSInteger count = [self countGreaterThanUsedCPUThreshold];
            if (count >= 4) { // 抓堆栈
                NSString *callStack = [SMCallStack callStackWithType:SMCallStackTypeAll isRunning:true isFilterCurrentThread:true];
                NSLog(@"❌❌❌ 高CPU ❌❌❌\n%@", callStack);
            }
        }
        
        self.CPUDatas[self.currentIndex] = usedCPU;
        self.currentIndex = self.currentIndex >= 7 ? 0 : self.currentIndex + 1;
        
        usleep(self.sleepTime * 1000000);
    }
}

- (void)stop {
    self.isMonitor = false;
}

#pragma mark - private

- (NSInteger)countGreaterThanUsedCPUThreshold {
    
    NSInteger count = 0;
    
//    for (NSInteger i = 1; i < 5; i++) {
//        NSInteger index = (self.currentIndex - i + 8) % 8;
//        if (self.CPUDatas[index] >= self.thresholdUsedCPU) {
//            ++count;
//        }
//    }
    
    for (NSInteger i = 0; i < 8; i++) {
        if (self.CPUDatas[i] >= self.thresholdUsedCPU) {
            ++count;
        }
    }
    
    return count;
}

+ (float)cpuUsageForApp {
    kern_return_t kr;
    thread_array_t         thread_list;
    mach_msg_type_number_t thread_count;
    thread_info_data_t     thinfo;
    mach_msg_type_number_t thread_info_count;
    thread_basic_info_t basic_info_th;
    
    // get threads in the task
    //  获取当前进程中 线程列表
    kr = task_threads(mach_task_self(), &thread_list, &thread_count);
    if (kr != KERN_SUCCESS)
        return -1;

    float tot_cpu = 0;
    
    for (int j = 0; j < thread_count; j++) {
        thread_info_count = THREAD_INFO_MAX;
        //获取每一个线程信息
        kr = thread_info(thread_list[j], THREAD_BASIC_INFO,
                         (thread_info_t)thinfo, &thread_info_count);
        if (kr != KERN_SUCCESS)
            return -1;
        
        basic_info_th = (thread_basic_info_t)thinfo;
        if (!(basic_info_th->flags & TH_FLAGS_IDLE)) {
            // cpu_usage : Scaled cpu usage percentage. The scale factor is TH_USAGE_SCALE.
            //宏定义TH_USAGE_SCALE返回CPU处理总频率：
            tot_cpu += basic_info_th->cpu_usage / (float)TH_USAGE_SCALE;
        }
        
    } // for each thread
    
    // 注意方法最后要调用 vm_deallocate，防止出现内存泄漏
    kr = vm_deallocate(mach_task_self(), (vm_offset_t)thread_list, thread_count * sizeof(thread_t));
    assert(kr == KERN_SUCCESS);
    
    if (tot_cpu < 0) {
        tot_cpu = 0.;
    }
    
    return tot_cpu;
}

@end
