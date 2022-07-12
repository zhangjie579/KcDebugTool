//
//  UIWindow+KcDebugTool.m
//  OCTest
//
//  Created by samzjzhang on 2020/12/5.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "UIWindow+KcDebugTool.h"
#import "NSObject+KcRuntimeExtension.h"
@import KcDebugSwift;

@implementation UIWindow (KcDebugTool)

+ (void)kc_hook_becomeKeyWindow {
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    [tool kc_hookWithObjc:UIWindow.class
                 selector:@selector(becomeKeyWindow)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:info.selectorName format:@"%@", info.instance];
    } error:nil];
}

+ (void)kc_hook_hitTest {
    [UIWindow kc_hookSelectorName:NSStringFromSelector(@selector(hitTest:withEvent:))
              swizzleSelectorName:NSStringFromSelector(@selector(_kc_private_test_hitTest:withEvent:))];
}

- (UIView *)_kc_private_test_hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *_Nullable view = [self _kc_private_test_hitTest:point withEvent:event];
    
    NSString *description = [KcLogParamModel instanceDesc:view];
//    if (view && ![NSStringFromClass([view class]) hasPrefix:@"_"]) {
//        KcPropertyResult *property = property = [KcFindPropertyTooler findResponderChainObjcPropertyNameWithObject:view startSearchView:nil isLog:false];
//        if (property) {
//            description = [NSString stringWithFormat:@"%@, 响应者: %@", property.debugLog, [KcLogParamModel instanceDesc:view]];
//        } else {
//            description = [KcLogParamModel instanceDesc:view];
//        }
//    }
    
    [KcLogParamModel logWithKey:@"最佳响应者" format:@"%@", description ?: @""];
    
    return view;
}

@end
