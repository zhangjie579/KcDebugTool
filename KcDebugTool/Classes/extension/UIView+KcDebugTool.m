//
//  UIView+KcDebugTool.m
//  OCTest
//
//  Created by samzjzhang on 2020/4/27.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "UIView+KcDebugTool.h"
//#import "NSObject+KcMethodExtension.h"
#import "NSObject+KcRuntimeExtension.h"
#import "KcAutoLayoutCheck.h"
#import "UIColor+KcDebugTool.h"
#import <math.h>
#import <objc/runtime.h>
@import KcDebugSwift;

static const void *kc_outOfSuperviewBorderKey = &kc_outOfSuperviewBorderKey;

@implementation UIView (KcDebugTool)

/// 是否不可见
- (BOOL)kc_unVisibleInHierarchy {
    if (self.hidden || self.alpha == 0) {
        return YES;
    }
    
    if ([self isKindOfClass:[UIWindow class]])
        return NO;

    if (!self.window)
        return YES;

    return [self.superview kc_unVisibleInHierarchy];
}

/// 所属viewController
- (nullable UIViewController *)kc_superViewController {
    id responder = self.nextResponder;
    while (responder) {
        if ([responder isKindOfClass: [UIViewController class]] || [responder isKindOfClass: [UIWindow class]]) {
            return responder;
        }
        responder = [responder nextResponder];
    }
    
    if ([responder isKindOfClass: [UIViewController class]]) {
        return responder;
    }
    return nil;
}

/// 找到合适的
- (void)kc_fiterNextResponderWithBlock:(BOOL(^)(UIResponder *responder))block {
    if (!block) {
        return;
    }
    
    UIResponder *responder = self.nextResponder;
    while (responder) {
        [KcLogParamModel logWithKey:@"响应链" format:@"responder: %@", responder];
        BOOL result = block(responder);
        if (result) {
            return;
        }
        responder = responder.nextResponder;
    }
}

/// 遍历响应链
- (void)kc_forEachResponderChain {
    UIResponder *responder = self.nextResponder;
    while (responder) {
        [KcLogParamModel logWithKey:@"响应链" format:@"responder: %@", responder];
        responder = responder.nextResponder;
    }
}

#pragma mark - hook

/// 添加view (也可以重写didAddSubview方法)
+ (void)kc_hook_addSubview {
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    // - (void)didAddSubview:(UIView *)subview;
    [tool kc_hookWithObjc:UIView.class
                 selector:@selector(addSubview:)
              withOptions:KcAspectTypeAfter
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        UIView *subView = info.arguments[0];
        [KcLogParamModel logWithKey:info.selectorName format:@"self: %@, subView: %@", info.instance, subView];
    } error:nil];
}

/// 移除
+ (void)kc_hook_removeFromSuperview {
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    
    // - (void)willRemoveSubview:(UIView *)subview;
    [tool kc_hookWithObjc:UIView.class
                 selector:@selector(removeFromSuperview)
              withOptions:KcAspectTypeAfter
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:info.selectorName format:@"self: %@, superview: %@", info.instance, [info.instance superview]];
    } error:nil];
}

/// 第一响应值相关
+ (void)kc_hook_firstResponder {
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    [tool kc_hookWithObjc:UIResponder.class
                 selector:@selector(becomeFirstResponder)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"第一响应值" format:@"%@, %@", info.selectorName, info.instance];
    } error:nil];
    
    [tool kc_hookWithObjc:UIResponder.class
                 selector:@selector(resignFirstResponder)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"第一响应值" format:@"%@, %@", info.selectorName, info.instance];
    } error:nil];
    
    [tool kc_hookWithObjc:UIView.class
                 selector:@selector(endEditing:)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"第一响应值" format:@"%@, self: %@, subviews: %@", info.selectorName, info.instance, [info.instance subviews]];
    } error:nil];
}

/// hook view init
+ (void)kc_hook_initWithViewClassNames:(NSSet<NSString *> *)classNames {
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    [tool kc_hookWithObjc:[UIView class]
                 selector:@selector(initWithFrame:)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        if (![info.instance kc_isClassOrSubClass:classNames]) {
            return;
        }
        [KcLogParamModel logWithKey:@"init" format:@"view: %@", info.instance];
    } error:nil];
}

