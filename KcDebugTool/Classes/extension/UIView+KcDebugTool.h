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

/// 在主线程检查 bounds 中心能否在所属 window 内命中自身或子视图，并输出诊断。
/// YES 仅表示命中检查通过（目标为 UIControl 时还要求 enabled），不保证 action/手势回调。
/// 不检查其他 window 的遮挡；withEvent:nil，依赖真实事件的自定义逻辑需结合实际触摸排查。
- (BOOL)kc_checkHitTestQuestion;

/// 检查指定点，point 使用接收者的局部坐标系；其余约定同 kc_checkHitTestQuestion。
/// NO 表示未命中、目标控件禁用，或无法检查（非主线程、无 window、坐标非有限值）。
- (BOOL)kc_checkHitTestQuestionAtPoint:(CGPoint)point;

/// 查找圆角的问题
- (NSMutableArray<NSString *> *)kc_findCornerRadiusQuestion;

/// 检查自身及祖先的隐藏、透明度、尺寸和裁剪；YES 表示未发现这些导致完全不可见的原因。
- (BOOL)kc_checkInvisibleQuestion;

/// 从自身向上逐层检查视图是否完整落在直接父视图的 bounds 内。
/// 越界的视图会显示红色边框；再次检查且已恢复时移除标记。YES 表示各层均未越界。
- (BOOL)kc_checkOutOfSuperviewBounds;

#pragma mark - hitTest

+ (void)kc_hookHitTest;

@end

NS_ASSUME_NONNULL_END
