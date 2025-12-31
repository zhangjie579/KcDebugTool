//
//  UIViewController+KcDebugTool.m
//  OCTest
//
//  Created by samzjzhang on 2020/4/27.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "UIViewController+KcDebugTool.h"
#import "NSObject+KcMethodExtension.h"

@implementation UIViewController (KcDebugTool)

/// 获取最上层UIViewController, baseViewController为keyWindow.rootViewController
+ (UIViewController *)kc_topViewController {
    // [[[UIApplication sharedApplication] keyWindow] rootViewController]有时为nil 比如当页面有菊花在转的时候
    return [self kc_topViewControllerWithBaseViewController:UIApplication.sharedApplication.delegate.window.rootViewController ?: UIApplication.sharedApplication.keyWindow.rootViewController];
}

/// 获取最上层UIViewController
+ (UIViewController *)kc_topViewControllerWithBaseViewController:(UIViewController *)baseViewController {
    if (baseViewController.presentedViewController) {
        return [self kc_topViewControllerWithBaseViewController:baseViewController.presentedViewController];
    }
    else if ([baseViewController isKindOfClass:[UINavigationController class]]) {
        return [self kc_topViewControllerWithBaseViewController:[(UINavigationController *)baseViewController visibleViewController]];
    }
    else if ([baseViewController isKindOfClass:[UITabBarController self]]) {
        UITabBarController *tabBarController = (UITabBarController *)baseViewController;
        if (tabBarController.selectedViewController) {
            return [self kc_topViewControllerWithBaseViewController:tabBarController.selectedViewController];
        }
    }
    else if (baseViewController.childViewControllers.count > 0) {
        return [self kc_topViewControllerWithBaseViewController:baseViewController.childViewControllers.lastObject];
    }
    return baseViewController;
}

#pragma mark - 横竖屏

/*
 + (void)attemptRotationToDeviceOrientation

 // Applications should use supportedInterfaceOrientations and/or shouldAutorotate.
 - (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation

 // New Autorotation support.
 @property(nonatomic, readonly) BOOL shouldAutorotate
 @property(nonatomic, readonly) UIInterfaceOrientationMask supportedInterfaceOrientations
 @property(nonatomic, readonly) UIInterfaceOrientation preferredInterfaceOrientationForPresentation
 */

/// 横竖屏
+ (void)kc_hook_RotationToDeviceOrientation {
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    [tool kc_hookWithObjc:UIApplication.sharedApplication.delegate
                 selector:@selector(application:supportedInterfaceOrientationsForWindow:)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"横竖屏" format:@"%@, window: %@", info.selectorName, info.arguments[1]];
    } error:nil];
    
    [tool kc_hookWithObjc:UIViewController.class
                 selector:@selector(supportedInterfaceOrientations)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"横竖屏" format:@"%@: %@", info.selectorName, info.instance];
    } error:nil];
    
    [tool kc_hookWithObjc:UIViewController.class
                 selector:@selector(shouldAutorotate)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"横竖屏" format:@"%@: %@", info.selectorName, info.instance];
    } error:nil];
    
    [tool kc_hookWithObjc:UIViewController.class
                 selector:@selector(attemptRotationToDeviceOrientation)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"横竖屏" format:@"%@: %@", info.selectorName, info.instance];
    } error:nil];
    
    [tool kc_hookWithObjc:UIDevice.class
                 selector:@selector(setOrientation:)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        UIDeviceOrientation orientation = (UIDeviceOrientation)[info.arguments[0] integerValue];
//        BOOL isPortrait = UIDeviceOrientationIsPortrait(orientation);
        BOOL isLandscape = UIDeviceOrientationIsLandscape(orientation);
        [KcLogParamModel logWithKey:@"横竖屏" format:@"UIDevice.orientation: %d, isLandscape: %d", orientation, isLandscape];
    } error:nil];
    
    // - (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id <UIViewControllerTransitionCoordinator>)coordinator
    [tool kc_hookWithObjc:UIViewController.class
                 selector:@selector(viewWillTransitionToSize:withTransitionCoordinator:)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"横竖屏" format:@"%@: %@", info.selectorName, info.instance];
    } error:nil];
}

