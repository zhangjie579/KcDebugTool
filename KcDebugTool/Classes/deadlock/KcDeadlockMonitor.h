#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KcDeadlockReport : NSObject
/// highCPU / dependencyCycle / longWait / mainThreadStall
@property (nonatomic, copy, readonly) NSString *kind;
@property (nonatomic, copy, readonly) NSString *reason;
/// 可序列化的采样、依赖边、时间等原始证据。
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *evidence;
/// 含线程 ID、地址、镜像、符号和偏移的可读报告。
@property (nonatomic, copy, readonly) NSString *dump;
@end

@interface KcDeadlockMonitor : NSObject
/// 100 表示占满一个逻辑核。默认：0.5 秒采样、80%、连续 3 次、等待 3 秒。
- (instancetype)initWithReportHandler:(void (^)(KcDeadlockReport *report))handler;
/// interval: 0.05...60 秒；CPUThreshold: (0, 100]；waitThreshold >= interval。
- (instancetype)initWithSampleInterval:(NSTimeInterval)interval
                         CPUThreshold:(double)CPUThreshold
                        waitThreshold:(NSTimeInterval)waitThreshold
                        reportHandler:(void (^)(KcDeadlockReport *report))handler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// 幂等。回调运行在专用监控队列，必须快速返回，勿同步等待主线程或业务锁。
- (void)start;
- (void)stop;

/// 稳定的内核线程 ID，而非 Mach port name；可在预期的 signal/执行线程上提前记录。
+ (uint64_t)currentThreadID;
/// 显式声明“当前线程即将阻塞，完成依赖于 targetThreadID”。只能有一个未结束的等待。
/// 仅在确知执行/唤醒线程时使用；不是自动推断 semaphore 或 GCD 队列的所有者。
/// 必须在 @try/@finally 中配对 endWaiting:；过期依赖会造成错误报告。
+ (NSUUID *)beginWaitingForThread:(uint64_t)targetThreadID reason:(NSString *)reason;
+ (void)endWaiting:(NSUUID *)token;
@end

NS_ASSUME_NONNULL_END
