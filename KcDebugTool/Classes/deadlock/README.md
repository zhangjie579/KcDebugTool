# Objective-C 卡死 / 死锁分析

此模块是主动接入的调试工具，默认不会自动启动，也不会 hook 系统锁。实现文件均为 `.m`，依赖 Foundation、pthread 和 Mach，支持 ARC。

## 接入

CocoaPods：`pod 'KcDebugTool/deadlock'`；`DebugTool` subspec 也依赖此模块。现有工程更新 pod 后才会包含新文件。手动集成则把本目录顶层的 `.h/.m` 加入 target，勿加入 `Tests`。

```objc
#import <KcDebugTool/KcDeadlockMonitor.h>
#import <KcDebugTool/KcTrackedLock.h>

// 作为 strong 属性长期持有。释放 monitor 或调用 stop 会停止采样。
self.deadlockMonitor = [[KcDeadlockMonitor alloc]
    initWithReportHandler:^(KcDeadlockReport *report) { NSLog(@"%@", report.dump); }];
[self.deadlockMonitor start];

self.cacheLock = [[KcTrackedLock alloc] initWithName:@"cache-lock" recursive:NO];
[self.cacheLock lock];
@try {
    // 业务临界区
} @finally {
    [self.cacheLock unlock];
}
```

仅建议在调试/定向诊断时启用。锁操作记录调用栈会增加开销、改变调度。iOS 应在进入后台时 `stop`、回到前台时 `start`，避免把后台挂起当成卡死。`start/stop` 幂等；停止不会清空仍在使用的锁元数据，因此重启后仍可检测原有锁环。回调在专用监控队列执行，必须快速返回，勿同步等待主线程或业务锁。回调中可 `stop`，重新 `start` 应在回调返回后执行。

## 1. CPU 跑满、死循环、自旋和活锁

CPU 跑满属于“忙”，不等同于锁死锁（通常是“阻塞”）。独立监控队列通过 `task_threads` 枚举线程，读取 `THREAD_BASIC_INFO` 的累计 user/system time，用两个采样点的增量计算：

```
CPU% = Δ(user_time + system_time) / ΔsystemUptime × 100
```

100% 表示占满一个逻辑核。默认每 0.5 秒采样，某个线程连续三个区间达到 80% 才输出 `highCPU`，包含线程 ID/名称、每次 CPU%、区间长度、三个时刻的实际堆栈。监控线程自身不参与统计；不存在的线程会清除历史。

分析方法：

- 多次停留在业务 `while/for` 的同一段指令：检查循环退出条件、计数器、整数溢出和共享变量可见性。没有退出条件的循环会持续消耗 CPU。
- 多次停留在 CAS / `tryLock` 重试：检查忙等是否有退避，以及解锁/状态更新线程是否能得到执行机会。
- 多个线程反复抢占、释放、重试但没有业务进度：可能是活锁，需要同时观察业务进度计数。
- 栈随业务不断前进：可能是大计算、解析、图片处理或大量重复调用。高 CPU 本身不应直接标为死循环。

**不能从有限次栈采样证明循环永不退出。** 报告明确使用“可能”，保留原始证据；没有使用系统的瞬时 `cpu_usage` 字段来替代区间 CPU 计算。当前策略针对单线程持续高 CPU；多个线程各低于阈值但合计很高、短命线程和短暂尖峰可能不会触发，需要按场景降低阈值或用 Instruments 分析总量。

```objc
self.deadlockMonitor = [[KcDeadlockMonitor alloc]
    initWithSampleInterval:0.5 CPUThreshold:80 waitThreshold:3
    reportHandler:^(KcDeadlockReport *report) { NSLog(@"%@", report.dump); }];
```

## 2. 锁循环依赖：找出所有参与线程并 dump

