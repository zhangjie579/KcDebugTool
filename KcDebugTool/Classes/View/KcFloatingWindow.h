//
//  KcFloatingWindow.h
//  OCTest
//
//  Created by samzjzhang on 2020/4/28.
//  Copyright © 2020 samzjzhang. All rights reserved.
//  悬浮window, 可滑动

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface KcFloatingWindow : UIWindow

/// 是否可滑动(默认: yes)
@property (nonatomic) BOOL enableScrolled;

/// 是否点击结束编辑 - 默认false
@property (nonatomic) BOOL shouldTapEndEditing;
@property (nonatomic) BOOL (^shouldReceiveTouch)(UIGestureRecognizer *gestureRecognizer, UITouch *touch);

@end

NS_ASSUME_NONNULL_END