/// 背景色
+ (void)kc_hook_backgroundColor {
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    [tool kc_hookWithObjc:UIView.class
                 selector:@selector(setBackgroundColor:)
              withOptions:KcAspectTypeBefore
               usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        [KcLogParamModel logWithKey:@"backgroundColor" format:@"%@, %@", info.instance, info.arguments.firstObject ?: @""];
    } error:nil];
}

#pragma mark - 布局相关

/// log view层级下丢失lessThanOrEqual约束labels
- (nullable NSString *)kc_log_missMaxHorizontalConstraintViewHierarchyForLabel {
    return [self kc_log_missMaxHorizontalConstraintViewHierarchyWithClassType:UILabel.class];
}

/// log view层级下丢失lessThanOrEqual约束的classType类型的view
- (nullable NSString *)kc_log_missMaxHorizontalConstraintViewHierarchyWithClassType:(Class)classType {
    NSMutableArray<KcPropertyResult *> *_Nullable propertys = [KcAutoLayoutCheck missMaxConstraintViewHierarchyWithView:self forAxis:UILayoutConstraintAxisHorizontal classType:classType];
    
    if (!propertys || propertys.count <= 0) {
        return nil;
    }
    
    NSMutableString *string = [[NSMutableString alloc] init];
    
    for (KcPropertyResult *property in propertys) {
        [string appendFormat:@"%@\n", property.debugLog];
    }
    
    [KcLogParamModel logWithKey:@"constraint - 缺少lessThanOrEqual" format:@"%@", string];
    
    return string;
}

/// 查找属性信息
- (nullable KcPropertyResult *)propertyInfoWithIsLog:(BOOL)isLog {
    if (@available(iOS 13.0, *)) {
        KcPropertyResult *result = [KcFindPropertyTooler findResponderChainObjcPropertyNameWithObject:self startSearchView:nil isLog:isLog];
        return result;
    } else {
        return nil;
    }
}

#pragma mark - 查找方法

/// 查找keyPath的值为value的所有祖先
/// - Parameters:
///   - value: keyPath的值
///   - keyPath: keyPath
- (NSArray<id> *)kc_findAncestorViewValue:(id)value keyPath:(NSString *)keyPath {
    return [self kc_findAncestorViewValue:value valueBlock:^id(UIView *view) {
        return [view valueForKeyPath:keyPath];
    }];
}

/// 查找并输出keyPath的值为value的所有祖先
/// - Parameters:
///   - value: keyPath的值
///   - keyPath: keyPath
- (NSString *)kc_log_findAncestorViewValue:(id)value keyPath:(NSString *)keyPath {
    NSArray<id> *ancestors = [self kc_findAncestorViewValue:value keyPath:keyPath];
    
    NSMutableString *log_str = [NSMutableString stringWithString:@""];
    for (id objc in ancestors) {
        [log_str appendFormat:@"%@\n", [KcLogParamModel instanceDesc:objc]];
    }
    
    [KcLogParamModel logWithKey:@"🐶 查找keyPath的值为value的所有祖先, 从下往上排列 🐶" format:@"%@", log_str];
    
    return log_str;
}

/// 查找keyPath的值为value的所有祖先
/// - Parameters:
///   - value: 对应的值
///   - selectorName: 方法名
- (NSArray<id> *)kc_findAncestorViewValue:(id)value selectorName:(NSString *)selectorName {
    return [self kc_findAncestorViewValue:value valueBlock:^id(UIView *view) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        return [view performSelector:NSSelectorFromString(selectorName)];
#pragma clang diagnostic pop
    }];
}

/// 查找祖先的某些值为value
/// - Parameters:
///   - value: 值
///   - valueBlock: 获取值的方式
- (NSArray<id> *)kc_findAncestorViewValue:(id)value valueBlock:(id(^)(UIView *))valueBlock {
    // 这里用superview而不是nextResponder, 因为nextResponder可能为UIViewController, view有的属性它不一定有⚠️
    UIView *_Nullable superview = self.superview;
    
    NSString *_Nullable valueStr = nil;
    if ([value isKindOfClass:[NSString class]]) {
        valueStr = (NSString *)value;
    } else if ([value isKindOfClass:[NSNumber class]]) {
        valueStr = [value stringValue];
    }
    
    // 祖先
    NSMutableArray<id> *ancestors = [[NSMutableArray alloc] init];
    
    while (superview) {
        id objc = valueBlock(superview);
        
        if (valueStr != nil) {
            if ([objc isKindOfClass:[NSString class]] && [objc isEqualToString:valueStr]) {
                [ancestors addObject:superview];
            } else if ([objc isKindOfClass:[NSNumber class]] && [[objc stringValue] isEqualToString:valueStr]) {
                [ancestors addObject:superview];
            }
        } else if ([objc isEqual:value]) {
            [ancestors addObject:superview];
        }
        
        superview = superview.superview;
    }
    
    return ancestors;
}