`KcTrackedLock` 封装 pthread normal / recursive mutex，并记录：锁的唯一 ID 和名称、当前 owner 的稳定内核线程 ID、递归深度、首次获取栈、等待开始时间和加锁调用栈。`tryLock` 失败不会产生阻塞依赖；递归锁同线程重入也不会产生等待边。

每次分析构造等待图 `线程 → 等待的锁 → 当前 owner 线程`。检测任意长度的闭环，所有参与者持续等待超过阈值后输出 `dependencyCycle`。例如：

```
线程 101 --等待 database-lock (UUID-B)--> 线程 202
线程 202 --等待 cache-lock (UUID-A)--> 线程 101
```

报告包含：

- `dependencies`：每条边的 `threadID`、`targetThreadID`、锁 `resource` / `reason`、`since`、`waitStack`、owner 的 `acquisitionStack` / `depth`。
- `threads`：环内每个线程的当前堆栈。可同时看到“在哪里等待”和“对方从哪里持有该锁”。
- 长度为 1 的闭环：同线程再次获取非递归锁。改用递归锁前应先检查重入是否符合业务约束；递归锁仍可能参与跨线程的锁顺序环。

图元数据更新由独立的内部 mutex 保护，实际阻塞期间不持有它；unlock 与 owner 更新协调，避免残留旧 owner。锁身份使用 UUID，不用可能重用的对象地址。图遍历只读取当前等待关系，普通竞争不会因历史加锁顺序而被误报为已发生的死锁。

此工具**不会自动得知已有 NSLock、NSRecursiveLock、`@synchronized`、os_unfair_lock、裸 pthread mutex 的 owner**。业务路径需替换成 `KcTrackedLock`；它不是 NSLock 子类，不支持 `lockBeforeDate:`、NSCondition 的 wait 或跨线程 unlock。没有把 runtime 私有布局或系统栈函数名当作可靠所有权来源。

## 3. 其他卡死场景

| 场景 | 原因 / 典型栈线索 | 当前能力与处理方向 |
| --- | --- | --- |
| 同串行队列同步派发、主线程同步派发主队列 | 同步任务等待自己所在队列可用；可能见 `_dispatch_sync_f_slow` 或下游等待 | 主队列可由心跳报超时；后台队列需要显式依赖或外部队列监测。部分 libdispatch 版本会直接 trap，进程内采样来不及报告 |
| A 队列 sync B，B 又 sync A | 队列执行依赖形成闭环；可能是多线程，也可能直接崩溃 | 执行线程已知且固定时可声明线程依赖；GCD 串行队列不固定绑定某线程，不能把队列地址当作线程 ID |
| 主线程 semaphore/group wait，完成任务在主队列 | 主线程阻塞后主队列的 signal/leave 无法执行；常见 `semaphore_wait_trap`、`__ulock_wait`、dispatch wait | 心跳超时 + 堆栈；知道实际执行线程时加显式依赖 |
| semaphore/condition 漏唤醒、group 漏 leave | 缺少 signal、错误的 predicate 或 leave 没在所有路径执行；可能没有任何锁环 | 可声明已知唤醒线程的等待并报 `longWait`，不能从 semaphore 反推唯一 owner；用超时、谓词循环和 finally 修复 |
| NSCondition 等待时仍持有另一把锁 | condition wait 只释放自己的锁，signal 方又需要外部锁 | 外部锁可跟踪；condition 部分需正确的显式依赖，切勿把 wait 全程当作仍持有 condition 锁 |
| 漏 unlock / 持锁线程退出 / 长临界区 | 等待者阻塞于锁，但没有闭环 | `KcTrackedLock` 输出 `longWait`、等待者栈与最后持有者获取栈；不能只凭超时区分永久漏释放和耗时工作 |
| 读写锁升级 | 多个读者持读锁后申请写锁，写者等待所有读者退出 | 当前无 rwlock 跟踪；需一资源多 owner 的图模型，不能直接套单 owner mutex 模型 |
| operation / 线程 join 依赖环 | A 等 B 完成，B 又依赖 A | 执行线程已知时用显式依赖；未开始执行的 Operation 需要任务节点，当前不自动追踪 |
| 优先级反转、线程饥饿、线程池耗尽 | 低优先级 owner 得不到执行；工作线程全部同步等尚未调度的任务 | 可表现为 longWait / 主线程心跳超时；不一定有闭环，应检查 QoS、限流和同步等待设计 |
| 同步 I/O、网络等待、sleep、极慢计算 | 等待外部资源或耗时任务 | 主线程卡住时心跳超时；只有高 CPU 或显式等待的后台线程才会触发此工具的其他报告 |

