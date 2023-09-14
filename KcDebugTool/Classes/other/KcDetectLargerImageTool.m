//
//  KcDetectLargerImageTool.m
//  KcDebugTool
//
//  Created by 张杰 on 2021/11/3.
//

#import "KcDetectLargerImageTool.h"
#import "KcHookTool.h"
#import <objc/message.h>
@import KcDebugSwift;

@implementation KcDetectLargerImageTool

static NSUInteger getImageMemoryLimit() {
    static NSUInteger imageMemoryLimit;
    
    if (imageMemoryLimit > 0) {
        return imageMemoryLimit;
    }
    
    imageMemoryLimit = 4 * 512 * 1024 * UIScreen.mainScreen.scale * UIScreen.mainScreen.scale;
    
    return imageMemoryLimit;
}

static UInt64 smallImageSize = 1 * 1024 * 1024;

/// 过滤小图的size(比这个小直接过滤掉), 默认 1M
+ (void)filterSmallImageSize:(UInt64)imageSize {
    smallImageSize = imageSize;
}

+ (void)start {
    [self startWithImageInfoBlock:nil];
}

static NSString *(*kc_imageInfoBlock)(UIImageView *);

+ (void)startWithImageInfoBlock:(NSString *(*)(UIImageView *))imageInfoBlock {
    KcHookTool *tool = [[KcHookTool alloc] init];

    if (imageInfoBlock && (intptr_t)imageInfoBlock != (intptr_t)_objc_msgForward) {
        kc_imageInfoBlock = imageInfoBlock;
    }
    
    
    // contents
//    [tool kc_hookWithObjc:CALayer.class selector:@selector(setContents:) withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
//        id __nullable contents = info.arguments.firstObject;
//        if (contents == nil || [contents isEqual:[NSNull null]]) {
//            return;
//        }
//
////        NSString *_Nullable className = NSStringFromClass(contents);
////        if (className && ([className isEqualToString:@"__NSCFType"] || [className hasPrefix:@"__"])) {
////            return;
////        }
//
//        UIImage * __nullable image = [UIImage imageWithCGImage:(__bridge CGImageRef _Nonnull)(contents)];
//        if (image == nil) {
//            return;
//        }
//
//        CALayer *layer = info.instance;
//        CGSize boxSize = layer.frame.size;
//        CGSize imageSize = CGSizeZero;
//
//        BOOL tooLarge = [self isTooLargeImageSizeWithImage:image boxSize:boxSize imageSize:&imageSize];
//
//        if (!tooLarge) {
//            return;
//        }
//
//        NSLog(@"------- ❎ 大图 ❎-------");
//        NSLog(@"🐶🐶🐶 imageView尺寸: %@, 图片尺寸: %@", NSStringFromCGSize(boxSize), NSStringFromCGSize(imageSize));
////            [imageView kc_debug_findPropertyName];
//        KcPropertyResult *_Nullable result = [KcFindPropertyTooler findResponderChainObjcPropertyNameWithObject:layer.delegate startSearchView:nil isLog:false];
//        if (result) {
//            NSLog(@"🐶🐶🐶 查找属性的属性名name: %@, 容器: %@", result.name, result.containClassName);
//        }
//        NSLog(@"------- ❎ 大图 ❎-------");
//
//    } error:nil];

    // animationImages 动画
    [tool kc_hookWithObjc:UIImageView.class selector:@selector(setAnimationImages:) withOptions:KcAspectTypeBefore usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        NSArray<UIImage *> * __nullable images = info.arguments.firstObject;
        if (![images isKindOfClass:[NSArray class]]) {
            return;
        }
        
        if (images.count <= 0) {
            return;
        }
        
        UIImageView *imageView = info.instance;
        CGSize imageViewSize = imageView.bounds.size;
        
        UIImage *firstImage = images.firstObject;
        CGSize imageSize = CGSizeZero;
        BOOL tooLarge = [self isTooLargeImageSizeWithImage:firstImage boxSize:imageViewSize imageSize:&imageSize];
        
        if (!tooLarge) {
            return;
        }
        
        NSLog(@"------- ❎ 大图 ❎-------");
        NSLog(@"🐶🐶🐶 采用animationImages动画⚠️ imageView: <%@: %p>, 尺寸: %@, 图片尺寸: %@, 图片内存: %0.3fM", NSStringFromClass(imageView.class), imageView, NSStringFromCGSize(imageViewSize), NSStringFromCGSize(firstImage.size), [self imageCost2:firstImage] / (1024.0 * 1024.0));
//            [imageView kc_debug_findPropertyName];
        KcPropertyResult *_Nullable result = [KcFindPropertyTooler findResponderChainObjcPropertyNameWithObject:imageView startSearchView:imageView.nextResponder isLog:false];
        if (result) {
            NSLog(@"🐶🐶🐶 查找属性的属性名name: %@, 容器: %@", result.name, result.containClassName);
        } else {
            NSLog(@"🐶🐶🐶 imageView: %@", imageView);
        }
        NSLog(@"------- ❎ 大图 ❎-------");
        
    } error:nil];
    
    // TODO: 这里有问题, 如果name是 xxx@3x.png 之类的, 获取的size, 系统会 / 对应的@nx, 否则不会
    [tool kc_hookWithObjc:UIImageView.class selector:@selector(setImage:) withOptions:KcAspectTypeAfter usingBlock:^(KcHookAspectInfo * _Nonnull info) {
        UIImage * __nullable image = info.arguments.firstObject;
        UIImageView *imageView = info.instance;
        CGSize imageViewSize = imageView.bounds.size;
        
        if ([imageView isKindOfClass:NSClassFromString(@"Gifu.GIFImageView")]) {
            return;
        }
        
        CGSize imageSize = CGSizeZero;
        BOOL tooLarge = [self isTooLargeImageSizeWithImage:image boxSize:imageViewSize imageSize:&imageSize];
        
        if (!tooLarge) {
            return;
        }
        
        NSString *imageNameInfo = @"";
        if (kc_imageInfoBlock) {
            NSString *imageName = kc_imageInfoBlock(imageView);
            if (imageName.length > 0) {
                imageNameInfo = [NSString stringWithFormat:@" imageInfo: %@,", imageName];
            }
        }
        
        NSLog(@"------- ❎ 大图 ❎-------");
        NSLog(@"🐶🐶🐶 imageView: <%@: %p>,%@ 尺寸: %@, 图片尺寸: %@, 图片内存: %0.3fM", NSStringFromClass(imageView.class), imageView, imageNameInfo, NSStringFromCGSize(imageViewSize), NSStringFromCGSize(image.size), [self imageCost2:image] / (1024.0 * 1024.0));
//            [imageView kc_debug_findPropertyName];
        KcPropertyResult *_Nullable result = [KcFindPropertyTooler findResponderChainObjcPropertyNameWithObject:imageView startSearchView:imageView.nextResponder isLog:false];
        if (result) {
            NSLog(@"🐶🐶🐶 查找属性的属性名name: %@, 容器: %@", result.name, result.containClassName);
        } else {
            NSLog(@"🐶🐶🐶 imageView: %@", imageView);
        }
        NSLog(@"------- ❎ 大图 ❎-------");
        
        
//        // swift设置为nil, 获取到的image为null类型
//        if (!image || [image isEqual:[NSNull null]]) {
//            return;
//        }
//
//        // 过滤过小的image size
//        CGSize filterImageSize = CGSizeMake(100, 100);
//        // 比例, image的尺寸超过imageView的这个尺寸就存在问题
//        CGFloat ratio = 1.5;
//
//
//        // 这里要处理分辨率
//        CGSize imageSize = CGSizeMake(image.size.width * image.scale / UIScreen.mainScreen.scale,
//                                      image.size.height * image.scale / UIScreen.mainScreen.scale);
//        CGSize imageViewSize = imageView.bounds.size;
//
//        if (imageViewSize.width <= 0 || imageViewSize.height <= 0) {
//            return;
//        }
//
//        // 图片过小直接过滤
//        if (imageSize.width < filterImageSize.width && imageSize.height < filterImageSize.width) {
//            return;
//        }
//
//        CGFloat widthRatio = imageSize.width / imageViewSize.width;
//        CGFloat heightRatio = imageSize.height / imageViewSize.height;
//
//        // 图片尺寸有问题
//        if ((widthRatio + heightRatio) * 0.5 >= ratio
//            || widthRatio * 0.5 >= ratio
//            || heightRatio * 0.5 >= ratio) {
//            NSLog(@"------- ❎ 大图 ❎-------");
//            NSLog(@"🐶🐶🐶 imageView尺寸: %@, 图片尺寸: %@", NSStringFromCGSize(imageViewSize), NSStringFromCGSize(imageSize));
////            [imageView kc_debug_findPropertyName];
//            KcPropertyResult *_Nullable result = [KcFindPropertyTooler findResponderChainObjcPropertyNameWithObject:imageView startSearchView:imageView.nextResponder isLog:false];
//            if (result) {
//                NSLog(@"🐶🐶🐶 查找属性的属性名name: %@, 容器: %@", result.name, result.containClassName);
//            }
//            NSLog(@"------- ❎ 大图 ❎-------");
//        }
    } error:nil];
}

