#import <Foundation/Foundation.h>
#import <pthread.h>

NS_ASSUME_NONNULL_BEGIN

// 内部图锁仅保护元数据，绝不跨实际阻塞、栈采样、用户回调持有。
FOUNDATION_EXPORT pthread_mutex_t KcDependencyMutex;
FOUNDATION_EXPORT uint64_t KcDiagnosticThreadID(void);
/// 在业务线程现场、进入图锁之前采集；队列名仅表示该事件发生时的执行上下文。
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *KcCurrentExecutionContext(void);
FOUNDATION_EXPORT void KcGraphAcquire(NSString *resource, NSString *name, uint64_t thread, NSArray *stack, NSDictionary *context);
FOUNDATION_EXPORT void KcGraphRelease(NSString *resource, uint64_t thread);
FOUNDATION_EXPORT NSUUID *KcGraphWait(NSString * _Nullable resource, uint64_t target, NSString *reason, NSArray *stack, NSDictionary *context);
FOUNDATION_EXPORT void KcGraphEndWait(NSUUID *token);
FOUNDATION_EXPORT NSArray<NSDictionary *> *KcGraphSnapshot(void);
// 上述 Graph 函数（Snapshot 除外）均要求调用方持有 KcDependencyMutex。
NS_ASSUME_NONNULL_END
