//
//  NSObject+KcMethodExtension.m
//  OCTest
//
//  Created by samzjzhang on 2020/7/21.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "NSObject+KcMethodExtension.h"
#import "UIView+KcDebugTool.h"
@import KcDebugSwift;

@implementation NSObject (KcMethodExtension)

+ (void)kc_hook_instanceMethodListWithInfo:(KcHookInfo *)info usingBlock:(void(^)(KcHookAspectInfo *info))block {
    [self kc_hook_instanceMethodListWithObjc:self info:info usingBlock:block];
}

+ (void)kc_hook_instanceMethodListWithObjc:(id)objc info:(KcHookInfo *)info usingBlock:(void(^)(KcHookAspectInfo *info))block {
    NSArray<NSString *> *instanceMethods = [objc kc_instanceMethodListWithInfo:info.methodInfo];
    if (instanceMethods.count <= 0) {
        return;
    }
    
    id<KcAspectable> manager = KcHookTool.manager;
    [instanceMethods enumerateObjectsUsingBlock:^(NSString * _Nonnull selectorName, NSUInteger idx, BOOL * _Nonnull stop) {
        [manager kc_hookWithObjc:objc selector:NSSelectorFromString(selectorName) withOptions:KcAspectTypeAfter usingBlock:^(KcHookAspectInfo * _Nonnull hookInfo) {
            [info.logModel defaultLogWithInfo:hookInfo];
            if (block) {
                block(hookInfo);
            }
        } error:nil];
    }];
}

/// hook 多个class的方法
+ (void)kc_hook_selectorName:(NSString *)selectorName
                 classNames:(NSArray<NSString *> *)classNames
                      block:(void(^)(KcHookAspectInfo *info))block {
    [self kc_hook_selector:NSSelectorFromString(selectorName) classNames:classNames block:block];
}

/// hook 多个class的方法
+ (void)kc_hook_selector:(SEL)selector
             classNames:(NSArray<NSString *> *)classNames
                  block:(void(^)(KcHookAspectInfo *info))block {
    id<KcAspectable> manager = KcHookTool.manager;
    [classNames enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [manager kc_hookWithObjc:NSClassFromString(obj)
                        selector:selector
                     withOptions:KcAspectTypeBefore
                      usingBlock:^(KcHookAspectInfo *info) {
            [KcLogParamModel logWithString:[NSString stringWithFormat:@"%@.%@", info.className, info.selectorName]];
            if (block) {
                block(info);
            }
        } error:nil];
    }];
}

#pragma mark - 属性

/// 监听属性的set
+ (void)kc_hook_classSetPropertys:(NSArray<NSString *> *)propertyNames
                       className:(NSString *)className
                           block:(void(^)(KcHookAspectInfo *info))block {
    [propertyNames enumerateObjectsUsingBlock:^(NSString * _Nonnull name, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *setSelectorName = [NSString stringWithFormat:@"set%@%@:", [name substringToIndex:1].uppercaseString, [name substringFromIndex:1]];
        [self.kc_hookTool kc_hookWithObjc:NSClassFromString(className)
                                 selector:NSSelectorFromString(setSelectorName)
                              withOptions:KcAspectTypeBefore
                               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
            [KcLogParamModel logWithString:[NSString stringWithFormat:@" [%@ %@] value: %@", info.class, info.selectorName, info.arguments.firstObject]];
            if (block) {
                block(info);
            }
        } error:nil];
    }];
}

+ (KcHookTool *)kc_hookTool {
    return [[KcHookTool alloc] init];
}

@end

#pragma mark - 事件

@implementation NSObject (KcDebugAction)

// -------------  UIControl

/// hook UIControl sendAction:to:forEvent:
+ (void)kc_hook_sendActionForEventWithBlock:(void(^)(KcHookAspectInfo *info))block {
    [self.kc_hookTool kc_hookWithObjc:[UIControl class]
                             selector:@selector(sendAction:to:forEvent:)
                          withOptions:KcAspectTypeAfter
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [self kc_handleLogSendActionWithInfo:info];
        if (block) {
            block(info);
        }
    } error:nil];
}