`mainThreadStall`（主队列心跳超时）和 `longWait` 都不是死锁证明。每次最多保留一个未完成的心跳；首次启动时主线程已卡住、无法取得主线程 ID，会附所有线程栈供定位。相同 CPU 线程/环/等待 token/心跳报告 10 秒内去重。

## 线程名、GCD 和 NSOperationQueue 名称

日志摘要显示 `线程 ID [threadName=..., gcd=..., operationQueue=...]`，其中三种名称分别记录，不互相替代。未命名线程显示 `<unnamed>`。

- 所有远程采样通过 Mach 的 `THREAD_EXTENDED_INFO.pth_name` 获取线程名；`highCPU`、锁环、长等待和主线程超时都保留线程名称及堆栈。
- `KcTrackedLock` 获取/等待锁以及显式 `beginWaitingForThread:reason:` 时，在业务线程现场采集 `NSThread.name` / pthread 名称、`dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL)` 和 `NSOperationQueue.currentQueue.name`。采集在内部图锁之外执行。
- 等待边的 `waitContext` 表示开始等待时的上下文；`ownerContext` 表示该锁首次获取时的上下文。它们是事件快照，不是线程的永久属性，线程池线程复用不会继承上一任务的队列记录。显式依赖没有锁 owner 上下文时，只显示目标线程现场采样的名称。
- 仅有远程 CPU 采样、业务路径未接入上述接口时，当前实现只能记录线程名，不能通过公共 API 可靠反查任意线程所属 GCD/Operation 队列。也不会在监控线程上调用 currentQueue 然后误记为业务队列。

例如：

```text
线程 101 [threadName=<unnamed>, gcd=com.example.cache] --等待 database-lock--> ...
线程 202 [threadName=<unnamed>, gcd=..., operationQueue=image-processing] --等待 cache-lock--> ...
```

可给业务队列设置有意义的名称：`dispatch_queue_create("com.example.cache", DISPATCH_QUEUE_SERIAL)`、`operationQueue.name = @"image-processing"`。两类队列执行的业务代码使用 tracked lock 时，其线程锁环同样可以检测；队列本身的 sync、Operation dependency 等未接入的调度依赖仍遵循上表的能力边界。

## 显式线程依赖

在实际阻塞前记录，返回/超时后清除；只在真正知道谁负责完成时使用。不能把“可能有某个线程会 signal”声明为确定依赖。

```objc
// targetThreadID 应在确定的执行线程上提前记录：
// uint64_t targetThreadID = KcDeadlockMonitor.currentThreadID;
NSUUID *wait = [KcDeadlockMonitor beginWaitingForThread:targetThreadID
                                              reason:@"等待后台线程完成计算"];
@try {
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
} @finally {
    [KcDeadlockMonitor endWaiting:wait];
}
```

同一线程同时只能声明一个等待。显式边支持与 tracked lock 混合的依赖环，但不会改变实际同步行为；过期或错误声明会误报。使用超时的显式边即使形成图环，也可能随后自行解除，报告只能证明观测时的等待环。

## 堆栈可靠性

线程 ID 使用 `THREAD_IDENTIFIER_INFO.thread_id` / `pthread_threadid_np`，不把 Mach port name 当作稳定线程标识。每次枚举后释放每个线程 port 的 send right 和数组内存。

