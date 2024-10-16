//
//  UIColor+KcDebugTool.h
//  Pods
//
//  Created by 张杰 on 2024/10/16.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UIColor (KcDebugTool)

- (NSArray<NSNumber *> *)kc_rgbaComponents;
+ (instancetype)kc_colorFromRGBAComponents:(NSArray<NSNumber *> *)components;

- (NSString *)kc_rgbaString;
- (NSString *)kc_hexString;

/// will check if the argument is a real CGColor
+ (UIColor *)kc_colorWithCGColor:(CGColorRef)cgColor;

@end

NS_ASSUME_NONNULL_END