/// hook UIApplication sendAction:to:from:forEvent:
+ (void)kc_hook_UIApplicationSendActionWithBlock:(void(^)(KcHookAspectInfo *info))block {
    [self.kc_hookTool kc_hookWithObjc:[UIApplication class]
                             selector:@selector(sendAction:to:from:forEvent:)
                          withOptions:KcAspectTypeAfter
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [self kc_handleLogSendActionWithInfo:info];
        if (block) {
            block(info);
        }
    } error:nil];
}

/// hook -[UIApplication sendEvent:]
/// 缺点: 不知道这个event会传给谁处理
+ (void)kc_hook_UIApplicationSendEventWithBlock:(void(^)(KcHookAspectInfo *info))block {
    [self.kc_hookTool kc_hookWithObjc:[UIApplication class]
                             selector:@selector(sendEvent:)
                          withOptions:KcAspectTypeAfter
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [self kc_handleLogSendActionWithInfo:info];
        if (block) {
            block(info);
        }
    } error:nil];
}

///// hook UIControl addTarget:action: 然后再 hook target的action
//+ (void)kc_hookTargetActionWithBlock:(void(^)(KcHookAspectInfo *info))block {
//    [self.kc_hookTool kc_hookWithObjc:[UIControl class] selector:@selector(addTarget:action:) withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
//        id target = info.arguments.firstObject;
//        id action = info.arguments.count >= 2 ? info.arguments[1] : nil;
//
//        if (!target || !action) {
//            return;
//        }
//
//        [self.kc_hookTool kc_hookWithObjc:target selectorName:action withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
//            [KcLogParamModel logWithString:[NSString stringWithFormat:@" addTarget: %@, action: %@", info.instance, info.selectorName]];
//
//            if (block) {
//                block(info);
//            }
//        }];
//    } error:nil];
//}

// -------- UIGestureRecognizer

/* UIGestureRecognizer 事件调用方法 (系统把方法隐藏了, hook 无效⚠️, 符号断点有用)
__CFRunLoopDoSource0
-[UIApplication sendEvent:]
-[UIWindow sendEvent:]
-[UIGestureRecognizer _updateGestureForActiveEvents]:
_UIGestureRecognizerSendActions
_UIGestureRecognizerSendTargetActions
-[UIGestureRecognizerTarget _sendActionWithGestureRecognizer:]
*/
+ (void)kc_hook_gestureRecognizerSendActionWithBlock:(void(^)(KcHookAspectInfo *info))block {
    [self.kc_hookTool kc_hookWithObjc:NSClassFromString(@"UIGestureRecognizerTarget")
                             selector:NSSelectorFromString(@"_sendActionWithGestureRecognizer:")
                          withOptions:KcAspectTypeAfter
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
//        id instance = info.instance; // (action=switchToDefaultKeyBoard, target=<KcTestView 0x7ffc6540f710>)
        id target = info.arguments.firstObject; // <UITapGestureRecognizer: 0x7ffc6540fa00; state = Ended; view = <UILabel 0x7ffc65406ed0>; target= <(action=switchToDefaultKeyBoard, target=<KcTestView 0x7ffc6540f710>)>>
        if ([target isKindOfClass:UIGestureRecognizer.class]) {
            UIGestureRecognizer *recognizer = (UIGestureRecognizer *)target;
            UIView *targetView = recognizer.view;
            
            UIViewController *vc = [targetView kc_superViewController];
            
            [KcLogParamModel logWithKey:@"gesture sendAction 👻👻👻" format:@"【%@ 😁】 targetView: %@, %@, delegate: %@", target, targetView, vc, recognizer.delegate];
        } else {
            [KcLogParamModel logWithKey:@"gesture sendAction 👻👻👻" format:@"%@", target];
        }
        
        if (block) {
            block(info);
        }
    } error:nil];
}

