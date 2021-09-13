//
//  KcMachOHelper+ClassList.h
//  KcDebugTool
//
//  Created by 张杰 on 2021/6/27.
//  class 列表

#import <KcDebugTool/KcMachOHelper.h>

NS_ASSUME_NONNULL_BEGIN

@interface KcMachOHelper (ClassList)

/// 与cls同一个bundle的class列表
+ (NSMutableArray<Class> *)bundleClassListWithClass:(Class)cls;

/// 获取main bundle中的class
+ (NSMutableArray<Class> *)mainBundleClassList;

/// 根据镜像name, 获取class list
+ (NSMutableArray<Class> *)bundleClassListWithImageName:(NSString *)imageName;

/// 遍历镜像image
+ (void)enumerateClassesInImageWithBlock:(void(^)(const char *path))block;

/// 遍历image的cls, 动态库
+ (void)enumerateClassesInImageWithIncludeImages:(NSArray<NSString *> *)includeImages block:(void(^)(NSString *className, Class _Nullable cls))block;

/// 遍历image的class
+ (void)enumerateClassForImage:(const char *)image block:(void(^)(NSString *className, Class _Nullable cls))block;

/// 遍历MainBundle镜像的__objc_classlist
+ (void)enumerateClassesInMainBundleImageWithBlock:(void (^)(Class __unsafe_unretained aClass))handler;

/// 遍历镜像image的__objc_classlist
+ (void)enumerateClassesInImageWithHeader:(const kc_mach_header_t *)mh
                                   handle:(void (^)(Class __unsafe_unretained aClass))handler;

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
