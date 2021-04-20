//
//  NSObject+KcMethodExtension.h
//  OCTest
//
//  Created by samzjzhang on 2020/7/21.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "KcHookModel.h"
#import "KcHookTool.h"
#import "NSObject+KcRuntimeExtension.h"

NS_ASSUME_NONNULL_BEGIN

@interface NSObject (KcMethodExtension)

+ (void)kc_hook_instanceMethodListWithInfo:(KcHookInfo *)info
                               usingBlock:(void(^)(KcHookAspectInfo *info))block;

/// hook class 所有对象方法
+ (void)kc_hook_instanceMethodListWithObjc:(id)objc
                                     info:(KcHookInfo *)info
                               usingBlock:(void(^)(KcHookAspectInfo *info))block;

/// hook 多个class的方法
+ (void)kc_hook_selectorName:(NSString *)selectorName
                 classNames:(NSArray<NSString *> *)classNames
                      block:(void(^)(KcHookAspectInfo *info))block;

+ (void)kc_hook_selector:(SEL)selector
              classNames:(NSArray<NSString *> *)classNames
                   block:(void(^)(KcHookAspectInfo *info))block;

#pragma mark - 属性

/// 监听属性的set
+ (void)kc_hook_classSetPropertys:(NSArray<NSString *> *)propertyNames
                       className:(NSString *)className
                           block:(void(^)(KcHookAspectInfo *info))block;

+ (KcHookTool *)kc_hookTool;

@end

#pragma mark - 事件

@interface NSObject (KcDebugAction)

/// hook UIControl sendAction:to:forEvent:
+ (void)kc_hook_sendActionForEventWithBlock:(void(^)(KcHookAspectInfo *info))block;

/// hook UIApplication sendAction:to:from:forEvent:
+ (void)kc_hook_UIApplicationSendActionWithBlock:(void(^)(KcHookAspectInfo *info))block;

/// hook -[UIApplication sendEvent:]
+ (void)kc_hook_UIApplicationSendEventWithBlock:(void(^)(KcHookAspectInfo *info))block;


///// hook UIControl addTarget:action: 然后再 hook target的action
//+ (void)kc_hookTargetActionWithBlock:(void(^)(KcHookAspectInfo *info))block;

// -------- UIGestureRecognizer

/// UIGestureRecognizer 事件调用方法
+ (void)kc_hook_gestureRecognizerSendActionWithBlock:(void(^)(KcHookAspectInfo *info))block;

/// hook UIGestureRecognizer的addTarget、initWithTarget方式的event
+ (void)kc_hook_gestureRecognizerAllTargetActionWithBlock:(void(^)(KcHookAspectInfo *info))block;
/// hook UIGestureRecognizer的addTarget方式的event
+ (void)kc_hook_gestureRecognizerAddTargetActionWithBlock:(void(^)(KcHookAspectInfo *info))block;
/// hook UIGestureRecognizer的initWithTarget方式的event
+ (void)kc_hook_gestureRecognizerInitTargetActionWithBlock:(void(^)(KcHookAspectInfo *info))block;

/// hook UIGestureRecognizer enable
+ (void)kc_hook_gestureRecognizerEnableWithBlock:(void(^)(KcHookAspectInfo *info))block;

// -------- 通知Notification

+ (void)kc_hook_notificationNameWithFilterBlock:(BOOL(^)(NSString *name))filterBlock
                                         block:(void(^ _Nullable)(KcHookAspectInfo *info))block;

#pragma mark - tableView

/// hook tableView delegate
+ (void)kc_hook_tableView_delegate;

/// hook collectionView delegate
+ (void)kc_hook_collectionView_delegate;

@end

NS_ASSUME_NONNULL_END
