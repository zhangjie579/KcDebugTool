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
@import KcDebugSwift;

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

/// 不能响应事件的原因
/*
  不能处理event:
     1.hidden
     2.userInteractionEnabled
     3.alpha < 0.01
     4.bounds不包括point
     5._isAnimatedUserInteractionEnabled
 
 - (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
 {
     if (self.hidden || !self.userInteractionEnabled || self.alpha < 0.01 || ![self pointInside:point withEvent:event] || ![self _isAnimatedUserInteractionEnabled]) {
         return nil;
     } else {
         /// 倒序，从最top的开始遍历
         for (UIView *subview in [self.subviews reverseObjectEnumerator]) {
             /// [subview convertPoint:point fromView:self] 获得point对应在child上面的点
             /// 看child是否可以处理
             UIView *hitView = [subview hitTest:[subview convertPoint:point fromView:self] withEvent:event];
             if (hitView) {
                 return hitView;
             }
         }
         return self;
     }
 }
 */
- (BOOL)kc_checkHitTestQuestion {
    UIView *currentView = self;
    UIResponder *nextResponder = self;
    
    while (nextResponder && currentView) {
        if (currentView.isHidden) {
            [KcLogParamModel logWithKey:@"❌不能点击" format:@"isHidden == true, %@ 属性信息: %@", currentView, [currentView kc_debug_findPropertyName]];
            return false;
        }
        
        if (!currentView.isUserInteractionEnabled) {
            [KcLogParamModel logWithKey:@"❌不能点击" format:@"isUserInteractionEnabled == false, %@ 属性信息: %@", currentView, [currentView kc_debug_findPropertyName]];
            return false;
        }
        
        if (currentView.alpha < 0.01) {
            [KcLogParamModel logWithKey:@"❌不能点击" format:@"self.alpha < 0.01, %@ 属性信息: %@", currentView, [currentView kc_debug_findPropertyName]];
            return false;
        }
        
        if (currentView.frame.size.width <= 0 || currentView.frame.size.height <= 0) {
            [KcLogParamModel logWithKey:@"❌不能点击" format:@"self.size <= 0, %@ 属性信息: %@", currentView, [currentView kc_debug_findPropertyName]];
            return false;
        }
        
        CGPoint centerPoint = [currentView convertPoint:CGPointMake(self.frame.size.width / 2, self.frame.size.height / 2) fromView:self];
        
        // pointInside
        if (![currentView pointInside:centerPoint withEvent:nil]) {
            [KcLogParamModel logWithKey:@"❌不能点击" format:@"pointInside:withEvent: = NO, %@ 属性信息: %@", currentView, [currentView kc_debug_findPropertyName]];
            return false;
        }
        
        // hitTest 看看返回什么
        UIView *_Nullable hitView = [currentView hitTest:centerPoint withEvent:nil];
        if (!hitView || ![hitView isEqual:self]) {
            [KcLogParamModel logWithKey:@"❌不能点击" format:@"hitTest返回值: %@ 属性信息: %@", hitView, [hitView kc_debug_findPropertyName]];
            return false;
        }
        
        UIView *superview = currentView.superview;
        if (superview) {
            CGRect superBounds = CGRectMake(0, 0, superview.frame.size.width, superview.frame.size.height);
            
            BOOL isContain = CGRectContainsPoint(superBounds, currentView.center);
            
            if (!isContain) {
                [KcLogParamModel logWithKey:@"❌不能点击" format:@"尺寸与super对不上, frame: %@, superBounds: %@, %@ 属性信息: %@", NSStringFromCGRect(currentView.frame), NSStringFromCGRect(superBounds), currentView, [currentView kc_debug_findPropertyName]];
                return false;
            }
        }
        
        nextResponder = nextResponder.nextResponder;
        currentView = nil;
        
        if (nextResponder) {
            if ([nextResponder isKindOfClass:[UIView self]]) {
                currentView = (UIView *)nextResponder;
            } else if ([nextResponder isKindOfClass:[UIViewController self]]) {
                currentView = ((UIViewController *)nextResponder).view;
            }
        }
    }
    
    return true;
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

/// 检查不可见的原因
/*
 1、自己size不对
 2、parent size不对
 * parent size过小，clip to bounds = true
 */
- (BOOL)kc_checkInvisibleQuestion {
    
    UIView *currentView = self;
    
    while (currentView) {
        if (currentView.hidden) {
            [KcLogParamModel logWithKey:@"❌不能显示" format:@"isHidden == true, %@", currentView];
            return false;
        }
        
        if (currentView.alpha < 0.01) {
            [KcLogParamModel logWithKey:@"❌不能显示" format:@"self.alpha < 0.01, %@", currentView];
            return false;
        }
        
        if (currentView.frame.size.width <= 0 || currentView.frame.size.height <= 0) {
            [KcLogParamModel logWithKey:@"❌不能显示" format:@"size <= 0, %@", currentView];
            return false;
        }
        
        UIView *superview = currentView.superview;
        if (superview) {
            if (superview.frame.size.width <= 0 || superview.frame.size.height <= 0) {
                [KcLogParamModel logWithKey:@"❌不能显示" format:@"在superview: %@的size <= 0", superview];
                return false;
            }
            
            BOOL isContains = CGRectContainsPoint(superview.bounds, currentView.center);
            
            if (!isContains) {
                [KcLogParamModel logWithKey:@"❌不能显示" format:@"在superview: %@的外面, clipsToBounds: %d", superview, superview.clipsToBounds];
                return false;
            }
        }
        
        currentView = superview;
    }
    
    return true;
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
