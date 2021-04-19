//
//  KcDebugLayout.m
//  KcDebugTool
//
//  Created by 张杰 on 2021/4/16.
//

#import "KcDebugLayout.h"

@implementation UIView (KcDebugLayout)

+ (NSString *)kc_debug_rootWindowViewHierarchy {
    return [UIApplication.sharedApplication.keyWindow ?: UIApplication.sharedApplication.delegate.window kc_debug_viewHierarchy];
}

+ (NSString *)kc_debug_keyWindowViewHierarchy {
    return [UIApplication.sharedApplication.keyWindow kc_debug_viewHierarchy];
}

/// 打印view层级
- (NSString *)kc_debug_viewHierarchy {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSString *description = [self performSelector:NSSelectorFromString(@"recursiveDescription")];
    #pragma clang diagnostic pop
    NSLog(@"%@", description);
    return description;
}

/// 打印自动布局层级
- (NSString *)kc_debug_autoLayoutHierarchy {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSString *description = [self performSelector:NSSelectorFromString(@"_autolayoutTrace")];
    #pragma clang diagnostic pop
    NSLog(@"%@", description);
    return description;
}

@end

#pragma mark - UIViewController

@implementation UIViewController (KcDebugLayout)

/// 打印ViewController的层级
- (void)kc_debug_viewControllerHierarchy {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSString *description = [self performSelector:NSSelectorFromString(@"_printHierarchy")];
    #pragma clang diagnostic pop
    NSLog(@"%@", description);
}

@end
