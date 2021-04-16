//
//  KcScrollViewTool.h
//  KcDebugTool
//
//  Created by 张杰 on 2021/4/16.
//  管理view滑动的工具

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KcScrollViewTool : NSObject

@property (nonatomic) UIView *view;

/// 是否可滑动(默认: yes)
@property (nonatomic) BOOL enableScrolled;

/// 是否点击结束编辑 - 默认false
@property (nonatomic) BOOL shouldTapEndEditing;
@property (nonatomic) BOOL (^shouldReceiveTouch)(UIGestureRecognizer *gestureRecognizer, UITouch *touch);

@end

NS_ASSUME_NONNULL_END
