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

#pragma mark - 查找方法

/// 查找keyPath的值为value的所有祖先
/// - Parameters:
///   - value: keyPath的值
///   - keyPath: keyPath
- (NSArray<id> *)kc_findAncestorViewValue:(id)value keyPath:(NSString *)keyPath;

/// 查找并输出keyPath的值为value的所有祖先
/// - Parameters:
///   - value: keyPath的值
///   - keyPath: keyPath
- (NSString *)kc_log_findAncestorViewValue:(id)value keyPath:(NSString *)keyPath;

/// 查找keyPath的值为value的所有祖先
/// - Parameters:
///   - value: 对应的值
///   - selectorName: 方法名
- (NSArray<id> *)kc_findAncestorViewValue:(id)value selectorName:(NSString *)selectorName;

/// 查找所有祖先keyPath的值
- (NSArray<NSString *> *)kc_findAncestorViewKeyPath:(NSString *)keyPath;

#pragma mark - 颜色

/// 是否亮色
+ (BOOL)kc_isLightColor:(UIColor *)color;

#pragma mark - 检查

/// 不能响应事件的原因
- (BOOL)kc_checkHitTestQuestion;

/// 查找圆角的问题
- (NSMutableArray<NSString *> *)kc_findCornerRadiusQuestion;

/// 检查不可见的原因
- (BOOL)kc_checkInvisibleQuestion;

#pragma mark - hitTest

+ (void)kc_hookHitTest;

@end

NS_ASSUME_NONNULL_END
