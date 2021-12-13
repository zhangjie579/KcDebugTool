//
//  KcDetectLargerImageTool.m
//  KcDebugTool
//
//  Created by 张杰 on 2021/11/3.
//

#import "KcDetectLargerImageTool.h"
#import "KcHookTool.h"
@import KcDebugSwift;

@implementation KcDetectLargerImageTool

+ (void)start {
    KcHookTool *tool = [[KcHookTool alloc] init];
    
    // TODO: 这里有问题, 如果name是 xxx@3x.png 之类的, 获取的size, 系统会 / 对应的@nx, 否则不会
    [tool kc_hookWithObjc:UIImageView.class selector:@selector(setImage:) withOptions:KcAspectTypeAfter usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        UIImage * __nullable image = info.arguments.firstObject;
        // swift设置为nil, 获取到的image为null类型
        if (!image || [image isEqual:[NSNull null]]) {
            return;
        }
        
        // 过滤过小的image size
        CGSize filterImageSize = CGSizeMake(100, 100);
        // 比例, image的尺寸超过imageView的这个尺寸就存在问题
        CGFloat ratio = 1.5;
        
        UIImageView *imageView = info.instance;
        // 这里要处理分辨率
        CGSize imageSize = CGSizeMake(image.size.width * image.scale / UIScreen.mainScreen.scale,
                                      image.size.height * image.scale / UIScreen.mainScreen.scale);
        CGSize imageViewSize = imageView.bounds.size;
        
        if (imageViewSize.width <= 0 || imageViewSize.height <= 0) {
            return;
        }
        
        // 图片过小直接过滤
        if (imageSize.width < filterImageSize.width && imageSize.height < filterImageSize.width) {
            return;
        }
        
        CGFloat widthRatio = imageSize.width / imageViewSize.width;
        CGFloat heightRatio = imageSize.height / imageViewSize.height;
        
        // 图片尺寸有问题
        if ((widthRatio + heightRatio) * 0.5 >= ratio
            || widthRatio * 0.5 >= ratio
            || heightRatio * 0.5 >= ratio) {
            NSLog(@"------- ❎ 大图 ❎-------");
            NSLog(@"🐶🐶🐶 imageView尺寸: %@, 图片尺寸: %@", NSStringFromCGSize(imageViewSize), NSStringFromCGSize(imageSize));
//            [imageView kc_debug_findPropertyName];
            KcPropertyResult *_Nullable result = [KcFindPropertyTooler findResponderChainObjcPropertyNameWithObject:imageView startSearchView:imageView.nextResponder isLog:false];
            if (result) {
                NSLog(@"🐶🐶🐶 查找属性的属性名name: %@, 容器: %@", result.name, result.containClassName);
            }
            NSLog(@"------- ❎ 大图 ❎-------");
        }
    } error:nil];
}

@end
