//
//  KcCheckUIManager.m
//  KcDebugTool
//
//  Created by 张杰 on 2025/5/29.
//

#import "KcCheckUIManager.h"
#import "NSObject+KcMethodExtension.h"
#import <objc/message.h>

/// 有问题view的边框
@interface KcQuestionBorderView : UIView

+ (void)addToView:(UIView *)view;
+ (void)removeView:(UIView *)view;

@end

@interface KcCheckUIManager ()

@property (nonatomic, strong) NSMutableArray<NSString *> *checkFrameWhiteClassNames;
@property (nonatomic, strong) NSMutableArray<Class> *checkFrameWhiteClasses;

@end

@implementation KcCheckUIManager

+ (instancetype)sharedManager {
    static KcCheckUIManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[KcCheckUIManager alloc] init];
    });
    
    return manager;
}

#pragma mark - public

/// 检查frame对不对
- (void)check_frame_with_white_class_names:(nullable NSArray<NSString *> *)whiteClassNames whiteClasses:(nullable NSArray<Class> *)whiteClasses {
    if (whiteClassNames) {
        [self.checkFrameWhiteClassNames addObjectsFromArray:whiteClassNames];
    }
    if (whiteClasses) {
        [self.checkFrameWhiteClasses addObjectsFromArray:whiteClasses];
    }
    
    [NSObject.kc_hookTool kc_hookWithObjc:UIView.class selectorName:@"layoutSubviews" withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        UIView *_Nullable view = info.instance;
        
        [KcCheckUIManager check_view_frame_is_beyound_mask:view];
        
//        NSLog(@"qq --- %@, %@", view, NSStringFromCGRect(view.frame));
    }];
}

/// 检查 translatesAutoresizingMaskIntoConstraints 对不对
- (void)check_translatesAutoresizingMaskIntoConstraints {
    [NSObject.kc_hookTool kc_hookWithObjc:UIView.class selector:@selector(setFrame:) withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        UIView *_Nullable view = info.instance;
        
        if (!view.translatesAutoresizingMaskIntoConstraints) {
            [KcLogParamModel logWithKey:@"layout" format:@"❌ setFrame方式无效 translatesAutoresizingMaskIntoConstraints = false : %@", view];
        }
        
//        NSLog(@"qq --- %@, %@", view, NSStringFromCGRect(view.frame));
    } error:nil];
    
    /* 方案存在问题
     1、children设置约束, 有些约束会导致给 super 设置约束, but这里不知道这个约束是children设置引起的, 实际这个约束可用可不用, 因为不是自己设置的
     */
//    [NSObject.kc_hookTool kc_hookWithObjc:NSLayoutConstraint.class selector:@selector(setActive:) withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
//        NSLayoutConstraint *_Nullable constraint = info.instance;
//        
//        if (!constraint) {
//            return;
//        }
//        
//        BOOL isActive = [info.arguments.firstObject boolValue];
//        
//        if (!isActive) {
//            return;
//        }
//        
//        UIView *_Nullable firstItem = constraint.firstItem;
//        
//        if (!firstItem || ![firstItem isKindOfClass:[UIView class]]) {
//            return;
//        }
//        
//        if (!firstItem.translatesAutoresizingMaskIntoConstraints) {
//            return;
//        }
//        
//        NSString *className = NSStringFromClass(firstItem.class);
//        
//        // 过滤系统的
//        if ([className hasPrefix:@"_"] || [className hasPrefix:@"UI"]) {
//            return;
//        }
//        
//        [KcLogParamModel logWithKey:@"layout" format:@"❌ autoLayout translatesAutoresizingMaskIntoConstraints值错误 %@", firstItem];
//        
//    } error:nil];
    
    // 有个问题: 有些情况下莫名其妙加的 constraints, 但是你后面 setFrame也有效
//    [KcHookTool.manager kc_hookWithObjc:UIView.class selector:@selector(layoutSubviews) withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
//
//        if (!info.instance || ![info.instance isKindOfClass:[UIView class]]) {
//            return;
//        }
//
//        UIView *view = info.instance;
//        
//        if (!view.translatesAutoresizingMaskIntoConstraints) {
//            return;
//        }
//        
//        NSString *className = NSStringFromClass(view.class);
//        
//        // 过滤系统的
//        if ([className hasPrefix:@"_"] || [className hasPrefix:@"UI"]) {
//            return;
//        }
//        
//        // 参考 lookServer库 UIView+LookinServer.m
//        // 通过 constraintsAffectingLayoutForAxis 可以拿到会影响 self 布局的所有已生效的 constraints
//        NSArray<__kindof NSLayoutConstraint *> *constraints = [view constraintsAffectingLayoutForAxis:UILayoutConstraintAxisHorizontal];
//        
////        NSArray<__kindof NSLayoutConstraint *> *constraints = view.constraints;
//
//        if (constraints.count > 0) {
//            [KcLogParamModel logWithKey:@"layout" format:@"❌ autoLayout translatesAutoresizingMaskIntoConstraints值错误 %@", view];
//            return;
//        }
//        
//        constraints = [view constraintsAffectingLayoutForAxis:UILayoutConstraintAxisVertical];
//        if (constraints.count > 0) {
//            [KcLogParamModel logWithKey:@"layout" format:@"❌ autoLayout translatesAutoresizingMaskIntoConstraints值错误 %@", view];
//            return;
//        }
//    } error:nil];
}

