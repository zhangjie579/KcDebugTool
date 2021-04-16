//
//  UIWindow+KcDebugTool.m
//  OCTest
//
//  Created by samzjzhang on 2020/12/5.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "UIWindow+KcDebugTool.h"

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

@end
