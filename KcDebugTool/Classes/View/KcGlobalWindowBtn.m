//
//  KcGlobalWindowBtn.m
//  KcDebugTool
//
//  Created by 张杰 on 2021/4/12.
//

#import "KcGlobalWindowBtn.h"
#import "KcFloatingWindow.h"
#import "KcScrollViewTool.h"
//#import "KcMethodCallStack.h"

@interface KcGlobalWindowBtn ()

/// 权限的window
@property (nonatomic) KcFloatingWindow      *window;
/// 权限管理
@property (nonatomic) UIButton              *btn;

@property (nonatomic) KcScrollViewTool      *scrollTool;

@end

@implementation KcGlobalWindowBtn

/// 添加权限管理入口
- (void)start {
    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    CGRect rect = CGRectMake(screenSize.width - 40, screenSize.height - 200, 30, 30);
    
    UIWindow *keyWindow = self.keyWindow;
    if (keyWindow) {
        self.btn.frame = rect;
        self.scrollTool.view = self.btn;
        [keyWindow addSubview:self.btn];
    } else {
        self.scrollTool.view = self.window;
        self.btn.frame = self.window.bounds;
        [self.window addSubview:self.btn];
        self.window.hidden = NO;
    }
}

/// 移除权限管理入口
- (void)end {
    self.window.hidden = YES;
    self.window = nil;
    [self.btn removeFromSuperview];
}

/// 点击
- (void)btnClick {
    
//    [KcCallStackModel logCallStack];
//    [KcCallStackModel clearCallStack];
    
//    UIViewController *topViewController = self.class.kc_topViewController;
//    if (!topViewController || !topViewController.navigationController) {
//        NSLog(@"没找到topViewController");
//        return;
//    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"kc_test_debug_btn_click" object:nil];
}

- (nullable UIWindow *)keyWindow {
    return UIApplication.sharedApplication.keyWindow ?: UIApplication.sharedApplication.delegate.window;
}

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

- (KcFloatingWindow *)window {
    if (!_window) {
        CGSize screenSize = UIScreen.mainScreen.bounds.size;
        _window = [[KcFloatingWindow alloc] initWithFrame:CGRectMake(screenSize.width - 120, screenSize.height - 120, 30, 30)];
        _window.layer.cornerRadius = 15;
        _window.clipsToBounds = YES;
        _window.alpha = 0.5;
    }
    return _window;
}

- (UIButton *)btn {
    if (!_btn) {
        _btn = [[UIButton alloc] init];
        _btn.backgroundColor = UIColor.orangeColor;
        [_btn setTitle:@"🏹" forState:UIControlStateNormal];
        _btn.titleLabel.textColor = UIColor.redColor;
        _btn.titleLabel.font = [UIFont systemFontOfSize:16];
        [_btn addTarget:self action:@selector(btnClick) forControlEvents:UIControlEventTouchUpInside];
        _btn.layer.cornerRadius = 15;
        _btn.clipsToBounds = true;
    }
    return _btn;
}

- (KcScrollViewTool *)scrollTool {
    if (!_scrollTool) {
        _scrollTool = [[KcScrollViewTool alloc] init];
    }
    return _scrollTool;
}

@end
