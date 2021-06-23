//
//  UIDevice+KcDebugTool.h
//  KcDebugTool
//
//  Created by 张杰 on 2021/6/18.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface UIDevice (KcDebugTool)

/// 是否是模拟器
+ (BOOL)isSimulator;

/// 架构类型
+ (NSString *)getArch;

@end

NS_ASSUME_NONNULL_END