/// hook UIGestureRecognizer的addTarget、initWithTarget方式的event
+ (void)kc_hook_gestureRecognizerAllTargetActionWithBlock:(void(^)(KcHookAspectInfo *info))block {
    [self kc_hook_gestureRecognizerAddTargetActionWithBlock:block];
    [self kc_hook_gestureRecognizerInitTargetActionWithBlock:block];
}

/// hook UIGestureRecognizer的addTarget方式的event
+ (void)kc_hook_gestureRecognizerAddTargetActionWithBlock:(void(^)(KcHookAspectInfo *info))block {
    [self.kc_hookTool kc_hookWithObjc:[UIGestureRecognizer class]
                             selector:@selector(addTarget:action:)
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [self __kc_hook_gestureRecognizerTargetActionWithInfo:info];
    } error:nil];
}

/// hook UIGestureRecognizer的initWithTarget方式的event
+ (void)kc_hook_gestureRecognizerInitTargetActionWithBlock:(void(^)(KcHookAspectInfo *info))block {
    /*
     1.UIGestureRecognizer - _targets: [UIGestureRecognizerTarget]
     2.UIGestureRecognizerTarget
        * SEL action;
        * id target;
     */
    [self.kc_hookTool kc_hookWithObjc:[UIGestureRecognizer class]
                             selector:@selector(initWithTarget:action:)
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [self __kc_hook_gestureRecognizerTargetActionWithInfo:info];
    } error:nil];
}

/// hook gesture的target action
+ (void)__kc_hook_gestureRecognizerTargetActionWithInfo:(KcHookAspectInfo *)info {
    id target = info.arguments.firstObject;
    id action = info.arguments.count >= 2 ? info.arguments[1] : nil;
    
    __weak typeof(info.instance) weakInstance = info.instance;
    [self kc_hook_customClassWithTarget:target
                                 action:action
                            logIdentity:@"UIGestureRecognizer"
                                  block:^(KcHookAspectInfo *subInfo) {
        __strong typeof(weakInstance) objc = weakInstance;
        if ([objc isKindOfClass:[UIGestureRecognizer class]]) {
            UIGestureRecognizer *gesture = (UIGestureRecognizer *)objc;
            UIView *view = gesture.view;
            
            // 因为对于rx这种用于block保证的, 知道target/action也没用
            KcPropertyResult *property = [KcFindPropertyTooler findResponderChainObjcPropertyNameWithObject:view startSearchView:nil isLog:false];
            if (property) {
                NSString *desc = [NSString stringWithFormat:@"[%@, 响应事件对象: %@]", property.debugLog, [KcLogParamModel instanceDesc:view]];
                
                [KcLogParamModel logWithKey:@"UIGestureRecognizer"
                                     format:@"target: %@, action: %@, %@", subInfo.className, subInfo.selectorName, desc];
                
                return;
            }
        }
        
        [KcLogParamModel logWithKey:@"UIGestureRecognizer"
                             format:@"target: %@, action: %@", subInfo.className, subInfo.selectorName];
    }];
}

/// hook UIGestureRecognizer enable
+ (void)kc_hook_gestureRecognizerEnableWithBlock:(void(^)(KcHookAspectInfo *info))block {
    [self.kc_hookTool kc_hookWithObjc:UIGestureRecognizer.class
                             selector:@selector(setEnabled:)
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"UIGestureRecognizer.enable"
                             format:@"%@ enable: %@", info.instance, info.arguments[0]];
        if (block) {
            block(info);
        }
    } error:nil];
}

