//
//  KcAutoLayoutCheck.h
//  KcDebugTool
//
//  Created by 张杰 on 2022/6/8.
//  自动布局检测

#import <UIKit/UIKit.h>
@class KcPropertyResult;

NS_ASSUME_NONNULL_BEGIN

/// 自动布局检测
@interface KcAutoLayoutCheck : NSObject

/// 检查丢失水平约束的UIView子类
/// 检查丢失水平约束的UIView子类
+ (void)checkMixHorizontalMaxLayoutWithWhiteClass:(NSSet<Class> *)whiteClasses
                                     blackClasses:(nullable NSSet<Class> *)blackClasses
                                blackSuperClasses:(nullable NSSet<Class> *)blackSuperClasses;

/// 检查view层级丢失 <= 的约束
/// @param axis 检查是水平还是竖直方向
/// @param classType 检查的class类型
+ (nullable NSMutableArray<KcPropertyResult *> *)missMaxConstraintViewHierarchyWithView:(__kindof UIView *)view forAxis:(UILayoutConstraintAxis)axis classType:(Class)classType;

/// 检查translatesAutoresizingMaskIntoConstraints的值
+ (void)checkTranslatesAutoresizingMaskIntoConstraints;

#pragma mark - 检查约束丢失的IMP

/// 设置丢失最大约束的函数指针(外部提供实现)
+ (void)setCheckMissMaxLayout:(BOOL(^)(UIView *, UILayoutConstraintAxis))imp;

/* view是否有最多尺寸约束的限制, 以水平方向作为说明 (仅作为参考, 不能完全保证正确性)
 1.自定义设置了width ✅
 2.left、width、right 只要自定义设置了2个, 就算有. width必须不是固有尺寸 ✅
 3.有NSLayoutRelationLessThanOrEqual基本上就算有
 */
+ (BOOL)checkMissMaxLayoutWithView:(__kindof UIView *)view forAxis:(UILayoutConstraintAxis)axis;

#pragma mark - 异常check

/// check 异常
+ (void)checkException;

@end

NS_ASSUME_NONNULL_END
