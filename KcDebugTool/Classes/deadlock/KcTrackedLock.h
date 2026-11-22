#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// 调试用互斥锁。只跟踪此实例，不 hook 系统锁。遵守同线程 unlock 语义。
/// 替换业务 NSLock/NSRecursiveLock 的使用点；不要用于 condition wait / 跨线程 signal。
@interface KcTrackedLock : NSObject <NSLocking>
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly, getter=isRecursive) BOOL recursive;
- (instancetype)initWithName:(NSString *)name recursive:(BOOL)recursive NS_DESIGNATED_INITIALIZER;
- (instancetype)init;
- (void)lock;
- (BOOL)tryLock;
- (void)unlock;
@end
NS_ASSUME_NONNULL_END
