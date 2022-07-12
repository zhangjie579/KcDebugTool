//
//  KcAutoLayoutCheck.m
//  KcDebugTool
//
//  Created by 张杰 on 2022/6/8.
//

#import "KcAutoLayoutCheck.h"
#import "KcHookTool.h"
#import "KcHookModel.h"
#import <objc/message.h>
@import KcDebugSwift;

@interface KcAutoLayoutCheck ()

@end

@implementation KcAutoLayoutCheck

/// 检查丢失水平约束的UIView子类
+ (void)checkMixHorizontalMaxLayoutWithWhiteClass:(NSSet<Class> *)whiteClasses blackClasses:(nullable NSSet<Class> *)blackClasses {
    KcHookTool *hook = [[KcHookTool alloc] init];
    
    [hook kc_hookWithObjc:UIView.class selector:@selector(layoutSubviews) withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        
        
        
        Class cls = [info.instance class];
        if ([blackClasses containsObject:cls]
            || ![whiteClasses containsObject:cls]
            || ![self checkMissMaxLayoutWithView:info.instance forAxis:UILayoutConstraintAxisHorizontal]) {
            return;
        }
        
        KcPropertyResult *property = [KcFindPropertyTooler findResponderChainObjcPropertyNameWithObject:info.instance startSearchView:nil isLog:false];
        [KcLogParamModel logWithKey:@"constraint - 缺少水平最大约束⚠️" format:@"%@", property.debugLog];
        
    } error:nil];
}

/// 检查view层级丢失 <= 的约束
/// @param axis 检查是水平还是竖直方向
/// @param classType 检查的class类型
+ (nullable NSMutableArray<KcPropertyResult *> *)missMaxConstraintViewHierarchyWithView:(__kindof UIView *)view forAxis:(UILayoutConstraintAxis)axis classType:(Class)classType {
    NSMutableArray<UIView *> *troubleViews = [[NSMutableArray alloc] init];
    [self missMaxConstraintViewHierarchyWithView:view forAxis:axis classType:classType troubleView:troubleViews];
    
    if (troubleViews.count <= 0) {
        return nil;
    }
    
    NSMutableArray<KcPropertyResult *> *propertys = [[NSMutableArray alloc] init];
    
    for (UIView *view in troubleViews) {
        KcPropertyResult *property = [KcFindPropertyTooler findResponderChainObjcPropertyNameWithObject:view startSearchView:nil isLog:false];
        if (property) {
            [propertys addObject:property];
        }
    }
    
    return propertys;
}

+ (void)missMaxConstraintViewHierarchyWithView:(__kindof UIView *)view forAxis:(UILayoutConstraintAxis)axis classType:(Class)classType troubleView:(NSMutableArray<UIView *> *)troubleView {
    // 处理子类
    void (^didSubviewsBlock)(NSArray<UIView *> *subviews) = ^(NSArray<UIView *> *subviews) {
        for (UIView *subview in subviews) {
            [self missMaxConstraintViewHierarchyWithView:subview forAxis:axis classType:classType troubleView:troubleView];
        }
    };
    
    if ([view isKindOfClass:[UITableView class]] || [view isKindOfClass:[UICollectionView class]]) {
        NSMutableSet<Class> *set = [[NSMutableSet alloc] init];
        for (id cell in [(id)view visibleCells]) {
            if (![set containsObject:[cell class]]) {
                [set addObject:[cell class]];
                [self missMaxConstraintViewHierarchyWithView:[cell contentView] forAxis:axis classType:classType troubleView:troubleView];
            }
        }
    } else if ([view isKindOfClass:[UITableViewCell class]] || [view isKindOfClass:[UICollectionViewCell class]]) {
        [self missMaxConstraintViewHierarchyWithView:[(id)view contentView] forAxis:axis classType:classType troubleView:troubleView];
    } else if ([view isKindOfClass:[UIStackView class]]) {
        UIStackView *stackView = (UIStackView *)view;
        didSubviewsBlock(stackView.arrangedSubviews);
    } else {
        if ([view isKindOfClass:classType]) {
            if ([KcAutoLayoutCheck checkMissMaxLayoutWithView:view forAxis:axis]) {
                [troubleView addObject:view];
            }
        }
        
        didSubviewsBlock(view.subviews);
    }
}


#pragma mark - 检查约束丢失的IMP

/// 检查丢失最大约束的IMP
static BOOL(^gCheckMissMaxLayoutIMP)(UIView *, UILayoutConstraintAxis);

/// 设置丢失最大约束的函数指针
+ (void)setCheckMissMaxLayout:(BOOL(^)(UIView *, UILayoutConstraintAxis))block {
    if (!block) {
        return;
    }
    
    gCheckMissMaxLayoutIMP = block;
}