#pragma mark - private

/// 检查view的frame是否越界
+ (void)check_view_frame_is_beyound_mask:(UIView *)view {
    UIView *_Nullable superview = view.superview;
    
    if (!superview || view.isHidden) {
        [KcQuestionBorderView removeView:view];
        return;
    }
    
    if ([view isKindOfClass:[KcQuestionBorderView class]]
        || [view isKindOfClass:[UICollectionViewCell class]]
        || [view isKindOfClass:[UITableViewCell class]]
        || [view isKindOfClass:[UICollectionReusableView class]]
        || [view isKindOfClass:[UITableViewHeaderFooterView class]]
        || [view isKindOfClass:[UISwitch class]]
        || [view isKindOfClass:[UIVisualEffectView class]]) {
        return;
    }
    
    for (Class cls in [KcCheckUIManager.sharedManager checkFrameWhiteClasses]) {
        if ([view isKindOfClass:cls]) {
            return;
        }
    }
    
    NSString *viewClsName = NSStringFromClass(view.class);
    
    // 过滤class
    if ([viewClsName hasPrefix:@"_"] || [viewClsName hasPrefix:@"UI"]) {
        return;
    }
    
    for (NSString *className in KcCheckUIManager.sharedManager.checkFrameWhiteClassNames) {
        if ([className containsString:viewClsName]) {
            return;
        }
    }
    
    // 过滤滑动列表
    if ([superview isMemberOfClass:[UIScrollView class]]) {
        return;
    }
    
    CGRect frame = view.frame;
    
    /*
     1、因为可能存在小数, so让上下左右都增加1
     2、不能用bounds, 因为对于滑动视图来说bounds会改
     */
    CGRect superBounds = CGRectMake(-1, -1, superview.frame.size.width + 2, superview.frame.size.height + 2);
    BOOL isContain = CGRectContainsRect(superBounds, frame);
    
    if (isContain) {
        [KcQuestionBorderView removeView:view];
    } else {
        [KcQuestionBorderView addToView:view];
    }
}

#pragma mark - 懒加载

- (NSMutableArray<NSString *> *)checkFrameWhiteClassNames {
    if (!_checkFrameWhiteClassNames) {
        _checkFrameWhiteClassNames = [[NSMutableArray alloc] initWithObjects:@"DebugCheckTapAreaView", nil];
    }
    return _checkFrameWhiteClassNames;
}

- (NSMutableArray<Class> *)checkFrameWhiteClasses {
    if (!_checkFrameWhiteClasses) {
        _checkFrameWhiteClasses = [[NSMutableArray alloc] init];
        
        Class mjCls = NSClassFromString(@"MJRefreshComponent");
        if (mjCls) {
            [_checkFrameWhiteClasses addObject:mjCls];
        }
        
        [_checkFrameWhiteClasses addObject:NSClassFromString(@"UIDimmingView")];
        [_checkFrameWhiteClasses addObject:NSClassFromString(@"UITransitionView")];
    }
    return _checkFrameWhiteClasses;
}

@end

#pragma mark - KcQuestionBorderView

@implementation KcQuestionBorderView

static void *const kc_question_borderView = (void *)&kc_question_borderView;

+ (void)addToView:(UIView *)view {
    KcQuestionBorderView *borderView = objc_getAssociatedObject(view, kc_question_borderView);
    
    if (!borderView) {
        KcQuestionBorderView *borderView = [[KcQuestionBorderView alloc] init];
        
        borderView.userInteractionEnabled = NO;
        
    //    borderView.translatesAutoresizingMaskIntoConstraints = true;
        
        borderView.frame = view.bounds;
        borderView.layer.borderColor = UIColor.redColor.CGColor;
        borderView.layer.borderWidth = 2;
        
        objc_setAssociatedObject(view, kc_question_borderView, borderView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    borderView.frame = view.bounds;
    
    [view addSubview:borderView];
    // 万一上面刚好一样大，并且有color就看不到了
//    [view sendSubviewToBack:borderView];
}

+ (void)removeView:(UIView *)view {
    KcQuestionBorderView *borderView = objc_getAssociatedObject(view, kc_question_borderView);
    
    if (!borderView) {
        return;
    }
    
    [borderView removeFromSuperview];
}

@end
