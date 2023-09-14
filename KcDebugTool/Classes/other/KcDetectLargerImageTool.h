//
//  KcDetectLargerImageTool.h
//  KcDebugTool
//
//  Created by 张杰 on 2021/11/3.
//  检测设置图片过大

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KcDetectLargerImageTool : NSObject

/// 过滤小图的size(比这个小直接过滤掉), 默认 1M
+ (void)filterSmallImageSize:(UInt64)imageSize;

+ (void)start;

+ (void)startWithImageInfoBlock:(NSString *_Nullable(*_Nullable)(UIImageView *))imageInfoBlock;

@end

NS_ASSUME_NONNULL_END
