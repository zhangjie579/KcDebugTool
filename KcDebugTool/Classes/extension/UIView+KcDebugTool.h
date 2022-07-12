//
//  UIView+KcDebugTool.h
//  OCTest
//
//  Created by samzjzhang on 2020/4/27.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "KcHookTool.h"
#import "KcHookModel.h"
@class KcPropertyResult;

NS_ASSUME_NONNULL_BEGIN

@interface UIView (KcDebugTool)

/// 是否不可见
- (BOOL)kc_unVisibleInHierarchy;

/// 所属viewController
- (nullable UIViewController *)kc_superViewController;

/// 遍历响应链
- (void)kc_forEachResponderChain;

#pragma mark - hook

/// 添加view
+ (void)kc_hook_addSubview;

/// 移除
+ (void)kc_hook_removeFromSuperview;

/// 第一响应值相关
+ (void)kc_hook_firstResponder;

/// hook view init
+ (void)kc_hook_initWithViewClassNames:(NSSet<NSString *> *)classNames;

/// 背景色
+ (void)kc_hook_backgroundColor;

#pragma mark - 约束相关

/// log view层级下丢失lessThanOrEqual约束labels
- (nullable NSString *)kc_log_missMaxHorizontalConstraintViewHierarchyForLabel;

/// log view层级下丢失lessThanOrEqual约束的classType类型的view
- (nullable NSString *)kc_log_missMaxHorizontalConstraintViewHierarchyWithClassType:(Class)classType;

#pragma mark - 属性

/// 查找属性信息
- (nullable KcPropertyResult *)propertyInfoWithIsLog:(BOOL)isLog;

@end

NS_ASSUME_NONNULL_END
