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

+ (void)kc_hookInstanceMethodListWithInfo:(KcHookInfo *)info
                               usingBlock:(void(^)(KcHookAspectInfo *info))block;

/// hook class 所有对象方法
+ (void)kc_hookInstanceMethodListWithObjc:(id)objc
                                     info:(KcHookInfo *)info
                               usingBlock:(void(^)(KcHookAspectInfo *info))block;

/// hook 多个class的方法
+ (void)kc_hookSelectorName:(NSString *)selectorName
                 classNames:(NSArray<NSString *> *)classNames
                      block:(void(^)(KcHookAspectInfo *info))block;

+ (void)kc_hookSelector:(SEL)selector
             classNames:(NSArray<NSString *> *)classNames
                  block:(void(^)(KcHookAspectInfo *info))block;

#pragma mark - 属性

/// 监听属性的set
+ (void)kc_hookClassSetPropertys:(NSArray<NSString *> *)propertyNames
                       className:(NSString *)className
                           block:(void(^)(KcHookAspectInfo *info))block;

+ (KcHookTool *)kc_hookTool;

@end

#pragma mark - 事件

@interface NSObject (KcDebugAction)

/// hook UIControl sendAction:to:forEvent:
+ (void)kc_hookSendActionForEventWithBlock:(void(^)(KcHookAspectInfo *info))block;

/// hook UIApplication sendAction:to:from:forEvent:
+ (void)kc_hookUIApplicationSendActionWithBlock:(void(^)(KcHookAspectInfo *info))block;

/// hook -[UIApplication sendEvent:]
+ (void)kc_hookUIApplicationSendEventWithBlock:(void(^)(KcHookAspectInfo *info))block;


///// hook UIControl addTarget:action: 然后再 hook target的action
//+ (void)kc_hookTargetActionWithBlock:(void(^)(KcHookAspectInfo *info))block;

// -------- UIGestureRecognizer

/// UIGestureRecognizer 事件调用方法
+ (void)kc_hookGestureRecognizerSendActionWithBlock:(void(^)(KcHookAspectInfo *info))block;

/// hook UIGestureRecognizer的addTarget、initWithTarget方式的event
+ (void)kc_hookGestureRecognizerAllTargetActionWithBlock:(void(^)(KcHookAspectInfo *info))block;
/// hook UIGestureRecognizer的addTarget方式的event
+ (void)kc_hookGestureRecognizerAddTargetActionWithBlock:(void(^)(KcHookAspectInfo *info))block;
/// hook UIGestureRecognizer的initWithTarget方式的event
+ (void)kc_hookGestureRecognizerInitTargetActionWithBlock:(void(^)(KcHookAspectInfo *info))block;

/// hook UIGestureRecognizer enable
+ (void)kc_hook_gestureRecognizerEnableWithBlock:(void(^)(KcHookAspectInfo *info))block;

// -------- 通知Notification

+ (void)kc_hookNotificationNameWithFilterBlock:(BOOL(^)(NSString *name))filterBlock
                                         block:(void(^ _Nullable)(KcHookAspectInfo *info))block;

@end

NS_ASSUME_NONNULL_END