/// 查找所有祖先keyPath的值
- (NSArray<NSString *> *)kc_findAncestorViewKeyPath:(NSString *)keyPath {
    UIView *_Nullable currentView = self;
    
    // 祖先
    NSMutableArray<NSString *> *ancestorValues = [[NSMutableArray alloc] init];
    
    while (currentView) {
        id value = [currentView valueForKeyPath:keyPath];
        
        if (value) {
            [ancestorValues addObject:[NSString stringWithFormat:@"<%@: %p>, %@", NSStringFromClass([currentView class]), currentView, value]];
        }
        
        currentView = currentView.superview;
    }
    
    return ancestorValues;
}

#pragma mark - 颜色

/// 是否亮色
+ (BOOL)kc_isLightColor:(UIColor *)color {
//    CGFloat red, green, blue, alpha;
//    [color getRed:&red green:&green blue:&blue alpha:&alpha];
//    
//    // 通过 getRed 方法获取颜色的 RGB 分量
//    // 使用亮度公式计算亮度
//    double brightness = 0.299 * red + 0.587 * green + 0.114 * blue;
//    // 根据亮度判断颜色类型
//    return brightness >= 0.5;

    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    // 将 UIColor 转换为 RGB 空间
    if ([color respondsToSelector:@selector(getRed:green:blue:alpha:)]) {
        [color getRed:&red green:&green blue:&blue alpha:&alpha];
    } else {
        // 兼容非 RGB 颜色空间
        CGColorRef cgColor = [color CGColor];
        size_t numComponents = CGColorGetNumberOfComponents(cgColor);
        const CGFloat *components = CGColorGetComponents(cgColor);
        if (numComponents == 2) {
            // 灰度色
            red = green = blue = components[0];
            alpha = components[1];
        } else if (numComponents == 4) {
            red = components[0];
            green = components[1];
            blue = components[2];
            alpha = components[3];
        }
    }
    // 计算亮度
    CGFloat brightness = (red * 299 + green * 587 + blue * 114) / 1000;
    return brightness >= 0.5;
}

#pragma mark - 检查

/// 默认检查 bounds 中心；frame 属于父坐标系，不能作为自身坐标使用。
- (BOOL)kc_checkHitTestQuestion {
    // 避免在后台线程读取 UIView 的几何信息。
    if (![NSThread isMainThread]) {
        [KcLogParamModel logWithKey:@"⚠️点击检查" format:@"请在主线程调用 kc_checkHitTestQuestion"];
        return NO;
    }
    return [self kc_checkHitTestQuestionAtPoint:CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds))];
}