/// hook 自定义方法的target/action
+ (void)kc_hook_customClassWithTarget:(id)target
                              action:(id)action
                         logIdentity:(NSString *)logIdentity
                               block:(void(^)(KcHookAspectInfo *info))block {
    if (!target || !action || [target isEqual:[NSNull null]] || ![action isKindOfClass:[NSString class]]) {
        return;
    }

    Class targetCls = [target class];
    if (![NSObject kc_isCustomClass:targetCls]) {
        return;
    }

    // 比如: 如果是通过Rx的方式添加的gesture处理, 对应的target、action是rx通用的, 不是想要的, 只能通过堆栈来查看⚠️
    [self.kc_hookTool kc_hookWithObjc:target
                         selectorName:action
                          withOptions:KcAspectTypeAfter
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        if (block) {
            block(info);
        } else {
            [KcLogParamModel logWithKey:logIdentity
                                 format:@"target: %@, action: %@", info.className, info.selectorName];
        }
    }];
}

/*
-[NSNotificationCenter postNotificationName:object:userInfo:]
_CFXNotificationPost ()
CoreFoundation -[_CFXNotificationRegistrar find:object:observer:enumerator:]
___CFXNotificationPost_block_invoke ()
_CFXRegistrationPost1
__CFNOTIFICATIONCENTER_IS_CALLING_OUT_TO_AN_OBSERVER__
*/
+ (void)kc_hook_notificationNameWithFilterBlock:(BOOL(^)(NSString *name))filterBlock
                                         block:(void(^ _Nullable)(KcHookAspectInfo *info))block {
    [self.kc_hookTool kc_hookWithObjc:NSNotificationCenter.class
                         selectorName:@"addObserver:selector:name:object:"
                          withOptions:KcAspectTypeBefore
                           usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        if (info.arguments.count < 2) {
            return;
        }
        NSObject *observer = info.arguments[0];
        SEL selector = NSSelectorFromString(info.arguments[1]);
        NSString *name = info.arguments[2];
        if (!observer || !selector) {
            return;
        }
        
        if (![NSObject kc_isCustomClass:observer.class]) {
            return;
        }
        
        // 监听具体的name
        if (filterBlock && !filterBlock(name)) {
            return;
        }
        
        [self.kc_hookTool kc_hookWithObjc:observer
                                 selector:selector
                              withOptions:KcAspectTypeBefore
                               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
            [KcLogParamModel logWithKey:@"NSNotificationCenter"
                                 format:@"target: %@, action: %@", info.className, info.selectorName];
            if (block) {
                block(info);
            }
        } error:nil];
    }];
}

// -------------  touch

///// touchesBegan
//+ (void)kc_hookTouchBeginWithBlock:(void(^)(KcHookAspectInfo *info))block {
//    [self.kc_hookTool kc_hookWithObjc:UIResponder.class selector:@selector(touchesBegan:withEvent:) withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
//        [KcLogParamModel logWithString:[NSString stringWithFormat:@" %@ %@ ", info.selectorName, info.instance]];
//    } error:nil];
//}

/// log sendAction
+ (void)kc_handleLogSendActionWithInfo:(KcHookAspectInfo *)info {
    id action = info.arguments.firstObject;
    id target = info.arguments.count >= 2 ? info.arguments[1] : nil;
    id instance = info.instance;
    
    // 那个对象的event
    NSString *instanceDesc = @"";
    if ([instance isKindOfClass:[UIView class]]) {
        KcPropertyResult *result = [KcFindPropertyTooler findResponderChainObjcPropertyNameWithObject:instance startSearchView:nil isLog:false];
        if (result) {
            instanceDesc = [NSString stringWithFormat:@", [%@, 响应事件对象: %@]", result.debugLog, [KcLogParamModel instanceDesc:instance]];
        }
    }
    
    NSString *className = [KcLogParamModel demangleNameWithName:NSStringFromClass([target class])];
    
    // 如果target非自定义class, 不log target
    if ([NSObject kc_isCustomClass:[target class]]) {
        [KcLogParamModel logWithKey:@"sendAction" format:@"class: %@, action: %@, target: %@ %@", className, action, [KcLogParamModel instanceDesc:target], instanceDesc];
    } else {
        [KcLogParamModel logWithKey:@"sendAction" format:@"class: %@, action: %@ %@", className, action, instanceDesc];
    }
}

@end
