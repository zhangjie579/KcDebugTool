//
//  UIApplication+KcDebugTool.h
//  OCTest
//
//  Created by samzjzhang on 2020/12/6.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "KcHookTool.h"
#import "KcHookModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface UIApplication (KcDebugTool)

+ (void)kc_hook_idleTimerDisabledWithBlock:(void(^)(KcHookAspectInfo * _Nonnull info))block;

@end

NS_ASSUME_NONNULL_END
