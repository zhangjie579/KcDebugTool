//
//  KcCheckUIManager.h
//  KcDebugTool
//
//  Created by 张杰 on 2025/5/29.
//  检查UI的问题

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 检查UI
@interface KcCheckUIManager : NSObject

+ (instancetype)sharedManager;

/// 检查frame对不对
- (void)check_frame_with_white_class_names:(nullable NSArray<NSString *> *)whiteClassNames whiteClasses:(nullable NSArray<Class> *)whiteClasses;

/// 检查 translatesAutoresizingMaskIntoConstraints 对不对
- (void)check_translatesAutoresizingMaskIntoConstraints;

@end

NS_ASSUME_NONNULL_END