/// 跳转方法
+ (void)kc_hook_navigationControllerWithShowBlock:(void(^ _Nullable)(Class toViewControllerType, UIViewController *fromViewController, UIViewController *toViewController))showBlock
                                     dismissBlock:(void(^ _Nullable)(UIViewController *fromViewController))dismissBlock {
    NSString *selectorNamePush = NSStringFromSelector(@selector(pushViewController:animated:));
    NSString *selectorNamePresent = NSStringFromSelector(@selector(presentViewController:animated:completion:));
    NSString *selectorNameDismiss = NSStringFromSelector(@selector(dismissViewControllerAnimated:completion:));
    NSString *selectorNamePop = NSStringFromSelector(@selector(popViewControllerAnimated:));
    
    // 默认走push
//    NSString *selectorNameShow = NSStringFromSelector(@selector(showViewController:sender:));
    // 默认走present
//    NSString *selectorNameShowDetail = NSStringFromSelector(@selector(showDetailViewController:sender:));
    
    NSArray<KcHookModel<UIViewController *, NSString *> *> *array = @[
        [[KcHookModel alloc] initWithKey:[UINavigationController class] value:selectorNamePush],
        [[KcHookModel alloc] initWithKey:[UIViewController class] value:selectorNamePresent],
        
        [[KcHookModel alloc] initWithKey:[UIViewController class] value:selectorNameDismiss],
        [[KcHookModel alloc] initWithKey:[UINavigationController class] value:selectorNamePop],
        
//        [[KcHookModel alloc] initWithKey:[UIViewController class] value:selectorNameShow],
//        [[KcHookModel alloc] initWithKey:[UIViewController class] value:selectorNameShowDetail],
    ];
    
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    [array enumerateObjectsUsingBlock:^(KcHookModel * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [tool kc_hookWithObjc:obj.key selectorName:obj.value withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
            UIViewController *fromViewController = [UIViewController kc_topViewControllerWithBaseViewController:info.instance];
            UIViewController * _Nullable toViewController = nil;
            
            if ([obj.value isEqualToString:selectorNamePush] ||
                [obj.value isEqualToString:selectorNamePresent]) {
                
                // push、present, 监听from对象的销毁 (这样会导致后面push的页面销毁, 并且不走pop逻辑)
//                [tool kc_hookWithObjc:info.instance
//                         selectorName:@"dealloc"
//                          withOptions:KcAspectTypeBefore
//                           usingBlock:^(KcHookAspectInfo * _Nonnull subInfo) {
//                    [KcLogParamModel logWithKey:@"跳转 - from对象dealloc - ⚠️" format:@"%@", subInfo.instance];
//                }];
                
                // 通过isa修改dealloc方法, 可能会导致Swift deinit方法不调用⚠️
                Class cls = [info.instance class];
                [info.instance kc_deallocObserverWithBlock:^{
                    [KcLogParamModel logWithKey:@"跳转 - from对象dealloc - ⚠️" format:@"%@", cls];
                }];
                
                toViewController = [UIViewController kc_topViewControllerWithBaseViewController:info.arguments.firstObject];
                if (showBlock) {
                    showBlock([toViewController class], fromViewController, toViewController);
                }
            } else if ([obj.value isEqualToString:selectorNameDismiss] ||
                       [obj.value isEqualToString:selectorNamePop]) {
                if (dismissBlock) {
                    dismissBlock(fromViewController);
                }
            }
            [KcLogParamModel logWithKey:@"跳转" format:@"%@ from: %@, to: %@, self: %@", obj.value, fromViewController, toViewController ?: @"", info.instance];
        }];
    }];
}

