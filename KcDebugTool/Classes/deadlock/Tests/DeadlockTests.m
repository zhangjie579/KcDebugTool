// Foundation-only executable: each real deadlock lives in its own process.
#import "KcDeadlockMonitor.h"
#import "KcTrackedLock.h"
#import "KcDeadlockInternal.h"
#import <stdatomic.h>
#import <pthread.h>

static void Check(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static BOOL PumpUntil(NSTimeInterval timeout, BOOL (^predicate)(void)) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    do {
        if (predicate()) return YES;
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    return predicate();
}
static void Background(NSString *name, dispatch_block_t block) {
    [NSThread detachNewThreadWithBlock:^{
        @autoreleasepool { NSThread.currentThread.name = name; block(); }
    }];
}
static KcDeadlockReport *Find(NSArray *reports, NSString *kind) {
    @synchronized (reports) {
        for (KcDeadlockReport *report in reports) if ([report.kind isEqual:kind]) return report;
    }
    return nil;
}
static void SetupCycle(NSUInteger size) {
    Check(size > 0, @"cycle scenario requires a positive size, e.g. cycle1/cycle2/cycle3");
    NSMutableArray *locks = [NSMutableArray array];
    NSMutableArray *ready = [NSMutableArray array];
    for (NSUInteger i = 0; i < size; i++) {
        [locks addObject:[[KcTrackedLock alloc] initWithName:[NSString stringWithFormat:@"L%lu", (unsigned long)i] recursive:NO]];
        [ready addObject:dispatch_semaphore_create(0)];
    }
    dispatch_semaphore_t go = dispatch_semaphore_create(0);
    for (NSUInteger i = 0; i < size; i++) {
        Background([NSString stringWithFormat:@"cycle-%lu", (unsigned long)i], ^{
            [locks[i] lock];
            dispatch_semaphore_signal(ready[i]);
            dispatch_semaphore_wait(go, DISPATCH_TIME_FOREVER);
            [locks[(i + 1) % size] lock];
        });
    }
    for (dispatch_semaphore_t semaphore in ready) {
        Check(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"owner started");
    }
    for (NSUInteger i = 0; i < size; i++) dispatch_semaphore_signal(go);
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Check(argc == 2, @"scenario argument required");
        NSString *scenario = @(argv[1]);
        NSMutableArray *reports = [NSMutableArray array];
        KcDeadlockMonitor *monitor = [[KcDeadlockMonitor alloc] initWithSampleInterval:0.05 CPUThreshold:40 waitThreshold:0.2 reportHandler:^(KcDeadlockReport *report) {
            @synchronized (reports) { [reports addObject:report]; }
        }];
        [monitor start];
        [monitor start]; // idempotent
        if ([scenario hasPrefix:@"cycle"]) {
            NSUInteger size = [[scenario substringFromIndex:5] integerValue];
            SetupCycle(size);
            Check(PumpUntil(4, ^BOOL{ return Find(reports, @"dependencyCycle") != nil; }), @"cycle detected");
            KcDeadlockReport *report = Find(reports, @"dependencyCycle");
            NSArray *edges = report.evidence[@"dependencies"];
            Check(edges.count == size, @"all cycle threads identified");
            for (NSDictionary *edge in edges) {
                Check([edge[@"waitStack"] count] > 0, @"waiting call site dumped");
                Check([edge[@"acquisitionStack"] count] > 0, @"owner acquisition call site dumped");
                Check([edge[@"targetThreadID"] unsignedLongLongValue] > 0, @"owner identified");
            }
            Check([report.evidence[@"threads"] count] == size, @"all live stacks dumped");
            Check([report.dump containsString:@"threadName=cycle-0"], @"thread name included in cycle summary");
            if (getenv("KC_DUMP_REPORT")) puts(report.dump.UTF8String);
        } else if ([scenario isEqual:@"gcdContext"] || [scenario isEqual:@"operationContext"]) {
            BOOL operation = [scenario isEqual:@"operationContext"];
            NSArray *locks = @[[[KcTrackedLock alloc] initWithName:@"queue-lock-A" recursive:NO],
                               [[KcTrackedLock alloc] initWithName:@"queue-lock-B" recursive:NO]];
            NSArray *labels = @[@"com.kc.tests.queue-A", @"com.kc.tests.queue-B"];
            dispatch_semaphore_t ready = dispatch_semaphore_create(0);
            dispatch_semaphore_t go = dispatch_semaphore_create(0);
            NSMutableArray *queues = [NSMutableArray array];
            for (NSUInteger i = 0; i < 2; i++) {
                dispatch_block_t work = ^{
                    [locks[i] lock];
                    dispatch_semaphore_signal(ready);
                    dispatch_semaphore_wait(go, DISPATCH_TIME_FOREVER);
                    [locks[1 - i] lock];
                };
                if (operation) {
                    NSOperationQueue *queue = [NSOperationQueue new];
                    queue.name = labels[i];
                    queue.maxConcurrentOperationCount = 1;
                    [queues addObject:queue];
                    [queue addOperationWithBlock:work];
                } else {
                    dispatch_queue_t queue = dispatch_queue_create([labels[i] UTF8String], DISPATCH_QUEUE_SERIAL);
                    [queues addObject:queue];
                    dispatch_async(queue, work);
                }
            }
            for (NSUInteger i = 0; i < 2; i++) {
                Check(dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"queue owner ready");
            }
            dispatch_semaphore_signal(go); dispatch_semaphore_signal(go);
            Check(PumpUntil(4, ^BOOL{ return Find(reports, @"dependencyCycle") != nil; }), @"queue cycle detected");
            KcDeadlockReport *report = Find(reports, @"dependencyCycle");
            NSString *key = operation ? @"operationQueueName" : @"dispatchQueueLabel";
            NSMutableSet *waitNames = [NSMutableSet set];
            NSMutableSet *ownerNames = [NSMutableSet set];
            for (NSDictionary *edge in report.evidence[@"dependencies"]) {
                [waitNames addObject:edge[@"waitContext"][key]];
                [ownerNames addObject:edge[@"ownerContext"][key]];
                Check([edge[@"waitContext"][@"threadName"] length] > 0, @"thread name or unnamed marker present");
            }
            Check([waitNames isEqualToSet:[NSSet setWithArray:labels]], @"waiting queues identified");
            Check([ownerNames isEqualToSet:[NSSet setWithArray:labels]], @"owner queues identified");
            for (NSString *label in labels) Check([report.reason containsString:label], @"queue names in readable summary");
            Check(queues.count == 2, @"retain execution queues for the test");
            if (getenv("KC_DUMP_REPORT")) puts(report.dump.UTF8String);
        } else if ([scenario isEqual:@"highCPU"]) {
            static atomic_bool running = true;
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            Background(@"busy-loop", ^{
                while (atomic_load_explicit(&running, memory_order_relaxed)) { __asm__ volatile(""); }
                dispatch_semaphore_signal(done);
            });
            BOOL detected = PumpUntil(5, ^BOOL{ return Find(reports, @"highCPU") != nil; });
            atomic_store(&running, false);
            Check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"busy loop stopped");
            Check(detected, @"sustained CPU detected");
            Check([Find(reports, @"highCPU").evidence[@"samples"] count] == 3, @"three interval samples");
            Check([Find(reports, @"highCPU").reason containsString:@"threadName=busy-loop"], @"high CPU summary includes thread name");
            if (getenv("KC_DUMP_REPORT")) puts(Find(reports, @"highCPU").dump.UTF8String);
        } else if ([scenario isEqual:@"longWait"]) {
            KcTrackedLock *lock = [[KcTrackedLock alloc] initWithName:@"long-critical-section" recursive:NO];
            [lock lock];
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            Background(@"waiter", ^{ [lock lock]; [lock unlock]; dispatch_semaphore_signal(done); });
            Check(PumpUntil(3, ^BOOL{ return Find(reports, @"longWait") != nil; }), @"long wait reported");
            Check(!Find(reports, @"dependencyCycle"), @"long wait is not a cycle");
            [lock unlock];
            Check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"waiter released");
            Check(KcGraphSnapshot().count == 0, @"wait edge removed on acquisition");
        } else if ([scenario isEqual:@"explicitCycle"]) {
            uint64_t main = KcDeadlockMonitor.currentThreadID;
            dispatch_semaphore_t ready = dispatch_semaphore_create(0);
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            __block uint64_t worker = 0;
            Background(@"explicit-worker", ^{
                worker = KcDeadlockMonitor.currentThreadID;
                NSUUID *wait = [KcDeadlockMonitor beginWaitingForThread:main reason:@"worker needs main"];
                dispatch_semaphore_signal(ready);
                dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
                [KcDeadlockMonitor endWaiting:wait];
            });
            Check(dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"worker ready");
            NSUUID *wait = [KcDeadlockMonitor beginWaitingForThread:worker reason:@"main needs worker"];
            // Model the main thread's actual blocking operation; monitor must work without its runloop.
            [NSThread sleepForTimeInterval:0.7];
            [KcDeadlockMonitor endWaiting:wait];
            dispatch_semaphore_signal(done);
            Check(Find(reports, @"dependencyCycle") != nil, @"explicit dependency cycle detected");
        } else if ([scenario isEqual:@"heartbeat"]) {
            Check(PumpUntil(0.15, ^{ return NO; }) == NO, @"prime heartbeat");
            [NSThread sleepForTimeInterval:0.6];
            Check(Find(reports, @"mainThreadStall") != nil, @"main stall detected independently");
            Check([Find(reports, @"mainThreadStall").evidence[@"mainThreadID"] unsignedLongLongValue] == KcDeadlockMonitor.currentThreadID, @"main thread identified");
        } else if ([scenario isEqual:@"recursive"]) {
            KcTrackedLock *lock = [[KcTrackedLock alloc] initWithName:@"recursive" recursive:YES];
            [lock lock]; [lock lock]; Check([lock tryLock], @"recursive tryLock succeeds");
            [lock unlock]; [lock unlock];
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            Background(@"recursive-waiter", ^{ [lock lock]; [lock unlock]; dispatch_semaphore_signal(done); });
            Check(PumpUntil(3, ^BOOL{ return Find(reports, @"longWait") != nil; }), @"recursive depth retained");
            Check(!Find(reports, @"dependencyCycle"), @"recursive acquisition has no self-cycle");
            [lock unlock];
            Check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"final recursive release");
        } else if ([scenario isEqual:@"cleanup"]) {
            KcTrackedLock *lock = [KcTrackedLock new];
            [lock lock];
            Check(![lock tryLock], @"nonrecursive tryLock fails without a wait");
            Check(KcGraphSnapshot().count == 0, @"tryLock creates no dependency");
            NSUUID *wait = [KcDeadlockMonitor beginWaitingForThread:KcDeadlockMonitor.currentThreadID reason:@"temporary"];
            BOOL threw = NO;
            @try { [lock lock]; } @catch (NSException *exception) { (void)exception; threw = YES; }
            Check(threw, @"duplicate wait rejected");
            [KcDeadlockMonitor endWaiting:wait]; // proves graph mutex was released on error
            [lock unlock];
            Check(KcGraphSnapshot().count == 0, @"explicit wait cleaned up");
            // Invalid unlock throws without poisoning the graph lock.
            @try { [lock unlock]; Check(NO, @"invalid unlock must throw"); }
            @catch (NSException *exception) { (void)exception; }
            [lock lock]; [lock unlock];
            PumpUntil(0.5, ^{ return NO; });
            Check(!Find(reports, @"dependencyCycle"), @"ended waits do not generate cycles");
            [monitor stop];
            @synchronized (reports) { [reports removeAllObjects]; }
            [monitor start];
            PumpUntil(0.3, ^{ return NO; });
            Check(!Find(reports, @"mainThreadStall"), @"restart starts fresh heartbeat");
        } else if ([scenario isEqual:@"contention"]) {
            KcTrackedLock *lock = [KcTrackedLock new];
            dispatch_group_t group = dispatch_group_create();
            __block NSUInteger count = 0;
            for (NSUInteger i = 0; i < 4; i++) {
                dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                    for (NSUInteger j = 0; j < 100; j++) { [lock lock]; count++; [lock unlock]; }
                });
            }
            Check(PumpUntil(5, ^BOOL{ return dispatch_group_wait(group, DISPATCH_TIME_NOW) == 0; }), @"contending workers finish");
            Check(count == 400, @"mutual exclusion preserved");
            Check(KcGraphSnapshot().count == 0, @"no stale contention edges");
            Check(!Find(reports, @"dependencyCycle"), @"normal contention is not a cycle");
        } else { Check(NO, @"unknown scenario"); }
        [monitor stop]; [monitor stop];
        printf("PASS %s\n", scenario.UTF8String);
    }
    return 0;
}
