#import "KcTrackedLock.h"
#import "KcDeadlockInternal.h"
#import <errno.h>

@implementation KcTrackedLock {
    pthread_mutex_t _mutex;
    NSString *_resource;
}
- (instancetype)init {
    return [self initWithName:@"unnamed" recursive:NO];
}
- (instancetype)initWithName:(NSString *)name recursive:(BOOL)recursive {
    if ((self = [super init])) {
        _name = [name copy];
        _recursive = recursive;
        _resource = NSUUID.UUID.UUIDString;
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, recursive ? PTHREAD_MUTEX_RECURSIVE : PTHREAD_MUTEX_NORMAL);
        int result = pthread_mutex_init(&_mutex, &attr);
        pthread_mutexattr_destroy(&attr);
        if (result) [NSException raise:NSInternalInconsistencyException format:@"mutex init: %d", result];
    }
    return self;
}
- (BOOL)tryLock {
    uint64_t thread = KcDiagnosticThreadID();
    NSArray *stack = NSThread.callStackSymbols;
    NSDictionary *context = KcCurrentExecutionContext();
    pthread_mutex_lock(&KcDependencyMutex);
    int result = pthread_mutex_trylock(&_mutex);
    if (!result) KcGraphAcquire(_resource, _name, thread, stack, context);
    pthread_mutex_unlock(&KcDependencyMutex);
    if (result && result != EBUSY) {
        [NSException raise:NSInternalInconsistencyException format:@"mutex trylock: %d", result];
    }
    return result == 0;
}
- (void)lock {
    uint64_t thread = KcDiagnosticThreadID();
    NSArray *stack = NSThread.callStackSymbols;
    NSDictionary *context = KcCurrentExecutionContext();
    pthread_mutex_lock(&KcDependencyMutex);
    int result = pthread_mutex_trylock(&_mutex);
    if (!result) {
        KcGraphAcquire(_resource, _name, thread, stack, context);
        pthread_mutex_unlock(&KcDependencyMutex);
        return;
    }
    NSUUID *token = nil;
    @try {
        if (result == EBUSY) token = KcGraphWait(_resource, 0, _name, stack, context);
    } @finally {
        pthread_mutex_unlock(&KcDependencyMutex);
    }
    if (result != EBUSY) {
        [NSException raise:NSInternalInconsistencyException format:@"mutex trylock: %d", result];
    }
    // 此处才真正阻塞；监控线程始终可读取依赖图。
    result = pthread_mutex_lock(&_mutex);
    pthread_mutex_lock(&KcDependencyMutex);
    KcGraphEndWait(token);
    if (!result) KcGraphAcquire(_resource, _name, thread, stack, context);
    pthread_mutex_unlock(&KcDependencyMutex);
    if (result) [NSException raise:NSInternalInconsistencyException format:@"mutex lock: %d", result];
}
- (void)unlock {
    uint64_t thread = KcDiagnosticThreadID();
    pthread_mutex_lock(&KcDependencyMutex);
    // Release 校验 owner；异常通过 finally 释放内部图锁。
    @try {
        KcGraphRelease(_resource, thread);
        int result = pthread_mutex_unlock(&_mutex);
        if (result) [NSException raise:NSInternalInconsistencyException format:@"mutex unlock: %d", result];
    } @finally {
        pthread_mutex_unlock(&KcDependencyMutex);
    }
}
- (void)dealloc {
    pthread_mutex_destroy(&_mutex);
}
@end