/// hook viewController (showViewController、showDetailViewController)方法
+ (void)kc_hook_viewControllerShowWithBlock:(void(^ _Nullable)(Class toViewControllerType, UIViewController *fromViewController, UIViewController *toViewController))block {
    void (^handleClosure)(KcHookAspectInfo * _Nonnull) = ^(KcHookAspectInfo * _Nonnull info) {
        UIViewController *from = info.instance;
        UIViewController *to = info.arguments.firstObject;
        
        if (block) {
            block([to class], from, to);
        }
        
        NSString *selectorName = [info.selectorName substringToIndex:[info.selectorName rangeOfString:@":"].location];
        
        [KcLogParamModel logWithKey:@"跳转"
                             format:@"%@ from: %@, to: %@", selectorName, from, to];
    };
    
    [self.kc_hookTool kc_hookWithObjc:self
                            selector:@selector(showViewController:sender:)
                        withOptions:KcAspectTypeBefore
                           usingBlock:handleClosure
                                error:nil];
    
    [self.kc_hookTool kc_hookWithObjc:self
                            selector:@selector(showDetailViewController:sender:)
                        withOptions:KcAspectTypeBefore
                           usingBlock:handleClosure
                                error:nil];
}

/// viewController的生命周期方法
+ (void)kc_hookViewControllerLifeCycle:(NSArray<NSString *> *)controllerCls block:(void(^)(KcHookAspectInfo *info))block {
    NSArray<NSString *> *selectorNames = @[@"viewWillAppear:",
                                           @"viewWillDisappear:",
                                           @"viewDidAppear:",
                                           @"viewDidDisappear:"];
    [controllerCls enumerateObjectsUsingBlock:^(NSString * _Nonnull name, NSUInteger idx, BOOL * _Nonnull stop) {
        [selectorNames enumerateObjectsUsingBlock:^(NSString * _Nonnull selectorName, NSUInteger idx, BOOL * _Nonnull stop) {
            [self.kc_hookTool kc_hookWithObjc:NSClassFromString(name)
                                     selector:NSSelectorFromString(selectorName)
                                  withOptions:KcAspectTypeBefore
                                   usingBlock:^(KcHookAspectInfo * _Nonnull info) {
                [KcLogParamModel logWithKey:@"生命周期" format:@"[%@ %@] - %@ ", [info.instance class], info.selectorName, info.instance];
                if (block) {
                    block(info);
                }
            } error:nil];
        }];
    }];
}

#pragma mark - init

/// hook viewController init
+ (void)kc_hook_initWithViewControllerClassNames:(NSSet<NSString *> *)classNames {
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    [tool kc_hookWithObjc:[UIViewController class]
                 selector:@selector(initWithNibName:bundle:)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        if (![info.instance kc_isClassOrSubClass:classNames]) {
            return;
        }
        [KcLogParamModel logWithKey:@"init" format:@"viewController: %@", info.instance];
    } error:nil];
}

/// hook initWithNibName
+ (void)kc_hook_initWithNibNameWithBlock:(void(^_Nullable)(KcHookAspectInfo * _Nonnull info))block {
    [NSObject.kc_hookTool kc_hookWithObjc:[UIViewController class]
                                 selector:@selector(initWithNibName:bundle:)
                              withOptions:KcAspectTypeAfter
                               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"init" format:@"viewController: %@", info.instance];
        if (block) {
            block(info);
        }
    } error:nil];
}

#pragma mark - add、remove

/// 添加移除viewController
+ (void)kc_hook_addRemoveViewController {
    
    /*
     - (void)addChildViewController:(UIViewController *)childController API_AVAILABLE(ios(5.0));

     - (void)removeFromParentViewController
     */
    [self.kc_hookTool kc_hookWithObjc:[UIViewController class]
                             selector:@selector(addChildViewController:)
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"addChildViewController" format:@"%@", info.arguments.firstObject];
    } error:nil];
    
    [self.kc_hookTool kc_hookWithObjc:[UIViewController class]
                             selector:@selector(removeFromParentViewController)
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"removeFromParentViewController" format:@"%@", info.instance];
    } error:nil];
}

#pragma mark - tabbar

