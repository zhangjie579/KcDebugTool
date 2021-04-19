//
//  UIView+KcDebugTool.m
//  OCTest
//
//  Created by samzjzhang on 2020/4/27.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "UIView+KcDebugTool.h"
//#import "NSObject+KcMethodExtension.h"
#import "NSObject+KcRuntimeExtension.h"

@implementation UIView (KcDebugTool)

/// 是否不可见
- (BOOL)kc_unVisibleInHierarchy {
    if (self.hidden || self.alpha == 0) {
        return YES;
    }
    
    if ([self isKindOfClass:[UIWindow class]])
        return NO;

    if (!self.window)
        return YES;

    return [self.superview kc_unVisibleInHierarchy];
}

/// 所属viewController
- (nullable UIViewController *)kc_superViewController {
    id responder = self.nextResponder;
    while (responder) {
        if ([responder isKindOfClass: [UIViewController class]] || [responder isKindOfClass: [UIWindow class]]) {
            return responder;
        }
        responder = [responder nextResponder];
    }
    
    if ([responder isKindOfClass: [UIViewController class]]) {
        return responder;
    }
    return nil;
}

/// 找到合适的
- (void)kc_fiterNextResponderWithBlock:(BOOL(^)(UIResponder *responder))block {
    if (!block) {
        return;
    }
    
    UIResponder *responder = self.nextResponder;
    while (responder) {
        [KcLogParamModel logWithKey:@"响应链" format:@"responder: %@", responder];
        BOOL result = block(responder);
        if (result) {
            return;
        }
        responder = responder.nextResponder;
    }
}

/// 遍历响应链
- (void)kc_forEachResponderChain {
    UIResponder *responder = self.nextResponder;
    while (responder) {
        [KcLogParamModel logWithKey:@"响应链" format:@"responder: %@", responder];
        responder = responder.nextResponder;
    }
}

#pragma mark - hook

/// 添加view (也可以重写didAddSubview方法)
+ (void)kc_hook_addSubview {
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    [tool kc_hookWithObjc:UIView.class
                 selector:@selector(addSubview:)
              withOptions:KcAspectTypeAfter
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        UIView *subView = info.arguments[0];
        [KcLogParamModel logWithKey:info.selectorName format:@"self: %@, subView: %@", info.instance, subView];
    } error:nil];
}

/// 移除
+ (void)kc_hook_removeFromSuperview {
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    [tool kc_hookWithObjc:UIView.class
                 selector:@selector(removeFromSuperview)
              withOptions:KcAspectTypeAfter
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:info.selectorName format:@"self: %@, superview: %@", info.instance, [info.instance superview]];
    } error:nil];
}

/// 第一响应值相关
+ (void)kc_hook_firstResponder {
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    [tool kc_hookWithObjc:UIResponder.class
                 selector:@selector(becomeFirstResponder)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"第一响应值" format:@"%@, %@", info.selectorName, info.instance];
    } error:nil];
    
    [tool kc_hookWithObjc:UIResponder.class
                 selector:@selector(resignFirstResponder)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"第一响应值" format:@"%@, %@", info.selectorName, info.instance];
    } error:nil];
    
    [tool kc_hookWithObjc:UIView.class
                 selector:@selector(endEditing:)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"第一响应值" format:@"%@, self: %@, subviews: %@", info.selectorName, info.instance, [info.instance subviews]];
    } error:nil];
}

/// hook view init
+ (void)kc_hook_initWithViewClassNames:(NSSet<NSString *> *)classNames {
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    [tool kc_hookWithObjc:[UIView class]
                 selector:@selector(initWithFrame:)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        if (![info.instance kc_isClassOrSubClass:classNames]) {
            return;
        }
        [KcLogParamModel logWithKey:@"init" format:@"view: %@", info.instance];
    } error:nil];
}

/// 背景色
+ (void)kc_hook_backgroundColor {
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    [tool kc_hookWithObjc:UIView.class
                 selector:@selector(setBackgroundColor:)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"backgroundColor" format:@"%@, %@", info.instance, info.arguments.firstObject ?: @""];
    } error:nil];
}

@end
