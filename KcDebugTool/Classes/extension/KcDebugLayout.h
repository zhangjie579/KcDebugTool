//
//  KcDebugLayout.h
//  KcDebugTool
//
//  Created by 张杰 on 2021/4/16.
//  调试布局

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 系统的扩展 (UIView (UIConstraintBasedLayoutDebugging)), 通过view.hasAmbiguousLayout 找到对应定义地方
@interface UIView (KcDebugLayout)

/// 打印view层级
+ (NSString *)kc_rootWindowViewHierarchy;
+ (NSString *)kc_keyWindowViewHierarchy;
/// 打印view层级
- (NSString *)kc_viewHierarchy;

/// 打印自动布局层级
- (NSString *)kc_autoLayoutHierarchy;

@end

@interface UIViewController (KcDebugLayout)

/// 打印ViewController的层级
- (void)kc_viewControllerHierarchy;

@end

NS_ASSUME_NONNULL_END