// MARK: - help

/// 图片是否过大
/// - Parameters:
///   - image: 图片
///   - boxSize: 显示图片的view的size
///   - presentImageSize: imageSize
+ (BOOL)isTooLargeImageSizeWithImage:(nullable UIImage *)image boxSize:(CGSize)boxSize imageSize:(CGSize *)presentImageSize {
    // swift设置为nil, 获取到的image为null类型
    if (!image || [image isEqual:[NSNull null]]) {
        return false;
    }
    
    if ([self isLargeImageWithImage:image memoryLimit:getImageMemoryLimit()]) {
        return true;
    }
    
    NSUInteger imageMemory = [self imageCost2:image];
    // 1M 以下过滤掉
    if (imageMemory < smallImageSize) {
        return false;
    }
    
    // 过滤过小的image size
    CGSize filterImageSize = CGSizeMake(100, 100);
    // 比例, image的尺寸超过imageView的这个尺寸就存在问题
    CGFloat ratio = 1.5;
    
    // 这里要处理分辨率
//    CGSize imageSize = CGSizeMake(image.size.width * image.scale / UIScreen.mainScreen.scale,
//                                  image.size.height * image.scale / UIScreen.mainScreen.scale);
    CGSize imageSize = image.size;
    *presentImageSize = imageSize;
    
    if (boxSize.width <= 0 || boxSize.height <= 0) {
        return false;
    }
    
    // 图片过小直接过滤
    if (imageSize.width < filterImageSize.width && imageSize.height < filterImageSize.width) {
        return false;
    }
    
    CGFloat widthRatio = imageSize.width / boxSize.width;
    CGFloat heightRatio = imageSize.height / boxSize.height;
    
    // 图片尺寸有问题
    if ((widthRatio + heightRatio) * 0.5 >= ratio || widthRatio * 0.5 >= ratio || heightRatio * 0.5 >= ratio) {
        return true;
    }
    
    return false;
}

/// 是否是大图
+ (BOOL)isLargeImageWithImage:(nullable UIImage *)image memoryLimit:(NSInteger)memoryLimit {
    NSUInteger imageMemory = [self imageCost2:image];
    return imageMemory >= memoryLimit;
}

/// image所占内存
/// https://github.com/ibireme/YYWebImage/issues/89
/// https://www.jianshu.com/p/634c022cb560
+ (NSUInteger)imageCost2:(UIImage *)image {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage)
        return 1;
    
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    
    if (width <= 0 || height <= 0) {
        return 1;
    }
    
    CGFloat bytesPerPixel = 4.0;
    CGFloat bytesPerSize = width * height;
    CGFloat memory = (UInt64)bytesPerPixel * (UInt64)bytesPerSize;
    
    return memory;
}

+ (NSUInteger)imageCost:(UIImage *)image {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return 1;
    CGFloat height = CGImageGetHeight(cgImage);
    size_t bytesPerRow = CGImageGetBytesPerRow(cgImage);
    NSUInteger cost = bytesPerRow * height;
    if (cost == 0)
        cost = 1;
    return cost;
}

@end
