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

//@interface NSLayoutConstraint (KcLayoutCheck)
//
//+ (instancetype)kc_hook_constraintWithItem:(id)view1 attribute:(NSLayoutAttribute)attr1 relatedBy:(NSLayoutRelation)relation toItem:(id)view2 attribute:(NSLayoutAttribute)attr2 multiplier:(CGFloat)multiplier constant:(CGFloat)c;
//
//+ (void)kc_addLayoutCheck:(void (^)(id view1, NSLayoutAttribute attr1, NSLayoutRelation relation, id view2, NSLayoutAttribute attr2, CGFloat multiplier, CGFloat constant))layoutCheck;
//
//@end

@interface KcAutoLayoutCheck ()

@end

@implementation KcAutoLayoutCheck

/// 检查丢失水平约束的UIView子类
+ (void)checkMixHorizontalMaxLayoutWithWhiteClass:(NSSet<Class> *)whiteClasses
                                     blackClasses:(nullable NSSet<Class> *)blackClasses
                                blackSuperClasses:(nullable NSSet<Class> *)blackSuperClasses {
    if (![self hasCheckMissMaxLayoutIMP]) {
        [KcLogParamModel logWithKey:@"自动布局❌" format:@"%@", @"需要注入检测方法, 或者替换SnapKit库"];
        return;
    }
    
    KcHookTool *hook = [[KcHookTool alloc] init];
    
    [hook kc_hookWithObjc:UIView.class selector:@selector(layoutSubviews) withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        
        if (!info.instance) {
            return;
        }
        
        Class superClass = [[info.instance superview] class];
        if (superClass && blackSuperClasses && [blackSuperClasses containsObject:superClass]) {
            return;
        }
        
        Class cls = [info.instance class];
        if ((blackClasses && [blackClasses containsObject:cls])
            || ![whiteClasses containsObject:cls]
            || ![self checkMissMaxLayoutWithView:info.instance forAxis:UILayoutConstraintAxisHorizontal]) {
            return;
        }
        
        KcPropertyResult *_Nullable property = [KcFindPropertyTooler findResponderChainObjcPropertyNameWithObject:info.instance startSearchView:nil isLog:false];
        if (property) {
            [KcLogParamModel logWithKey:@"constraint - 缺少水平最大约束⚠️" format:@"%@", property.debugLog];
        }
        
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

/// 检查translatesAutoresizingMaskIntoConstraints的值
+ (void)checkTranslatesAutoresizingMaskIntoConstraints {
//    KcHookTool *hook = [[KcHookTool alloc] init];
//    
//    [hook kc_hookWithObjc:UIView.class selector:@selector(layoutSubviews) withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
//        
//        if (!info.instance || ![info.instance isKindOfClass:[UIView class]]) {
//            return;
//        }
//        
//        UIView *view = info.instance;
//        
//        if (view.constraints.count <= 0) {
//            return;
//        }
//        
//        if (!view.translatesAutoresizingMaskIntoConstraints) {
//            return;
//        }
//        
//        KcPropertyResult *_Nullable property = [KcFindPropertyTooler findResponderChainObjcPropertyNameWithObject:info.instance startSearchView:nil isLog:false];
//        [KcLogParamModel logWithKey:@"constraint - translatesAutoresizingMaskIntoConstraints未设置为false⚠️" format:@"%@", property.debugLog ?: view];
//        
//    } error:nil];
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

/// 是否有check miss max layout的函数指针
+ (BOOL)hasCheckMissMaxLayoutIMP {
    if (gCheckMissMaxLayoutIMP) {
        return true;
    }
    
    Class cls = NSClassFromString(@"KcConstraintCheck");
    SEL selector = NSSelectorFromString(@"missMaxConstraintWithView:for:");
    IMP imp = class_getMethodImplementation(object_getClass(cls), selector);
    
    if (!imp) {
        return false;
    }
    
    BOOL(*point)(Class, SEL, UIView *, UILayoutConstraintAxis) = (void *)imp;
    
    BOOL(^block)(UIView *view, UILayoutConstraintAxis axis) = [^BOOL(UIView *view, UILayoutConstraintAxis axis){
        // 通过这种方式, 就算有left、right约束, 也可能是把super撑起来, 也就是没最大限制的约束
//        NSArray<__kindof NSLayoutConstraint *> *constraints = [view constraintsAffectingLayoutForAxis:axis];
        return point(cls, selector, view, axis);
    } copy];
    
    [self setCheckMissMaxLayout:block];
    
    return true;
}

#pragma mark - 异常check

/// check 异常
+ (void)checkException {
    KcHookTool *hook = [[KcHookTool alloc] init];
    
    // 优先级
    [hook kc_hookWithObjc:NSLayoutConstraint.class selector:@selector(setPriority:) withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        
        NSLayoutConstraint * _Nullable constraint = info.instance;
        
        if (constraint == nil || ![constraint isKindOfClass:[NSLayoutConstraint class]]) {
            return;
        }
        
        UILayoutPriority priority = [info.arguments.firstObject floatValue];
        
        // https://developer.apple.com/documentation/uikit/nslayoutconstraint/1526946-priority
        // Priorities may not change from nonrequired to required, or from required to nonrequired. An exception will be thrown if a priority of required in macOS or UILayoutPriorityRequired in iOS is changed to a lower priority, or if a lower priority is changed to a required priority after the constraints is added to a view. Changing from one optional priority to another optional priority is allowed even after the constraint is installed on a view.
        if (constraint.isActive) {
            if (constraint.priority == UILayoutPriorityRequired || priority == UILayoutPriorityRequired) {
                NSAssert(!constraint.isActive, @"激活后不允许修改priority⚠️");
            }
        }
        
        
    } error:nil];
    
//    [NSAssertionHandler.currentHandler handleFailureInMethod:<#(nonnull SEL)#> object:<#(nonnull id)#> file:<#(nonnull NSString *)#> lineNumber:<#(NSInteger)#> description:<#(nullable NSString *), ...#>];
    
//    NSError *assertionHandlerError = nil;
    
//    [hook kc_hookWithObjc:NSAssertionHandler.class selector:@selector(handleFailureInMethod:object:file:lineNumber:description:) withOptions:KcAspectTypeInstead usingBlock:^(KcHookAspectInfo * _Nonnull info) {
//
//        NSArray *arguments = info.arguments;
//        NSLog(@"%@", arguments);
//
//    } error:&assertionHandlerError];
//
//    if (assertionHandlerError != nil) {
//        NSLog(@"❌ hook 失败: %@", assertionHandlerError);
//    }
}

/// 观察布局约束
+ (void)observerLayoutConstraintWithFirstItem:(nullable id)firstItem
                               firstAttribute:(NSLayoutAttribute)firstAttribute
                                   secondItem:(nullable id)secondItem
                              secondAttribute:(NSLayoutAttribute)secondAttribute
                                     relation:(NSLayoutRelation)relation
                                     constant:(CGFloat)constant
                                    findBlock:(void(^)(void))block {
    /* setActive
     + NSLayoutConstraint.activate(layoutConstraints)
     + [NSLayoutConstraint _addOrRemoveConstraints:activate:]
     */
    [KcHookTool.manager kc_hookWithObjc:NSLayoutConstraint.class selector:@selector(setActive:) withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        NSLayoutConstraint * _Nullable constraint = info.instance;
        BOOL isActive = [info.arguments.firstObject boolValue];
        
        if (!constraint || !isActive) {
            return;
        }
        
        // 检查 constant
        if (constraint.constant != constant || relation != constraint.relation) {
            return;
        }
        
        // 检查 firstAttribute、secondAttribute
        if (firstAttribute != constraint.firstAttribute || secondAttribute != constraint.secondAttribute) {
            return;
        }
        
        BOOL firstItemEqual = firstItem && constraint.firstItem && [firstItem isEqual:constraint.firstItem];
        if (!firstItemEqual) {
            return;
        }
        
        BOOL secondItemEqual = false;
        
        if (secondItem && constraint.secondItem && [secondItem isEqual:constraint.secondItem]) {
            secondItemEqual = true;
        } else if (!secondItem && !constraint.secondItem) {
            secondItemEqual = true;
        }
        
        if (!secondItemEqual) {
            return;
        }
        
        NSLog(@"✅ 找到了autoLayout");
        
        if (block) {
            block();
        }
    } error:nil];
    
    // setConstant
    [KcHookTool.manager kc_hookWithObjc:NSLayoutConstraint.class selector:@selector(setConstant:) withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        NSLayoutConstraint * _Nullable constraint = info.instance;
        CGFloat _constant = [info.arguments.firstObject doubleValue];
        
        if (!constraint) {
            return;
        }
        
        // 检查 constant
        if (_constant != constant || relation != constraint.relation) {
            return;
        }
        
        // 检查 firstAttribute、secondAttribute
        if (firstAttribute != constraint.firstAttribute || secondAttribute != constraint.secondAttribute) {
            return;
        }
        
        BOOL firstItemEqual = firstItem && constraint.firstItem && [firstItem isEqual:constraint.firstItem];
        BOOL secondItemEqual = secondItem && constraint.secondItem && [secondItem isEqual:constraint.secondItem];
        
        if (!firstItemEqual || !secondItemEqual) {
            return;
        }
        
        NSLog(@"✅ 找到了autoLayout");
        
        if (block) {
            block();
        }
    } error:nil];
    
    // NSLayoutConstraint.__allocating_init(item:attribute:relatedBy:toItem:attribute:multiplier:constant:)
    // + (instancetype)constraintWithItem:(id)view1 attribute:(NSLayoutAttribute)attr1 relatedBy:(NSLayoutRelation)relation toItem:(nullable id)view2 attribute:(NSLayoutAttribute)attr2 multiplier:(CGFloat)multiplier constant:(CGFloat)c
    
//    [object_getClass(NSLayoutConstraint.class) kc_hookSelectorName:@"constraintWithItem:attribute:relatedBy:toItem:attribute:multiplier:constant:" swizzleSelectorName:@"kc_hook_constraintWithItem:attribute:relatedBy:toItem:attribute:multiplier:constant:"];
//    
//    __weak typeof(firstItem) weakFirstItem = firstItem;
//    __weak typeof(secondItem) weakSecondItem = secondItem;
//    [NSLayoutConstraint kc_addLayoutCheck:^(id _firstItem, NSLayoutAttribute _firstAttribute, NSLayoutRelation _relation, id _secondItem, NSLayoutAttribute _secondAttribute, CGFloat _multiplier, CGFloat _constant) {
//        __strong typeof(weakFirstItem) strongFirstItem = weakFirstItem;
//        __strong typeof(weakSecondItem) strongSecondItem = weakSecondItem;
//        
//        // 检查 constant
//        if (_constant != constant || relation != _relation) {
//            return;
//        }
//        
//        // 检查 firstAttribute、secondAttribute
//        if (firstAttribute != _firstAttribute || secondAttribute != _secondAttribute) {
//            return;
//        }
//        
//        BOOL firstItemEqual = strongFirstItem && _firstItem && ![_firstItem isEqual:[NSNull null]] && [strongFirstItem isEqual:_firstItem];
//        BOOL secondItemEqual = strongSecondItem && _secondItem && ![_secondItem isEqual:[NSNull null]] && [strongSecondItem isEqual:_secondItem];
//        
//        if (!firstItemEqual || !secondItemEqual) {
//            return;
//        }
//        
//        NSLog(@"✅ 找到了autoLayout");
//        
//        if (block) {
//            block();
//        }
//    }];
}

