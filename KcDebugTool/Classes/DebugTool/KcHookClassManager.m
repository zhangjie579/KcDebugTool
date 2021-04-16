//
//  KcHookClassManager.m
//  NowLive
//
//  Created by samzjzhang on 2020/4/24.
//  Copyright © 2020 now. All rights reserved.
//

#import "KcHookClassManager.h"
#import "NSObject+KcMethodExtension.h"
#import "KcHookProjectProtocol.h"
#import <dlfcn.h>

@implementation KcHookClassManager

/// load之后、main之前调用 (写在这, 可以不用导入到项目内, 也可以写在load内)
__attribute__((constructor)) void kc_hookDebugClass() {

    NSLog(@"KcHookClassManager start...");

    NSArray<NSString *> *hookProjectList = @[@"KcHookProject"];
    NSMutableArray<Class<KcHookProjectProtocol>> *classList = [[NSMutableArray alloc] init];
    [hookProjectList enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        Class cls = NSClassFromString(obj);
        if (!cls) {
            return;
        }
        [classList addObject:cls];
    }];

    // 延迟执行的原因: 代码里面有在app开始的时候有通过method_exchangeImplementations来hook方法, 而这边是通过Aspect来hook; "Aspect hook必须在method_exchangeImplementations hook之后"
    // 因为走forwardInvocation的时候, 会走到第1次hook的方法(比如是: 前缀_方法名), 它的实现是_objc_msgForward, 还是会走到Aspect的forwardInvocation, 但是获取的原始方法是: 前缀_方法名, aspect后的方法是: aspect__前缀_方法名, 找不到这个方法, crash
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [KcHookClassManager asyncAfter_hookDebugClass];
        [classList makeObjectsPerformSelector:@selector(startDelay)];
    });

    [KcHookClassManager sync_hookDebugClass];
    [classList makeObjectsPerformSelector:@selector(start)];
}

+ (void)asyncAfter_hookDebugClass {
    // hook - UINavigationController 跳转相关代码
//    [UIViewController kc_hook_navigationControllerWithShowBlock:^(Class  _Nonnull __unsafe_unretained toViewControllerType, UIViewController * _Nonnull fromViewController, UIViewController * _Nonnull toViewController) {
//        KcHookInfo *info = [KcHookInfo makeDefaultInfo];
//        info.logModel.isLogClassName = true;
//        
////        if (toViewController) {
////            [NSObject kc_hookInstanceMethodListWithObjc:toViewController.class info:info usingBlock:^(KcHookAspectInfo * _Nonnull info) {
////
////            }];
////        }
//    } dismissBlock:^(UIViewController * _Nonnull fromViewController) {
//        
//    }];
    
    // UIControl sendEvent
//    [NSObject kc_hookSendActionForEventWithBlock:^(KcHookAspectInfo * _Nonnull info) {
//
//    }];
    
    // gesture 看log 👻
    [NSObject kc_hookGestureRecognizerSendActionWithBlock:^(KcHookAspectInfo * _Nonnull info) {

    }];
    
    // 通知
//    [NSObject kc_hookNotificationNameWithFilterBlock:^BOOL(NSString * _Nonnull name) {
//        return [name isEqualToString:UIKeyboardWillShowNotification] || [name isEqualToString:UIKeyboardWillHideNotification];
//    } block:^(KcHookAspectInfo * _Nonnull info) {
//
//    }];
    
    // [UIApplication sendEvent:]
//    [NSObject kc_hookUIApplicationSendEventWithBlock:^(KcHookAspectInfo * _Nonnull info) {
//
//    }];
    
//    [[self kc_hookTool] kc_hookWithObjc:WKWebView.class selector:@selector(setUserInteractionEnabled:) withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
//
//    } error:nil];
}

