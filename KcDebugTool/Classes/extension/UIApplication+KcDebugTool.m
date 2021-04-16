//
//  UIApplication+KcDebugTool.m
//  OCTest
//
//  Created by samzjzhang on 2020/12/6.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "UIApplication+KcDebugTool.h"

@implementation UIApplication (KcDebugTool)

+ (void)kc_hook_idleTimerDisabledWithBlock:(void(^)(KcHookAspectInfo * _Nonnull info))block {
    KcHookTool *hookTool = [[KcHookTool alloc] init];
    [hookTool kc_hookWithObjc:UIApplication.sharedApplication
                     selector:@selector(setIdleTimerDisabled:)
                  withOptions:KcAspectTypeBefore
                   usingBlock:block
                        error:nil];
}

@end