@end

//@implementation NSLayoutConstraint (KcLayoutCheck)
//
//static void *kc_layoutCheckKey = &kc_layoutCheckKey;
//
//+ (instancetype)kc_hook_constraintWithItem:(id)view1 attribute:(NSLayoutAttribute)attr1 relatedBy:(NSLayoutRelation)relation toItem:(id)view2 attribute:(NSLayoutAttribute)attr2 multiplier:(CGFloat)multiplier constant:(CGFloat)c {
//    NSMutableArray *_Nullable layoutChecks = objc_getAssociatedObject(self, kc_layoutCheckKey);
//    
//    if (layoutChecks) {
//        for (id element in layoutChecks) {
//            void (^layoutCheck)(id view1, NSLayoutAttribute attr1, NSLayoutRelation relation, id view2, NSLayoutAttribute attr2, CGFloat multiplier, CGFloat constant) = element;
//            layoutCheck(view1, attr1, relation, view2, attr2, multiplier, c);
//        }
//    }
//    
//    // 要在MRC下, 自己处理内存管理, ARC下会crash⚠️
//    return [NSLayoutConstraint kc_hook_constraintWithItem:view1 attribute:attr1 relatedBy:relation toItem:view2 attribute:attr2 multiplier:multiplier constant:c];
//}
//
//+ (void)kc_addLayoutCheck:(void (^)(id view1, NSLayoutAttribute attr1, NSLayoutRelation relation, id view2, NSLayoutAttribute attr2, CGFloat multiplier, CGFloat constant))layoutCheck {
//    NSMutableArray *layoutChecks = objc_getAssociatedObject(self, kc_layoutCheckKey);
//    
//    if (!layoutChecks) {
//        layoutChecks = [[NSMutableArray alloc] init];
//        
//        objc_setAssociatedObject(self, kc_layoutCheckKey, layoutChecks, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
//    }
//    
//    [layoutChecks addObject:layoutCheck];
//}
//
//@end