/// 同步不延迟 hook (有些class, 延迟hook有问题)
+ (void)sync_hookDebugClass {
    {
        NSArray<NSString *> *classNames = @[
//            @"NWAVReceiverRTMP",
//            @"NWGLView",
            @"LVAVReceiveServiceImpl",
        ];
        
        NSMutableArray<NSString *> *blackSelectors = [KcHookClassManager blackSelectors_qb];
        KcHookInfo *parameters          = [[KcHookInfo alloc] init];
        
        KcMethodInfo *methodInfo        = [[KcMethodInfo alloc] init];
        parameters.methodInfo           = methodInfo;
        methodInfo.isHookGetMethod      = false;
        methodInfo.isHookSetMethod      = false;
        methodInfo.isHookSuperClass     = false;
        methodInfo.whiteSelectors       = nil;
        methodInfo.blackSelectors       = blackSelectors;
        
        KcLogParamModel *logModel       = [[KcLogParamModel alloc] init];
        parameters.logModel             = logModel;
        logModel.isLogExecuteTime       = false;
        logModel.isLog                  = true;
        logModel.isLogClassName         = true;
        logModel.isOnlyLogTimeoutMethod = false;
        logModel.isLogTarget            = false;

        // hook - class 所有方法
        [classNames enumerateObjectsUsingBlock:^(NSString * _Nonnull name, NSUInteger idx, BOOL * _Nonnull stop) {
            [NSObject kc_hookInstanceMethodListWithObjc:NSClassFromString(name) info:parameters usingBlock:^(KcHookAspectInfo * _Nonnull info) {
                
            }];
        }];
    }
}

/// hook一些class的所有方法
+ (void)hookAnyMethodsWithClassNames:(NSArray<NSString *> *)classNames block:(void(^)(KcHookInfo *params))block {
    NSArray<NSString *> *blackSelectors = [KcHookClassManager blackSelectors_qb];
    KcHookInfo *parameters          = [[KcHookInfo alloc] init];
    
    KcMethodInfo *methodInfo        = [[KcMethodInfo alloc] init];
    parameters.methodInfo           = methodInfo;
    methodInfo.isHookGetMethod      = false;
    methodInfo.isHookSetMethod      = false;
    methodInfo.isHookSuperClass     = false;
    methodInfo.whiteSelectors       = nil;
    methodInfo.blackSelectors       = blackSelectors;
    
    KcLogParamModel *logModel       = [[KcLogParamModel alloc] init];
    parameters.logModel             = logModel;
    logModel.isLogExecuteTime       = false;
    logModel.isLog                  = true;
    logModel.isLogClassName         = true;
    logModel.isOnlyLogTimeoutMethod = false;
    logModel.isLogTarget            = false;
    
    if (block) {
        block(parameters);
    }
    
    // hook - class 所有方法
    [classNames enumerateObjectsUsingBlock:^(NSString * _Nonnull name, NSUInteger idx, BOOL * _Nonnull stop) {
        [NSObject kc_hookInstanceMethodListWithObjc:NSClassFromString(name) info:parameters usingBlock:^(KcHookAspectInfo * _Nonnull info) {
            
        }];
    }];
}

#pragma mark - Tool

/// 黑名单
+ (NSMutableArray<NSString *> *)blackSelectors_qb {
    NSMutableArray<NSString *> *blackSelectors = [NSMutableArray array];
    return blackSelectors;
}

#pragma mark - clang插桩hook(会hook所有自定义的方法)

/* 使用
 1.Other C Flags , 添加 -fsanitize-coverage=func,trace-pc-guard
 2.打开下面2个方法即可
 */

//void __sanitizer_cov_trace_pc_guard_init(uint32_t *start,
//                                         uint32_t *stop) {
//    static uint64_t N;  // Counter for the guards.
//    if (start == stop || *start) return;  // Initialize only once.
//    printf("INIT: %p %p\n", start, stop);
//    for (uint32_t *x = start; x < stop; x++)
//        *x = ++N;  // Guards should start from 1.
//}
///// clang插桩 实现hook, 可以hook c、swift、oc方法
///// 随便将这2段代码放在任意一个文件内, 编译时会将`__sanitizer_cov_trace_pc_guard`加入到自己实现的方法内
//void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
//    //if (!*guard) return;  // Duplicate the guard check.
//
//    void *PC = __builtin_return_address(0);
//    Dl_info info;
//    dladdr(PC, &info);
//
//    printf("fname=%s \nfbase=%p \nsname=%s\nsaddr=%p \n", info.dli_fname, info.dli_fbase, info.dli_sname, info.dli_saddr);
////    NSString *name = [NSString stringWithUTF8String:info.dli_sname]; // -[NLRoomDRHelper onTimer:]
////    if (name.length > 1 && [name containsString:@"["]) {
////        name = [name substringFromIndex:2];
////    }
////    if ([name hasPrefix:@"NLRoomViewController"]) {
////        printf("kc--- 方法名=%s saddr=%p \n", info.dli_sname, info.dli_saddr);
////    }
//}

@end


