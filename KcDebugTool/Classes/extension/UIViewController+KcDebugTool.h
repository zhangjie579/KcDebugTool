//
//  UIViewController+KcDebugTool.h
//  OCTest
//
//  Created by samzjzhang on 2020/4/27.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "KcHookTool.h"
#import "KcHookModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface UIViewController (KcDebugTool)

/// 获取最上层UIViewController, baseViewController为keyWindow.rootViewController
+ (UIViewController *)kc_topViewController;
/// 获取最上层UIViewController
+ (UIViewController *)kc_topViewControllerWithBaseViewController:(UIViewController *)baseViewController;

#pragma mark - hook

/// 横竖屏
+ (void)kc_hook_RotationToDeviceOrientation;

/// 跳转方法
+ (void)kc_hook_navigationControllerWithShowBlock:(void(^ _Nullable)(Class toViewControllerType, UIViewController *fromViewController, UIViewController *toViewController))showBlock
                                     dismissBlock:(void(^ _Nullable)(UIViewController *fromViewController))dismissBlock;

/// hook viewController (showViewController、showDetailViewController)方法
+ (void)kc_hook_viewControllerShowWithBlock:(void(^ _Nullable)(Class toViewControllerType, UIViewController *fromViewController, UIViewController *toViewController))block;

/// viewController的生命周期方法
+ (void)kc_hookViewControllerLifeCycle:(NSArray<NSString *> *)controllerCls
                                 block:(void(^)(KcHookAspectInfo *info))block;

/// hook viewController init
+ (void)kc_hook_initWithViewControllerClassNames:(NSSet<NSString *> *)classNames;

/// hook initWithNibName
+ (void)kc_hook_initWithNibNameWithBlock:(void(^_Nullable)(KcHookAspectInfo * _Nonnull info))block;

@end

/// 导航栏
@interface UIViewController (KcDebugNavigation)

+ (void)kc_hook_navigationController;

/// 导航栏item
+ (void)kc_hookNavigationBarButtonItem;

+ (void)kc_hook_setTitle;

/// 导航栏背景色
+ (void)kc_hook_navigationBarColor;

@end

NS_ASSUME_NONNULL_END
