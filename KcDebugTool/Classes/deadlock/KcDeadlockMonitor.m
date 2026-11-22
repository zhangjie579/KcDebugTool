#import "KcDeadlockMonitor.h"
#import "KcDeadlockInternal.h"
#import "KcThreadSampler.h"
#import <pthread.h>
#import <math.h>

pthread_mutex_t KcDependencyMutex = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *KcOwners;
static NSMutableDictionary<NSNumber *, NSDictionary *> *KcWaits;
static void KcPrepareGraph(void) {
    if (!KcOwners) KcOwners = [NSMutableDictionary dictionary];
    if (!KcWaits) KcWaits = [NSMutableDictionary dictionary];
}
static NSTimeInterval KcNow(void) { return NSProcessInfo.processInfo.systemUptime; }
uint64_t KcDiagnosticThreadID(void) {
    uint64_t identity = 0;
    pthread_threadid_np(NULL, &identity);
    return identity;
}

void KcGraphAcquire(NSString *resource, NSString *name, uint64_t thread, NSArray *stack, NSDictionary *context) {
    KcPrepareGraph();
    NSMutableDictionary *owner = KcOwners[resource];
    if (owner) {
        owner[@"depth"] = @([owner[@"depth"] unsignedIntegerValue] + 1);
    } else {
        KcOwners[resource] = [@{@"threadID": @(thread), @"resource": resource, @"name": name,
                              @"depth": @1, @"acquisitionStack": stack, @"ownerContext": context} mutableCopy];
    }
}
void KcGraphRelease(NSString *resource, uint64_t thread) {
    NSMutableDictionary *owner = KcOwners[resource];
    if (!owner || [owner[@"threadID"] unsignedLongLongValue] != thread) {
        [NSException raise:NSInternalInconsistencyException format:@"KcTrackedLock must be unlocked by its owner"];
    }
    NSUInteger depth = [owner[@"depth"] unsignedIntegerValue];
    if (depth > 1) owner[@"depth"] = @(depth - 1);
    else [KcOwners removeObjectForKey:resource];
}
NSUUID *KcGraphWait(NSString *resource, uint64_t target, NSString *reason, NSArray *stack, NSDictionary *context) {
    KcPrepareGraph();
    uint64_t thread = KcDeadlockMonitor.currentThreadID;
    if (KcWaits[@(thread)]) {
        [NSException raise:NSInternalInconsistencyException format:@"End the previous dependency before declaring another wait"];
    }
    NSUUID *token = NSUUID.UUID;
    KcWaits[@(thread)] = @{@"threadID": @(thread), @"targetThreadID": @(target),
        @"resource": resource ?: @"", @"reason": reason, @"since": @(KcNow()),
        @"token": token.UUIDString, @"waitStack": stack, @"waitContext": context};
    return token;
}
void KcGraphEndWait(NSUUID *token) {
    for (NSNumber *thread in KcWaits.allKeys) {
        if ([KcWaits[thread][@"token"] isEqual:token.UUIDString]) {
            [KcWaits removeObjectForKey:thread];
            break;
        }
    }
}
NSArray<NSDictionary *> *KcGraphSnapshot(void) {
    pthread_mutex_lock(&KcDependencyMutex);
    NSMutableArray *edges = [NSMutableArray array];
    for (NSDictionary *wait in KcWaits.allValues) {
        NSMutableDictionary *edge = [wait mutableCopy];
        NSDictionary *owner = KcOwners[wait[@"resource"]];
        if (owner) {
            edge[@"targetThreadID"] = owner[@"threadID"];
            edge[@"acquisitionStack"] = owner[@"acquisitionStack"];
            edge[@"depth"] = owner[@"depth"];
            edge[@"ownerContext"] = owner[@"ownerContext"];
        }
        [edges addObject:[edge copy]];
    }
    pthread_mutex_unlock(&KcDependencyMutex);
    return edges;
}

// 上下文来自锁获取/等待事件，不从监控队列查询业务队列，也不缓存成线程的永久属性。
static NSString *KcDescribeThread(NSNumber *identity, NSDictionary *sample, NSDictionary *context) {
    NSString *name = context[@"threadName"];
    if (!name.length || [name isEqualToString:@"<unnamed>"]) name = sample[@"name"];
    NSMutableString *description = [NSMutableString stringWithFormat:@"线程 %@ [threadName=%@", identity,
                                    name.length ? name : @"<unnamed>"];
    if ([context[@"dispatchQueueLabel"] length]) [description appendFormat:@", gcd=%@", context[@"dispatchQueueLabel"]];
    if ([context[@"operationQueueName"] length]) [description appendFormat:@", operationQueue=%@", context[@"operationQueueName"]];
    [description appendString:@"]"];
    return description;
}