/* view是否有最多尺寸约束的限制, 以水平方向作为说明 (仅作为参考, 不能完全保证正确性)
 1.自定义设置了width ✅
 2.left、width、right 只要自定义设置了2个, 就算有. width必须不是固有尺寸 ✅
 3.有NSLayoutRelationLessThanOrEqual基本上就算有
 */
+ (BOOL)checkMissMaxLayoutWithView:(__kindof UIView *)view forAxis:(UILayoutConstraintAxis)axis {
    // 这个拿到的是view的有效约束, constraints不一定能拿到view的全部约束, 可能有些约束加在了superview上面, 比如可以看masonry install代码
    // 这种分不出哪些是系统添加的约束, 哪些是自己添加的约束❓其实如果都是通过masonry来添加约束的话, 直接判断masonry存储的约束中, 水平/竖直方向上有没有添加相应的约束即可
    // 而且constraintsAffectingLayoutForAxis对于stackView本身添加的约束, 处理起来太复杂了
//        NSArray<__kindof NSLayoutConstraint *> *constraints = [view constraintsAffectingLayoutForAxis:axis];

//        CGSize intrinsicContentSize = view.intrinsicContentSize;
//        NSLayoutAttribute firstAttribute = axis == UILayoutConstraintAxisHorizontal ? NSLayoutAttributeWidth : NSLayoutAttributeHeight;
//        CGFloat constant = axis == UILayoutConstraintAxisHorizontal ? intrinsicContentSize.width : intrinsicContentSize.height;
    
//        switch (axis) {
//            case UILayoutConstraintAxisHorizontal: {
//                BOOL hasLessThanOrEqual = true;
//                for (NSLayoutConstraint *constraint in constraints) {
//                    if (constraint.relation == NSLayoutRelationLessThanOrEqual) {
//                        hasLessThanOrEqual = false;
//                        break;
//                    } else if (constraint.relation == NSLayoutRelationEqual && constraint.constant == intrinsicContentSize.width && constraint.firstAttribute == NSLayoutAttributeWidth) {
//
//                    }
//                }
//                return hasLessThanOrEqual;
//            }
//                break;
//            case UILayoutConstraintAxisVertical: {
//
//            }
//                break;
//        }
    
//        BOOL hasLessThanOrEqual = true;
    
//        BOOL isCustomSetSize = true; // 是否自定义设置的size, 系统设置的固有尺寸不能作为max layout
//
//        BOOL hasLeftConstraint = false;
//        BOOL hasRightConstraint = false;
//
//        for (NSLayoutConstraint *constraint in constraints) {
//            // 这种情况大概率是有最大的尺寸约束
//            if (constraint.relation == NSLayoutRelationLessThanOrEqual) {
////                hasLessThanOrEqual = false;
////                break;
//                return true;
//            }
//
//            if (constraint.firstAttribute == firstAttribute && constraint.relation == NSLayoutRelationEqual && constraint.constant == constant) { // 大概率是系统设置的size
//                isCustomSetSize = false; continue;
//            }
//
//            switch (axis) {
//                case UILayoutConstraintAxisHorizontal: {
//                    if (constraint.firstAttribute == NSLayoutAttributeLeading || constraint.firstAttribute == NSLayoutAttributeLeft) {
//                        hasLeftConstraint = true;
//                    } else if (constraint.firstAttribute == NSLayoutAttributeTrailing || constraint.firstAttribute == NSLayoutAttributeRight) {
//                        hasRightConstraint = true;
//                    }
//                }
//                    break;
//
//                case UILayoutConstraintAxisVertical: {
//                    if (constraint.firstAttribute == NSLayoutAttributeTop) {
//                        hasLeftConstraint = true;
//                    } else if (constraint.firstAttribute == NSLayoutAttributeBottom) {
//                        hasRightConstraint = true;
//                    }
//                }
//                    break;
//            }
//        }
//
//        if (isCustomSetSize) {
//            return true;
//        }
//
//        if (hasLeftConstraint && hasRightConstraint) {
//            return true;
//        }
//
//        return false;
    
    // 这里是自定义了snapKit, 里面添加的方法
    if (!gCheckMissMaxLayoutIMP) {
        Class cls = NSClassFromString(@"KcConstraintCheck");
        SEL selector = NSSelectorFromString(@"missMaxConstraintWithView:for:");
        IMP imp = class_getMethodImplementation(object_getClass(cls), selector);
        
        if (!imp) {
            [KcLogParamModel logWithKey:@"自动布局❌" format:@"%@", @"需要注入检测方法, 或者替换SnapKit库"];
            return false;
        }
        
        BOOL(*point)(Class, SEL, UIView *, UILayoutConstraintAxis) = (void *)imp;
        
        BOOL(^block)(UIView *view, UILayoutConstraintAxis axis) = [^BOOL(UIView *view, UILayoutConstraintAxis axis){
            return point(cls, selector, view, axis);
        } copy];
        
        [self setCheckMissMaxLayout:block];
    }
    
    return gCheckMissMaxLayoutIMP(view, axis);
}

@end