通过 `thread_get_state` 获取 PC/FP/LR，再用 `vm_read_overwrite` 安全读取有上限的 frame pointer 链，支持 arm64、x86_64 和旧 arm/i386 分支；arm64e 使用访问器并剥离返回地址 PAC。**不 suspend 业务线程**，以免暂停持有 malloc/runtime/dyld 锁的线程后，监控线程又因符号化而被卡住。运行中栈不是一致性快照，可能截断或混入变化帧；正在阻塞的线程通常更稳定。

`dladdr` 输出镜像名、镜像加载地址、原始 PC、符号及偏移。缺少符号时保留地址，失败时报告明确占位信息；优化、尾调用、省略 FP、系统权限限制都会影响完整性。建议诊断构建保留 frame pointers 和符号；源码行号需匹配构建的二进制/dSYM 离线符号化。锁的获取/等待调用栈另行在对应线程现场记录，可以补足远程采样失败。

## 验证

实际运行测试的输出节选（ID、地址和百分比会随运行变化）：

```text
highCPU / busy-loop / threadID=1624590 / CPUPercent=98.89
00 tests __main_block_invoke.37 + 12
01 tests __Background_block_invoke + 84
02 Foundation __NSThread__block_start__ + 76

dependencyCycle
线程 1623441 --等待 L1--> 线程 1623442
线程 1623442 --等待 L0--> 线程 1623441
两线程的当前栈均为：
00 libsystem_kernel.dylib __psynch_mutexwait + 8
01 libsystem_pthread.dylib _pthread_mutex_firstfit_lock_wait + 84
02 libsystem_pthread.dylib _pthread_mutex_firstfit_lock_slow + 216
03 tests -[KcTrackedLock lock] + 248
04 tests __SetupCycle_block_invoke + 140
```

第一个用例故意执行无退避的 `while (atomic_load(&running))`，CPU 持续消耗在该 block 内；测试结束会设置退出标志。第二个用例两个线程各持 L0/L1，再等待对方的锁，因所有者均无法执行到 unlock 而形成闭环。完整报告还分别保存 `__SetupCycle_block_invoke + 44` 的持锁获取栈和 `+140` 的等待调用栈，能区分锁的获取点与阻塞点。

```sh
bash KcDebugTool/Classes/deadlock/Tests/run.sh
```

使用 macOS Foundation/Mach 独立可执行文件，每个真实死锁用例独立进程，进程退出回收阻塞线程，不挂死 Example/XCTest。包含：非递归自锁、两线程环、三线程环、持续忙循环、长等待、显式依赖环、主线程心跳、递归深度、异常/重启/状态清理、正常多线程竞争。设置 `KC_DUMP_REPORT=1` 可查看 CPU 和锁环的实际报告。

iOS arm64 与 x86_64 Simulator 使用 SDK 严格编译检查；上述运行测试在 macOS 执行，不替代 iOS 真机运行验证。Example 有现有的本地 Pod 路径依赖，独立测试不要求修改它们。

## 参考

- [Apple NSLock：同线程 unlock、非递归重入](https://developer.apple.com/documentation/foundation/nslock)
- [Apple NSRecursiveLock](https://developer.apple.com/documentation/foundation/nsrecursivelock)
- [Apple NSCondition：wait 释放并重新获取锁，谓词需循环检查](https://developer.apple.com/documentation/foundation/nscondition?language=objc)
- [Apple Dispatch Queues：同步派发与当前队列死锁](https://developer.apple.com/library/archive/documentation/General/Conceptual/ConcurrencyProgrammingGuide/OperationQueues/OperationQueues.html)
- [Apple Dispatch Queue：当前队列 label](https://developer.apple.com/documentation/dispatch/dispatch-queue?language=objc)
- [Apple NSOperationQueue.currentQueue](https://developer.apple.com/documentation/foundation/operationqueue/current)
- [Apple XNU thread 实现](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/thread.c)