- (BOOL)kc_checkHitTestQuestionAtPoint:(CGPoint)point {
    if (![NSThread isMainThread]) {
        [KcLogParamModel logWithKey:@"⚠️点击检查" format:@"请在主线程调用 kc_checkHitTestQuestionAtPoint:"];
        return NO;
    }
    if (!isfinite(point.x) || !isfinite(point.y)) {
        [KcLogParamModel logWithKey:@"❌不能点击" format:@"检查点不是有限坐标: %@", NSStringFromCGPoint(point)];
        return NO;
    }

    UIWindow *window = [self isKindOfClass:UIWindow.class] ? (UIWindow *)self : self.window;
    if (!window) {
        [KcLogParamModel logWithKey:@"❌不能点击" format:@"视图未加入 UIWindow: %@", self];
        return NO;
    }

    // 从事件入口检查，才能覆盖兄弟视图遮挡和祖先自定义 hitTest 的情况。
    // 不提前用 bounds/pointInside 排除，允许自定义 hitTest 扩大响应区域。
    CGPoint windowPoint = [self convertPoint:point toView:window];
    UIView *hitView = [window hitTest:windowPoint withEvent:nil];
    BOOL hitsTarget = hitView && (hitView == self || [hitView isDescendantOfView:self]);
    if (hitsTarget) {
        // disabled 不一定导致 hitTest 返回 nil，但控件不会处理 touch/action。
        // 成功分支只判断目标；祖先控件对命中的影响交给实际 hitTest 处理。
        if ([self isKindOfClass:UIControl.class] && !((UIControl *)self).isEnabled) {
            [KcLogParamModel logWithKey:@"❌不能点击" format:@"UIControl.enabled == NO，命中但控件不会响应: %@", self];
            return NO;
        }
        [KcLogParamModel logWithKey:@"✅命中检查通过" format:@"目标: %@, point: %@, hitView: %@。仅表示所属 window 内命中目标或其子视图，不保证 action/手势回调执行；仍需排查手势竞争、cancelsTouchesInView、UIScrollView 的触摸延迟/取消、动画交互限制及其他 window 遮挡。", self, NSStringFromCGPoint(point), hitView];
        return YES;
    }

    [KcLogParamModel logWithKey:@"❌不能点击" format:@"目标: %@, point: %@, windowPoint: %@, window.hitTest 返回: %@", self, NSStringFromCGPoint(point), NSStringFromCGPoint(windowPoint), hitView];

    // 失败后再收集标准命中条件；沿 superview 遍历，响应链不等于视图树。
    // 这些是诊断线索，最终结果以上面的 window.hitTest 为准。
    for (UIView *view = self; view; view = view.superview) {
        CGPoint localPoint = [view convertPoint:point fromView:self];
        if (view.isHidden) {
            [KcLogParamModel logWithKey:@"点击检查线索" format:@"hidden == YES: %@", view];
        }
        if (!view.isUserInteractionEnabled) {
            [KcLogParamModel logWithKey:@"点击检查线索" format:@"userInteractionEnabled == NO: %@", view];
        }
        if (view.alpha <= 0.01) {
            [KcLogParamModel logWithKey:@"点击检查线索" format:@"alpha <= 0.01 (%.5f)，处于命中透明度阈值附近或以下: %@", view.alpha, view];
        }
        if ([view isKindOfClass:UIControl.class] && !((UIControl *)view).isEnabled) {
            [KcLogParamModel logWithKey:@"点击检查线索" format:@"UIControl.enabled == NO: %@", view];
        }
        if (![view pointInside:localPoint withEvent:nil]) {
            [KcLogParamModel logWithKey:@"点击检查线索" format:@"pointInside:withEvent: == NO, point: %@, bounds: %@, view: %@；默认命中会跳过该分支，与 clipsToBounds 无关，自定义 hitTest 可能改变此行为。", NSStringFromCGPoint(localPoint), NSStringFromCGRect(view.bounds), view];
        }
        if (view.layer.animationKeys.count > 0) {
            [KcLogParamModel logWithKey:@"点击检查线索" format:@"存在动画: %@, view: %@；检查动画是否允许交互以及 presentation/model 坐标差异，存在动画本身不等于不能点击。", view.layer.animationKeys, view];
        }
        if (view == window) {
            break;
        }
    }
    [KcLogParamModel logWithKey:@"点击检查线索" format:@"若标准属性正常，请检查祖先自定义 hitTest:withEvent: 是否返回其他视图，以及返回的 hitView 所在分支是否遮挡目标。"];
    return NO;
}

/// 查找圆角的问题
- (NSMutableArray<NSString *> *)kc_findCornerRadiusQuestion {
    NSMutableArray<NSString *> *items = [[NSMutableArray alloc] init];
    
    UIView *currentView = self;
    while (currentView) {
        [items addObject:[NSString stringWithFormat:@"<%@: %p>, cornerRadius: %.2f, clipsToBounds: %d, backgroundColor: %@", NSStringFromClass(currentView.class), currentView, currentView.layer.cornerRadius, currentView.clipsToBounds || currentView.layer.masksToBounds, [currentView.backgroundColor kc_hexString] ?: @""]];
        
        currentView = currentView.superview;
    }
    
    NSLog(@"%@", items);
    
    return items;
}

