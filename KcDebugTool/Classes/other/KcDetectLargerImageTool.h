//
//  KcDetectLargerImageTool.h
//  KcDebugTool
//
//  Created by 张杰 on 2021/11/3.
//  检测设置图片过大

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KcDetectLargerImageTool : NSObject

+ (void)start;

+ (void)startWithImageInfoBlock:(NSString *(*)(UIImageView *))imageInfoBlock;

@end

NS_ASSUME_NONNULL_END
