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

#pragma mark - 自启动

/// load之后、main之前调用 (写在这, 可以不用导入到项目内, 也可以写在load内)
/* 说明
 1. 现在iOS已经禁用了通过runtime的接口获取method, 获取的为nil, 如何 hook 私有方法 ❓
    * 可以通过自己解析MachO
    * 符号断点 👻
 */
__attribute__((constructor)) void kc_hookDebugClass(void) {
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [KcHookClassManager asyncAfter_hookDebugClass];
        [classList makeObjectsPerformSelector:@selector(startDelay)];
    });

    [KcHookClassManager sync_hookDebugClass];
    [classList makeObjectsPerformSelector:@selector(start)];
}

+ (void)asyncAfter_hookDebugClass {
    // hook - UINavigationController 跳转相关代码 👻
    [UIViewController kc_hook_navigationControllerWithShowBlock:^(Class  _Nonnull __unsafe_unretained toViewControllerType, UIViewController * _Nonnull fromViewController, UIViewController * _Nonnull toViewController) {
        KcHookInfo *info = [KcHookInfo makeDefaultInfo];
        info.logModel.isLogClassName = true;

//        if (toViewController) {
//            [NSObject kc_hookInstanceMethodListWithObjc:toViewController.class info:info usingBlock:^(KcHookAspectInfo * _Nonnull info) {
//
//            }];
//        }
    } dismissBlock:^(UIViewController * _Nonnull fromViewController) {

    }];
    
    // UIControl sendEvent 👻
    [NSObject kc_hook_sendActionForEventWithBlock:^(KcHookAspectInfo * _Nonnull info) {

    }];
    
    // gesture 看log 👻
    [NSObject kc_hook_gestureRecognizerAllTargetActionWithBlock:^(KcHookAspectInfo * _Nonnull info) {

    }];
    
    // cell相关 👻
    [UITableView kc_hook_cellDidSelect];
    [UICollectionView kc_hook_cellDidSelect];
    
    { // UIViewController dealloc 👻
        // 如果这个方法会crash, 可用下发的方法
        [UIViewController kc_hook_deallocWithBlock:^(KcHookAspectInfo * _Nonnull info) {
            // 过滤非自定义的class
            if (!info.instanceClass || ![NSObject kc_isCustomClass:info.instanceClass]) {
                return;
            }
            [KcLogParamModel logWithKey:@"dealloc" format:@"%@", info.className];
        }];
        
//        [UIViewController kc_hook_initWithNibNameWithBlock:^(KcHookAspectInfo * _Nonnull info) {
//            NSString *className = info.className;
//            Class __nullable instanceClass = info.instanceClass;
//            [info.instance kc_deallocObserverWithBlock:^{
//                // 过滤非自定义的class
//                if (!instanceClass || ![NSObject kc_isCustomClass:instanceClass]) {
//                    return;
//                }
//                [KcLogParamModel logWithKey:@"dealloc" format:@"%@", className];
//            }];
//        }];
    }
    
    // 大图检测 👻
//    [KcDetectLargerImageTool start];
    
    // 第一响应者
//    [UIView kc_hook_firstResponder];
    
    // 监听UIPresentationController
//    [NSObject.kc_hookTool kc_hookWithObjc:UIPresentationController.class
//                             selectorName:NSStringFromSelector(@selector(_setPresentingViewController:)) withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
//        NSLog(@"aa -- %@", info.arguments.firstObject);
//    }];
    
//    [NSObject.kc_hookTool kc_hookWithObjc:UITableView.class
//                             selectorName:NSStringFromSelector(@selector(setContentSize:))
//                              withOptions:KcAspectTypeBefore
//                               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
//        NSLog(@"aa -- 1, %@", info.arguments.firstObject);
//    }];
//    
//    [NSObject.kc_hookTool kc_hookWithObjc:UITableView.class
//                             selectorName:NSStringFromSelector(@selector(reloadData))
//                              withOptions:KcAspectTypeAfter
//                               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
//        NSLog(@"aa -- 2, height: %d", [info.instance contentSize].height);
//    }];
    
//    Class barBackgroundClass = NSClassFromString(@"_UIBarBackground");
//    [NSObject.kc_hookTool kc_hookWithObjc:UIView.class
//                             selectorName:NSStringFromSelector(@selector(setBackgroundColor:)) withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
//        if ([[info.instance class] isKindOfClass:barBackgroundClass]) {
//            NSLog(@"aa -- %@", info.arguments.firstObject);
//        }
//    }];
    
    // 通知
//    [NSObject kc_hook_notificationNameWithFilterBlock:^BOOL(NSString * _Nonnull name) {
//        return [name isEqualToString:UIKeyboardWillShowNotification] || [name isEqualToString:UIKeyboardWillHideNotification];
//    } block:^(KcHookAspectInfo * _Nonnull info) {
//
//    }];
    
    // [UIApplication sendEvent:] 👻
//    [NSObject kc_hook_UIApplicationSendEventWithBlock:^(KcHookAspectInfo * _Nonnull info) {
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
            [NSObject kc_hook_instanceMethodListWithObjc:NSClassFromString(name) info:parameters usingBlock:^(KcHookAspectInfo * _Nonnull info) {
                
            }];
        }];
    }
    
//    [NSObject kc_hook_gestureRecognizerAllTargetActionWithBlock:^(KcHookAspectInfo * _Nonnull info) {
//
//    }];
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
        [NSObject kc_hook_instanceMethodListWithObjc:NSClassFromString(name) info:parameters usingBlock:^(KcHookAspectInfo * _Nonnull info) {
            
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

/* 使用 https://clang.llvm.org/docs/SanitizerCoverage.html
 1.Other C Flags , 添加 -fsanitize-coverage=func,trace-pc-guard
 * 搜索Other Swift Flags , 添加两条配置即可 :
     * -sanitize-coverage=func
     * -sanitize=undefined
 
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
////    printf("fbase=%p sname=%s saddr=%p %p \n", info.dli_fbase, info.dli_sname, info.dli_saddr, PC);
////    NSString *name = [NSString stringWithUTF8String:info.dli_sname]; // -[NLRoomDRHelper onTimer:]
////    if (name.length > 1 && [name containsString:@"["]) {
////        name = [name substringFromIndex:2];
////    }
////    if ([name hasPrefix:@"NLRoomViewController"]) {
////        printf("kc--- 方法名=%s saddr=%p, %p \n", info.dli_sname, info.dli_saddr, PC);
////    }
//}

@end