@interface KcDeadlockReport ()
@property (nonatomic, copy, readwrite) NSString *kind;
@property (nonatomic, copy, readwrite) NSString *reason;
@property (nonatomic, copy, readwrite) NSDictionary *evidence;
@property (nonatomic, copy, readwrite) NSString *dump;
@end
@implementation KcDeadlockReport
- (NSString *)description { return self.dump; }
@end

// 每次 start 独立的心跳，旧的主线程回调不会改写新会话。
@interface KcHeartbeat : NSObject
@property (atomic) BOOL acknowledged;
@property (nonatomic) NSTimeInterval sentAt;
@end
@implementation KcHeartbeat
@end

@implementation KcDeadlockMonitor {
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    NSTimeInterval _interval, _waitThreshold, _lastSampleTime;
    double _CPUThreshold;
    void (^_handler)(KcDeadlockReport *);
    NSDictionary<NSNumber *, NSDictionary *> *_previous;
    NSMutableDictionary<NSNumber *, NSMutableArray *> *_CPUHistory;
    NSMutableDictionary<NSString *, NSNumber *> *_lastReports;
    KcHeartbeat *_heartbeat;
    uint64_t _mainThreadID;
}
- (instancetype)initWithReportHandler:(void (^)(KcDeadlockReport *))handler {
    return [self initWithSampleInterval:0.5 CPUThreshold:80 waitThreshold:3 reportHandler:handler];
}
- (instancetype)initWithSampleInterval:(NSTimeInterval)interval CPUThreshold:(double)CPUThreshold
                        waitThreshold:(NSTimeInterval)waitThreshold reportHandler:(void (^)(KcDeadlockReport *))handler {
    if (!isfinite(interval) || interval < 0.05 || interval > 60 || !isfinite(CPUThreshold) ||
        CPUThreshold <= 0 || CPUThreshold > 100 || !isfinite(waitThreshold) || waitThreshold < interval || !handler) {
        [NSException raise:NSInvalidArgumentException format:@"Invalid deadlock monitor configuration"];
    }
    if ((self = [super init])) {
        _interval = interval;
        _CPUThreshold = CPUThreshold;
        _waitThreshold = waitThreshold;
        _handler = [handler copy];
        _queue = dispatch_queue_create("com.kcdebugtool.deadlock-monitor", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, (__bridge const void *)self, (__bridge void *)self, NULL);
    }
    return self;
}
+ (uint64_t)currentThreadID {
    return KcDiagnosticThreadID();
}
+ (NSUUID *)beginWaitingForThread:(uint64_t)targetThreadID reason:(NSString *)reason {
    if (!targetThreadID || !reason.length) {
        [NSException raise:NSInvalidArgumentException format:@"A known target thread and reason are required"];
    }
    NSArray *stack = NSThread.callStackSymbols;
    NSDictionary *context = KcCurrentExecutionContext();
    pthread_mutex_lock(&KcDependencyMutex);
    @try { return KcGraphWait(nil, targetThreadID, reason, stack, context); }
    @finally { pthread_mutex_unlock(&KcDependencyMutex); }
}
+ (void)endWaiting:(NSUUID *)token {
    pthread_mutex_lock(&KcDependencyMutex);
    KcGraphEndWait(token);
    pthread_mutex_unlock(&KcDependencyMutex);
}
- (void)onQueue:(dispatch_block_t)block {
    if (dispatch_get_specific((__bridge const void *)self)) block();
    else dispatch_sync(_queue, block);
}
- (void)start {
    [self onQueue:^{
        if (self->_timer) return;
        self->_previous = @{};
        self->_lastSampleTime = 0;
        self->_CPUHistory = [NSMutableDictionary dictionary];
        self->_lastReports = [NSMutableDictionary dictionary];
        self->_mainThreadID = 0;
        self->_heartbeat = nil;
        self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self->_timer, ^{ [weakSelf sample]; });
        uint64_t nanos = (uint64_t)(self->_interval * NSEC_PER_SEC);
        dispatch_source_set_timer(self->_timer, dispatch_time(DISPATCH_TIME_NOW, nanos), nanos, nanos / 10);
        dispatch_resume(self->_timer);
    }];
}
- (void)stop {
    [self onQueue:^{
        if (self->_timer) dispatch_source_cancel(self->_timer);
        self->_timer = nil;
        self->_heartbeat = nil;
        self->_previous = nil;
        self->_CPUHistory = nil;
        self->_lastReports = nil;
    }];
}
- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
}
- (void)emit:(NSString *)kind key:(NSString *)key reason:(NSString *)reason evidence:(NSDictionary *)evidence now:(NSTimeInterval)now {
    if (!_timer) return;
    NSNumber *last = _lastReports[key];
    if (last && now - last.doubleValue < 10) return;
    _lastReports[key] = @(now);
    KcDeadlockReport *report = [KcDeadlockReport new];
    report.kind = kind;
    report.reason = reason;
    report.evidence = evidence;
    NSData *JSON = [NSJSONSerialization dataWithJSONObject:evidence options:NSJSONWritingPrettyPrinted error:NULL];
    report.dump = [NSString stringWithFormat:@"[KcDeadlock] %@\n%@\n%@", kind, reason,
                   [[NSString alloc] initWithData:JSON encoding:NSUTF8StringEncoding] ?: evidence.description];
    _handler(report);
}
- (void)sample {
    @autoreleasepool {
        if (!_timer) return;
        NSTimeInterval now = KcNow();
        NSDictionary *threads = KcSampleThreads();
        NSTimeInterval elapsed = now - _lastSampleTime;
        for (NSNumber *thread in threads) {
            NSDictionary *sample = threads[thread];
            NSDictionary *old = _previous[thread];
            double usage = old && elapsed > 0 ? 100 * ([sample[@"CPUTime"] doubleValue] - [old[@"CPUTime"] doubleValue]) / elapsed : 0;
            if (usage < _CPUThreshold) { [_CPUHistory removeObjectForKey:thread]; continue; }
            NSMutableArray *history = _CPUHistory[thread];
            if (!history) _CPUHistory[thread] = history = [NSMutableArray array];
            [history addObject:@{@"uptime": @(now), @"interval": @(elapsed), @"CPUPercent": @(usage), @"thread": sample}];
            if (history.count > 3) [history removeObjectAtIndex:0];
            if (history.count == 3) {
                [self emit:@"highCPU" key:[@"cpu:" stringByAppendingString:thread.stringValue]
                    reason:[NSString stringWithFormat:@"%@ 连续三个区间高 CPU；可能是死循环、自旋、活锁，也可能是正常重计算。比较下列多次采样的业务帧，不能仅凭 CPU 或相同栈确认死循环。", KcDescribeThread(thread, sample, nil)]
                  evidence:@{@"threadID": thread, @"threshold": @(_CPUThreshold), @"samples": [history copy]} now:now];
                if (!_timer) return;
            }
        }
        for (NSNumber *thread in _CPUHistory.allKeys) if (!threads[thread]) [_CPUHistory removeObjectForKey:thread];
        _previous = threads;
        _lastSampleTime = now;
        [self analyzeDependencies:KcGraphSnapshot() threads:threads now:now];
        if (!_timer) return;
        [self checkHeartbeat:threads now:now];
        // 有界：线程 churn 不会让报告去重表永久增长。
        for (NSString *key in _lastReports.allKeys) {
            if (now - [_lastReports[key] doubleValue] > 60) [_lastReports removeObjectForKey:key];
        }
    }
}
- (void)analyzeDependencies:(NSArray<NSDictionary *> *)edges threads:(NSDictionary *)threads now:(NSTimeInterval)now {
    NSMutableDictionary *byThread = [NSMutableDictionary dictionary];
    for (NSDictionary *edge in edges) byThread[edge[@"threadID"]] = edge;
    NSMutableSet *cycleThreads = [NSMutableSet set];
    NSMutableSet *finished = [NSMutableSet set];
    for (NSNumber *start in byThread) {
        NSMutableArray *path = [NSMutableArray array];
        NSMutableDictionary *positions = [NSMutableDictionary dictionary];
        NSNumber *cursor = start;
        while (byThread[cursor] && ![finished containsObject:cursor] && !positions[cursor]) {
            positions[cursor] = @(path.count);
            [path addObject:cursor];
            cursor = byThread[cursor][@"targetThreadID"];
        }
        if (positions[cursor]) {
            NSArray *cycle = [path subarrayWithRange:NSMakeRange([positions[cursor] unsignedIntegerValue], path.count - [positions[cursor] unsignedIntegerValue])];
            [cycleThreads addObjectsFromArray:cycle];
            BOOL persistent = YES;
            NSMutableArray *dependencies = [NSMutableArray array];
            NSMutableArray *stacks = [NSMutableArray array];
            for (NSNumber *thread in cycle) {
                NSDictionary *edge = byThread[thread];
                if (now - [edge[@"since"] doubleValue] < _waitThreshold) persistent = NO;
                [dependencies addObject:edge];
                [stacks addObject:threads[thread] ?: @{@"threadID": thread, @"stack": @[@"<thread unavailable; see recorded wait/acquisition stack>"]}];
            }
            if (persistent) {
                NSArray *sorted = [cycle sortedArrayUsingSelector:@selector(compare:)];
                NSMutableArray *chain = [NSMutableArray array];
                for (NSDictionary *edge in dependencies) {
                    [chain addObject:[NSString stringWithFormat:@"%@ --等待 %@ (%@)--> %@",
                        KcDescribeThread(edge[@"threadID"], threads[edge[@"threadID"]], edge[@"waitContext"]),
                        edge[@"reason"], [edge[@"resource"] length] ? edge[@"resource"] : @"显式依赖",
                        KcDescribeThread(edge[@"targetThreadID"], threads[edge[@"targetThreadID"]], edge[@"ownerContext"])]];
                }
                NSString *reason = [NSString stringWithFormat:@"观察到持续的等待依赖闭环%@：\n%@\n锁依赖来自 KcTrackedLock；显式边的准确性由调用方保证。",
                    cycle.count == 1 ? @"（同线程自等待）" : @"", [chain componentsJoinedByString:@"\n"]];
                [self emit:@"dependencyCycle" key:[@"cycle:" stringByAppendingString:sorted.description]
                    reason:reason
                  evidence:@{@"cycle": cycle, @"dependencies": dependencies, @"threads": stacks} now:now];
                if (!_timer) return;
            }
        }
        [finished addObjectsFromArray:path];
    }
    for (NSDictionary *edge in edges) {
        NSNumber *thread = edge[@"threadID"];
        if ([cycleThreads containsObject:thread] || now - [edge[@"since"] doubleValue] < _waitThreshold) continue;
        NSNumber *target = edge[@"targetThreadID"];
        NSMutableArray *stacks = [NSMutableArray array];
        for (NSNumber *identity in @[thread, target]) {
            if (threads[identity]) [stacks addObject:threads[identity]];
        }
        [self emit:@"longWait" key:[@"wait:" stringByAppendingString:edge[@"token"]]
            reason:[NSString stringWithFormat:@"%@ 等待 %@，依赖 %@；超过阈值但未观察到闭环，不能确认死锁。", KcDescribeThread(thread, threads[thread], edge[@"waitContext"]), edge[@"reason"], KcDescribeThread(target, threads[target], edge[@"ownerContext"])]
          evidence:@{@"dependency": edge, @"waitSeconds": @(now - [edge[@"since"] doubleValue]), @"threads": stacks} now:now];
        if (!_timer) return;
    }
}
- (void)checkHeartbeat:(NSDictionary *)threads now:(NSTimeInterval)now {
    if (_heartbeat && !_heartbeat.acknowledged) {
        if (now - _heartbeat.sentAt >= _waitThreshold) {
            id stack = threads[@(_mainThreadID)];
            [self emit:@"mainThreadStall" key:@"main-stall"
                reason:[NSString stringWithFormat:@"主队列心跳超时（不是死锁证明），%@：检查忙循环、锁等待、同步 I/O、dispatch_sync 或 semaphore/group 等待。初次心跳尚未执行时附全部线程。", self->_mainThreadID ? KcDescribeThread(@(self->_mainThreadID), stack, nil) : @"主线程 ID 尚未知"]
              evidence:@{@"waitSeconds": @(now - _heartbeat.sentAt), @"mainThreadID": @(_mainThreadID),
                         @"threads": stack ? @[stack] : threads.allValues} now:now];
        }
        return;
    }
    KcHeartbeat *heartbeat = [KcHeartbeat new];
    heartbeat.sentAt = now;
    _heartbeat = heartbeat;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        uint64_t identity = KcDeadlockMonitor.currentThreadID;
        // ID 回写也在监控队列进行，避免与 stop/start 和 sample 竞争。
        KcDeadlockMonitor *monitor = weakSelf;
        if (monitor) dispatch_async(monitor->_queue, ^{
            if (monitor->_heartbeat == heartbeat) monitor->_mainThreadID = identity;
        });
        heartbeat.acknowledged = YES;
    });
}
@end