- (BOOL)kc_checkInvisibleQuestion {
    if (![NSThread isMainThread]) {
        [KcLogParamModel logWithKey:@"⚠️显示检查" format:@"请在主线程调用 kc_checkInvisibleQuestion"];
        return NO;
    }
    if (!self.window && ![self.window isKindOfClass:UIWindow.class]) {
        [KcLogParamModel logWithKey:@"❌不能显示" format:@"视图未加入 UIWindow: %@", self];
        return NO;
    }

    CGFloat effectiveAlpha = 1;
    CGRect visibleRect = self.bounds;
    for (UIView *view = self; view; view = view.superview) {
        if (view.hidden) {
            [KcLogParamModel logWithKey:@"❌不能显示" format:@"hidden == YES: %@", view];
            return NO;
        }
        effectiveAlpha *= view.alpha;
        if (effectiveAlpha <= 0.01) {
            [KcLogParamModel logWithKey:@"❌不能显示" format:@"累计 alpha <= 0.01: %@", view];
            return NO;
        }
        if (CGRectIsEmpty(visibleRect)) {
            [KcLogParamModel logWithKey:@"❌不能显示" format:@"可见区域为空: %@", view];
            return NO;
        }
        UIView *parent = view.superview;
        if (parent) {
            visibleRect = [view convertRect:visibleRect toView:parent];
            if (parent.clipsToBounds) {
                visibleRect = CGRectIntersection(visibleRect, parent.bounds);
            }
            if (CGRectIsEmpty(visibleRect)) {
                [KcLogParamModel logWithKey:@"❌不能显示" format:@"目标完全位于裁剪视图之外: %@", parent];
                return NO;
            }
        }
    }
    return YES;
}

- (BOOL)kc_checkOutOfSuperviewBounds {
    if (![NSThread isMainThread]) {
        [KcLogParamModel logWithKey:@"⚠️尺寸检查" format:@"请在主线程调用 kc_checkOutOfSuperviewBounds"];
        return NO;
    }

    BOOL allContained = YES;
    for (UIView *view = self; view.superview; view = view.superview) {
        UIView *parent = view.superview;
        CGRect rectInParent = [view convertRect:view.bounds toView:parent];
        BOOL contained = CGRectContainsRect(parent.bounds, rectInParent);
        CALayer *border = objc_getAssociatedObject(view, kc_outOfSuperviewBorderKey);
        if (!contained) {
            allContained = NO;
            if (!border) {
                border = [CALayer layer];
                border.borderColor = UIColor.redColor.CGColor;
                border.borderWidth = 2;
                objc_setAssociatedObject(view, kc_outOfSuperviewBorderKey, border, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            border.frame = view.bounds;
            [view.layer addSublayer:border];
            [KcLogParamModel logWithKey:@"❌超出父视图" format:@"view: %@, 在父视图中的范围: %@, parent: %@, bounds: %@", view, NSStringFromCGRect(rectInParent), parent, NSStringFromCGRect(parent.bounds)];
        } else if (border) {
            [border removeFromSuperlayer];
        }
    }
    return allContained;
}

#pragma mark - HitTest

/*
 - (nullable UIView *)hitTest:(CGPoint)point withEvent:(nullable UIEvent *)event;   // recursively calls -pointInside:withEvent:. point is in the receiver's coordinate system
 - (BOOL)pointInside:(CGPoint)point withEvent:(nullable UIEvent *)event;   // default returns YES if point is in bounds
 */
+ (void)kc_hookHitTest {
    [UIView kc_hookSelectorName:@"hitTest:withEvent:" swizzleSelectorName:@"kc_hitTest:withEvent:"];
}

// recursively calls -pointInside:withEvent:. point is in the receiver's coordinate system
- (nullable UIView *)kc_hitTest:(CGPoint)point withEvent:(nullable UIEvent *)event {
    UIView *_Nullable view = [self kc_hitTest:point withEvent:event];
    
    [KcLogParamModel logWithKey:@"hitTest" format:@"<%@: %p>, 返回值: %@", NSStringFromClass([self class]), self, view];
    
    return view;
}

// default returns YES if point is in bounds
- (BOOL)kc_pointInside:(CGPoint)point withEvent:(nullable UIEvent *)event {
    BOOL result = [self kc_pointInside:point withEvent:event];
    
    [KcLogParamModel logWithKey:@"pointInside" format:@"<%@: %p>, 返回值: %l", NSStringFromClass([self class]), self, result];
    
    return result;
}

@end
