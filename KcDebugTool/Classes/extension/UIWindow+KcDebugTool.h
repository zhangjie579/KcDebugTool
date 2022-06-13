//
//  UIWindow+KcDebugTool.h
//  OCTest
//
//  Created by samzjzhang on 2020/12/5.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "KcHookTool.h"
#import "KcHookModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface UIWindow (KcDebugTool)

+ (void)kc_hook_becomeKeyWindow;

/// hitTest:withEvent:
+ (void)kc_hook_hitTest;

@end

NS_ASSUME_NONNULL_END
