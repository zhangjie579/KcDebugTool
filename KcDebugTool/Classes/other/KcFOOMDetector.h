//
//  KcFOOMDetector.h
//  Pods
//
//  Created by 张杰 on 2023/4/25.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/*
 https://www.infoq.cn/article/ox7u3ymwiwzamt1vgm7m
 https://engineering.fb.com/2015/08/24/ios/reducing-fooms-in-the-facebook-ios-app/
 https://www.jianshu.com/p/c2e2e53ffb16
 https://developer.umeng.com/docs/193624/detail/305627
 
 
 1.App没有升级
 2.App没有调用exit()或abort()退出
 3.App没有出现Crash (依赖于自身CrashReport组件的Crash回调)
 4.用户没有强退App - applicationWillTerminate
 5.系统没有升级/重启
 6.watchdog
 7.App当时没有后台运行（依赖于ApplicationState和前后台切换通知）
 8.App出现FOOM （依赖于ApplicationState和前后台切换通知）
 */
@interface KcFOOMDetector : NSObject

+ (void)beginMonitoringMemoryEventsWithHandler:(void(^)(BOOL wasInForeground, BOOL watchDog))handler
                                 crashDetector:(BOOL(^)(void))crashDetector
                               appVersionBlock:(NSString *(^_Nullable)(void))appVersionBlock;

@end

NS_ASSUME_NONNULL_END