/// 检查tabbar的问题
+ (void)kc_hook_checkTabbar {
    [NSObject.kc_hookTool kc_hookWithObjc:UIView.class selector:@selector(setAlpha:) withOptions:KcAspectTypeAfter usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        UIView *_Nullable view = info.instance;

        if (view == nil || [view isEqual:[NSNull null]] || ![view isKindOfClass:[UITabBar class]]) {
            return;
        }

        float alpha = [info.arguments.firstObject floatValue];

        [KcLogParamModel logWithKey:@"tabbar" format:@"%@, alpha: %f", info.instance, alpha];
    } error:nil];
        
    [NSObject.kc_hookTool kc_hookWithObjc:UIView.class selector:@selector(setHidden:) withOptions:KcAspectTypeAfter usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        UIView *_Nullable view = info.instance;

        if (view == nil || [view isEqual:[NSNull null]] || ![view isKindOfClass:[UITabBar class]]) {
            return;
        }
        
        BOOL hidden = [info.arguments.firstObject boolValue];
        
        [KcLogParamModel logWithKey:@"tabbar" format:@"%@, hidden: %d", info.instance, hidden];
    } error:nil];
    
    [NSObject.kc_hookTool kc_hookWithObjc:UIViewController.class selector:@selector(setHidesBottomBarWhenPushed:) withOptions:KcAspectTypeAfter usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        UIView *_Nullable view = info.instance;

        if (view == nil || [view isEqual:[NSNull null]]) {
            return;
        }
        
        BOOL hidesBottomBarWhenPushed = [info.arguments.firstObject boolValue];
        
//        NSString *className = NSStringFromClass([info.instance class]);
        
        [KcLogParamModel logWithKey:@"tabbar" format:@"%@, hidesBottomBarWhenPushed: %d", info.instance, hidesBottomBarWhenPushed];
    } error:nil];
}

@end

@implementation UIViewController (KcDebugNavigation)

+ (void)kc_hook_navigationController {
    [UIViewController kc_hookSelectorName:NSStringFromSelector(@selector(navigationController))
              swizzleSelectorName:NSStringFromSelector(@selector(__kc_hook_navigationController))];
}

- (UINavigationController *)__kc_hook_navigationController {
    UINavigationController *_Nullable navigationController = [self __kc_hook_navigationController];
    
    if (!navigationController) {
        [KcLogParamModel logWithKey:@"导航栏" format:@"❎❎❎获取导航栏失败 vc: %@", self];
    }
    
    return navigationController;
}

/// 导航栏item
+ (void)kc_hookNavigationBarButtonItem {
    // left item
    
    [self.kc_hookTool kc_hookWithObjc:UINavigationItem.class
                             selector:@selector(setLeftBarButtonItem:)
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"导航栏" format:@"%@", info.selectorName];
    } error:nil];
    
    [self.kc_hookTool kc_hookWithObjc:UINavigationItem.class
                             selector:@selector(setLeftBarButtonItems:)
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"导航栏" format:@"%@", info.selectorName];
    } error:nil];
    
    // right item
    
    [self.kc_hookTool kc_hookWithObjc:UINavigationItem.class
                             selector:@selector(setRightBarButtonItem:)
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"导航栏" format:@"%@", info.selectorName];
    } error:nil];
    
    [self.kc_hookTool kc_hookWithObjc:UINavigationItem.class
                             selector:@selector(setRightBarButtonItems:)
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"导航栏" format:@"%@", info.selectorName];
    } error:nil];
    
    // ---- title
    [self kc_hook_setTitle];
}

+ (void)kc_hook_setTitle {
    [self.kc_hookTool kc_hookWithObjc:UINavigationItem.class
                             selector:@selector(setTitle:)
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"导航栏title" format:@"%@ %@", info.selectorName, info.arguments[0]];
    } error:nil];
    
    [self.kc_hookTool kc_hookWithObjc:UINavigationItem.class
                             selector:@selector(setTitleView:)
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"导航栏title" format:@"%@ %@", info.selectorName, info.arguments[0]];
    } error:nil];
    
    [self.kc_hookTool kc_hookWithObjc:UIViewController.class
                             selector:@selector(setTitle:)
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"导航栏title" format:@"%@ %@", info.selectorName, info.arguments[0]];
    } error:nil];
}

/// 导航栏背景色
+ (void)kc_hook_navigationBarColor {
    [self.kc_hookTool kc_hookWithObjc:UINavigationBar.class
                             selector:@selector(setBarTintColor:)
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"导航栏背景色" format:@"%@ %@", info.selectorName, info.arguments[0]];
    } error:nil];
}

@end
