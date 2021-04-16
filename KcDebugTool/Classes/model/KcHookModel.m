//
//  KcHookModel.m
//  NowLive
//
//  Created by samzjzhang on 2020/4/24.
//  Copyright © 2020 now. All rights reserved.
//

#import "KcHookModel.h"
#import "KcHookTool.h"
#import "KcAspects.h"

@implementation KcHookModel

- (instancetype)initWithKey:(id)key value:(id)value {
    if (self = [super init]) {
        _key = key;
        _value = value;
    }
    return self;
}

@end

@implementation KcMethodInfo

/// 默认黑名单
+ (NSArray<NSString *> *)defaultBlackSelectorNames {
    return @[ @"alloc",
              @"init",
              @"dealloc",
              @"initialize",
              @"load",
              @".cxx_destruct",
              @"_isDeallocating",
              @"release",
              @"autorelease",
              @"retain",
              @"Retain",
              @"_tryRetain",
              @"copy",
              /*UIView的:*/
              @"nsis_descriptionOfVariable:",
              /*NSObject的:*/
              @"respondsToSelector:",
              @"class",
              @"methodSignatureForSelector:",
              @"allowsWeakReference",
              @"retainWeakReference",
              @"forwardInvocation:",
              @"description",
              @"debugDescription",
              @"self",
              
              // --- 横竖屏
              @"shouldAutorotate",
              @"supportedInterfaceOrientations",
              @"preferredInterfaceOrientationForPresentation",
              @"interfaceOrientation",
              
              @"prefersStatusBarHidden",
              @"setStatusBarStyle:",
              @"statusBarStyle",
    ];
}

@end

@implementation KcLogParamModel

+ (void)logWithString:(NSString *)string {
    NSLog(@"kc --- %@", string);
}

+ (void)logWithKey:(NSString *)key format:(NSString *)format, ... {
    NSString *msg = @"";
    
    va_list arglist;
    va_start(arglist, format);
    if (format) {
        msg = [[NSString alloc] initWithFormat:format arguments:arglist];
    }
    va_end(arglist);
    
    NSLog(@"kc --- [%@] %@", key, msg);
}

- (void)defaultLogWithInfo:(KcHookAspectInfo *)info {
    
    NSString *(^methodDescriptionLog)(void) = ^NSString * {
        NSString *selectorName = info.selectorNameFilterPrefix;
        if (self.isLogTarget) {
            return [NSString stringWithFormat:@"%@.%@", info.instance, selectorName];
        } else if (self.isLogClassName) {
            return [NSString stringWithFormat:@"%@.%@", info.className, selectorName];
        } else {
            return [NSString stringWithFormat:@"%@", info.selectorName];
        }
    };
    
    // 1.超时
    if (self.isOnlyLogTimeoutMethod) {
        if (!info.aspectInfo) {
            [self.class logWithString:@"当前hook模式下不能获取到方法的执行时间, 请改用aspect是方式 ⚠️⚠️⚠️"];
        }
        
        id<KcAspectInfo> aspectInfo = info.aspectInfo;
        double timeout = self.timeout <= 0 ? self.defaultTimeout : self.timeout;
        if (aspectInfo.duration >= timeout) {
            [self.class logWithString:[NSString stringWithFormat:@"%@, 执行时间: %f", methodDescriptionLog(), aspectInfo.duration]];
        }
        return;
    }
    
    // 2.是否log
    if (!self.isLog) {
        return;
    }
    
    // 限频
    if (self.filterHighFrequencyLog &&
        [self filterHighFrequencyLogWithIdentity:[NSString stringWithFormat:@"[%@ %@]", info.className, info.selectorNameFilterPrefix]]) {
        return;
    }
    
    // 3.输出执行时间
    if (self.isLogExecuteTime) {
        if (!info.aspectInfo) {
            [self.class logWithString:@"当前hook模式下不能获取到方法的执行时间, 请改用aspect是方式 ⚠️⚠️⚠️"];
        }
        id<KcAspectInfo> aspectInfo = info.aspectInfo;
        [self.class logWithString:[NSString stringWithFormat:@"%@, 执行时间: %f", methodDescriptionLog(), aspectInfo.duration]];
    } else {
        [self.class logWithString:methodDescriptionLog()];
    }
}

- (double)defaultTimeout {
    return 0.02;
}

//+ (void)logWithFormat:(NSString *)format, ... {
//    NSLog(@"kc--- %@", format, __VA_ARGS__);
//}

/// 过滤高频
- (BOOL)filterHighFrequencyLogWithIdentity:(NSString *)identity {
    static NSMutableDictionary<NSString *, NSNumber *> *cacheLog;
    if (!cacheLog) {
        cacheLog = [[NSMutableDictionary alloc] init];
    }
    
    static NSCache<NSString *, NSNumber *> *cacheInterval;  // 确定是否需要过滤的log 时间间隔
    static NSCache<NSString *, NSNumber *> *cacheTime;      // 次数
    static NSMutableSet<NSString *> *filterLogs; // 已经确定是需要过滤的log
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cacheInterval = [[NSCache alloc] init];
        cacheTime = [[NSCache alloc] init];
        filterLogs = [[NSMutableSet alloc] init];
    });
    
    if ([filterLogs containsObject:identity]) {
        return true;
    }
    
    NSNumber * _Nullable number = [cacheInterval objectForKey:identity];
    if (!number) {
        [cacheInterval setObject:@(CFAbsoluteTimeGetCurrent()) forKey:identity];
        return false;
    }
    
    double interval = number.doubleValue - CFAbsoluteTimeGetCurrent();
    if (interval > self.frequencyInterval) {
        [cacheInterval setObject:@(CFAbsoluteTimeGetCurrent()) forKey:identity];
        [cacheTime removeObjectForKey:identity];
        
        return false;
    }
    
    if (self.frequencyTime <= 1) {
        [filterLogs addObject:identity];
        return true;
    }
    
    NSInteger time = [cacheTime objectForKey:identity].integerValue + 1;
    if (time > self.frequencyTime) {
        [filterLogs addObject:identity];
        return true;
    }
    
    [cacheTime setObject:@(time) forKey:identity];
    
    return false;
}

@end

@implementation KcHookInfo

+ (instancetype)makeDefaultInfo {
    KcHookInfo *parameters     = [[KcHookInfo alloc] init];
    
    KcMethodInfo *methodInfo = [[KcMethodInfo alloc] init];
    methodInfo.isHookGetMethod       = false;
    methodInfo.isHookSetMethod       = false;
    methodInfo.isHookSuperClass      = false;
    parameters.methodInfo = methodInfo;
    
    KcLogParamModel *logModel = [[KcLogParamModel alloc] init];
    logModel.isLogExecuteTime      = false;
    logModel.isLog                 = true;
    logModel.isLogClassName        = false;
    parameters.logModel = logModel;

    return parameters;
}

@end

