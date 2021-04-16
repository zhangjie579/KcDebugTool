//
//  KcMachOHelper.h
//  OCTest
//
//  Created by samzjzhang on 2020/11/18.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface KcMachOHelper : NSObject

+ (const char *)imageNameWithClass:(Class)cls;

+ (void)enumerateClassesInImageWithBlock:(void(^)(const char *path))block;

/// 遍历image的cls, 动态库
+ (void)enumerateClassesInImageWithIncludeImages:(NSArray<NSString *> *)includeImages block:(void(^)(NSString *className, Class _Nullable cls))block;

/// 遍历image的class
+ (void)enumerateClassForImage:(const char *)image block:(void(^)(NSString *className, Class _Nullable cls))block;

/// 获取uuid: const mach_header *header = (const mach_header *)_dyld_get_image_header(i);
+ (NSString *)uuidWithBinaryImageHeader:(const void *)header;

/* 获取镜像的信息
 @{
     @"os_version" : version,
     @"arch" : typeOfCpu,
     @"model" : model,
     @"name" : executableName,
     @"dyld_images" : [
         @{
             @"uuid" : uuidStr,
             @"base_addr" : ,
             @"addr_slide" : ,
             @"name" : ,
         }
     ]
 }
 */
+ (NSDictionary<NSString *, id> *)dyldImageInfo;

@end

@interface NSObject (KcMachO)

/// 所有自定义class
+ (NSMutableArray<Class> *)kc_allCustomClasses;
/// 获取machO中__objc_classlist段内的class - 自定义class
+ (NSMutableArray<Class> *)kc_allCustomClassesFromObjcClasslistWithFilterImagePath:(BOOL(^ _Nullable)(NSString *imagePath))filterImagePath filterClassName:(BOOL(^ _Nullable)(NSString *imagePath))filterClassName;

/// 所有自定义class - objc_copyClassNamesForImage
/// @param filterImagePath 过滤image Path
/// @param filterClassName 过滤 className
+ (NSMutableArray<Class> *)kc_allCustomClassesForImageWithFilterImagePath:(BOOL(^ _Nullable)(NSString *imagePath))filterImagePath
                                                          filterClassName:(BOOL(^ _Nullable)(NSString *imagePath))filterClassName;

/// 获取MachO段中的内容
+ (nullable void *)kc_sectiondata:(const char *)segname
                         sectname:(const char *)sectname
                             size:(size_t *)size
                  filterImagePath:(BOOL(^ _Nullable)(NSString *imagePath))filterImagePath;

@end

NS_ASSUME_NONNULL_END
