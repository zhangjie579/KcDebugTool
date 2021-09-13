//
//  KcMachOHelper+ClassList.m
//  KcDebugTool
//
//  Created by 张杰 on 2021/6/27.
//

#import "KcMachOHelper+ClassList.h"
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/arch.h>
#import <mach-o/getsect.h>
#import <stdlib.h>
#import <string.h>
#import <sys/types.h>

@implementation KcMachOHelper (ClassList)

/// 与cls同一个bundle的class列表
+ (NSMutableArray<Class> *)bundleClassListWithClass:(Class)cls {
    NSMutableArray<Class> *classes = [[NSMutableArray alloc] init];
    unsigned int count;
    const char *imageName = class_getImageName(cls);
    Class *classList = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        Class currentCls = classList[i];
        if (strcmp(class_getImageName(currentCls), imageName) == 0) {
            [classes addObject:currentCls];
        }
    }
    free(classList);
    
    return classes;
}

/// 获取main bundle中的class
+ (NSMutableArray<Class> *)mainBundleClassList {
    NSMutableArray<Class> *classes = [[NSMutableArray alloc] init];
//    const char *mainBundleImageName = NSBundle.mainBundle.executablePath.UTF8String;
    
//    unsigned int count;
//    Class *classList = objc_copyClassList(&count);
//    for (unsigned int i = 0; i < count; i++) {
//        Class currentCls = classList[i];
//        if (strcmp(class_getImageName(currentCls), mainBundleImageName) == 0) {
//            [classes addObject:currentCls];
//        }
//    }
//    free(classList);
    
    // 0xfffffffffffffffe, UnsafeMutableRawPointer(bitPattern: -2)
    void *address = (void *)(UINT64_MAX - 1);
    void *symbol = dlsym(address, "main");
    Dl_info info;
    int result = dladdr(symbol, &info);
    
    if (result == 0) {
        return classes;
    }
    
    unsigned int count;
    Class *classList = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        Class currentCls = classList[i];
        if (strcmp(class_getImageName(currentCls), info.dli_fname) == 0) {
            [classes addObject:currentCls];
        }
    }
    free(classList);
    
    return classes;
}

/// 根据镜像name, 获取class list
+ (NSMutableArray<Class> *)bundleClassListWithImageName:(NSString *)imageName {
    NSMutableArray<Class> *classes = [[NSMutableArray alloc] init];
    unsigned int count;
    const char *cImageName = imageName.UTF8String;
    Class *classList = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        Class currentCls = classList[i];
        if (strcmp(class_getImageName(currentCls), cImageName) == 0) {
            [classes addObject:currentCls];
        }
    }
    free(classList);
    
    return classes;
}

/// 遍历镜像image
+ (void)enumerateClassesInImageWithBlock:(void(^)(const char *path))block {
    uint32_t count = _dyld_image_count();
    
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
//        NSString *imagePath = [NSString stringWithUTF8String:path];
        
        if (block) {
            block(path);
        }
    }
}

/// 遍历image的cls
+ (void)enumerateClassesInImageWithIncludeImages:(NSArray<NSString *> *)includeImages       block:(void(^)(NSString *className, Class _Nullable cls))block {
    BOOL(^blockInclude)(NSString *imagePath, NSArray<NSString *> *images) = ^BOOL(NSString *imagePath, NSArray<NSString *> *images) {
        for (NSString *image in images) {
            if ([imagePath containsString:image]) {
                return true;
            }
        }
        return false;
    };
    
    [self enumerateClassesInImageWithBlock:^(const char *path) {
        NSString *imagePath = [NSString stringWithUTF8String:path];
        
        if (!blockInclude(imagePath, includeImages)) {
            return;
        }
        
        [self enumerateClassForImage:path block:block];
        
    }];
}

/// 遍历image的class
+ (void)enumerateClassForImage:(const char *)image block:(void(^)(NSString *className, Class _Nullable cls))block {
    unsigned int count;
    const char **classNames = objc_copyClassNamesForImage(image, &count);
    for (NSInteger i = 0; i < count; i++) {
        NSString *className = [NSString stringWithCString:classNames[i] encoding:NSUTF8StringEncoding];
        Class cls = NSClassFromString(className);
        
        block(className, cls);
    }
    
    free(classNames);
}

/// 遍历MainBundle镜像的__objc_classlist
+ (void)enumerateClassesInMainBundleImageWithBlock:(void (^)(Class __unsafe_unretained aClass))handler {
    if (!handler) {
        return;
    }
    
    NSString *mainBundlePath = [NSBundle mainBundle].executablePath;
    for (uint32_t i = 0, count = _dyld_image_count(); i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        if (strcmp(path, mainBundlePath.UTF8String) == 0) {
            const kc_mach_header_t *mh = (const kc_mach_header_t *)_dyld_get_image_header(i);
            
            [self enumerateClassesInImageWithHeader:mh handle:handler];
        }
    }
}

/// 遍历镜像image的__objc_classlist
+ (void)enumerateClassesInImageWithHeader:(const kc_mach_header_t *)mh
                                   handle:(void (^)(Class __unsafe_unretained aClass))handler {
    if (mh == NULL || !handler) {
        return;
    }
    
//#ifndef __LP64__
//        const struct section *section = getsectbynamefromheader(mh, "__DATA", "__objc_classlist");
//        if (section == NULL) {
//            return;
//        }
//        uint32_t size = section->size;
//#else
//        const struct section_64 *section = getsectbynamefromheader_64(mh, "__DATA", "__objc_classlist");
//        if (section == NULL) {
//            return;
//        }
//        uint64_t size = section->size;
//#endif
    
    const kc_section_t *section = kc_getsectbynamefromheader_f(mh, "__DATA", "__objc_classlist");
    if (section == NULL) {
        return;
    }
    uint64_t size = section->size;
    
    if (size <= 0) {
        return;
    }
    
    char *imageBaseAddress = (char *)mh;
    Class *classReferences = (Class *)(void *)(imageBaseAddress + ((uintptr_t)section->offset&0xffffffff));
    
    for (unsigned long i = 0; i < size/sizeof(void *); i++) {
        Class aClass = classReferences[i];
        if (aClass) {
            handler(aClass);
        }
    }
}

@end

@implementation NSObject (KcMachO)

/// 所有自定义class
+ (NSMutableArray<Class> *)kc_allCustomClasses {
    return [self kc_allCustomClassesFromObjcClasslistWithFilterImagePath:nil filterClassName:nil];
}

/// 获取machO中__objc_classlist段内的class - 自定义class
+ (NSMutableArray<Class> *)kc_allCustomClassesFromObjcClasslistWithFilterImagePath:(BOOL(^ _Nullable)(NSString *imagePath))filterImagePath
                                                                   filterClassName:(BOOL(^ _Nullable)(NSString *imagePath))filterClassName {
    NSMutableArray<Class> *customClasses = [[NSMutableArray alloc] init];
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;

    unsigned long size = 0;
    unsigned int classCount = 0;
    void *data = [self kc_sectiondata:"__DATA"
                             sectname:"__objc_classlist"
                                 size:&size
                      filterImagePath:^BOOL(NSString *imagePath) {
        if (![imagePath containsString:bundlePath] ||
            [imagePath containsString:@".dylib"] ||
            [imagePath containsString:@"RevealServer"]) {
            return true;
        }
        return false;
    }];
    
    if (!data) {
        data = [self kc_sectiondata:"__DATA_CONST"
                           sectname:"__objc_classlist"
                               size:&size
                    filterImagePath:^BOOL(NSString *imagePath) {
            if (![imagePath containsString:bundlePath] ||
                [imagePath containsString:@".dylib"] ||
                [imagePath containsString:@"RevealServer"]) {
                return true;
            }
            return false;
        }];
    }
    
    BOOL isCopy = false;
    if (!data) {
        data = objc_copyClassList(&classCount);
        isCopy = true;
    } else {
        classCount = (unsigned int)(size / sizeof(void *));
    }
    
    Class *clsref = (Class *)data;
    
    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = clsref[i];
//        NSString *className = NSStringFromClass(cls);
//        NSString *imageName = [NSString stringWithUTF8String:class_getImageName(cls)];
        
        [customClasses addObject:cls];
    }
    
    if (isCopy) {
        free(data);
    }
    
    return customClasses;
}

/// 获取MachO段中的内容
+ (nullable void *)kc_sectiondata:(const char *)segname
                         sectname:(const char *)sectname
                             size:(size_t *)size
                  filterImagePath:(BOOL(^ _Nullable)(NSString *imagePath))filterImagePath {
    uint32_t imageCount = _dyld_image_count();

    for (uint32_t idx = 0; idx < imageCount; idx++) {
        const char *binaryName = _dyld_get_image_name(idx);
        NSString *imagePath = [NSString stringWithUTF8String:binaryName];
        
        if (filterImagePath) {
            if (filterImagePath(imagePath)) {
                continue;
            }
        }
        
        const kc_mach_header_t *header = (const kc_mach_header_t *)_dyld_get_image_header(idx);
        
        void *data = getsectiondata(header, segname, sectname, size);
        return data;
    }
    
    return nil;
}

/// 所有自定义class - objc_copyClassNamesForImage
/// @param filterImagePath 过滤image Path
/// @param filterClassName 过滤 className
+ (NSMutableArray<Class> *)kc_allCustomClassesForImageWithFilterImagePath:(BOOL(^ _Nullable)(NSString *imagePath))filterImagePath
                                                  filterClassName:(BOOL(^ _Nullable)(NSString *imagePath))filterClassName {
    NSMutableArray<Class> *customClasses = [[NSMutableArray alloc] init];
    int imageCount = (int)_dyld_image_count();
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    for(int iImg = 0; iImg < imageCount; iImg++) {
        const char *path = _dyld_get_image_name((unsigned)iImg);
        NSString *imagePath = [NSString stringWithUTF8String:path];
        
        if (![imagePath containsString:bundlePath] || [imagePath containsString:@".dylib"] || [imagePath containsString:@"RevealServer"]) {
            continue;
        }
        
        if (filterImagePath) {
            if (filterImagePath(imagePath)) {
                continue;
            }
        }
        
        unsigned int ldCount;
        const char **ldClasses = objc_copyClassNamesForImage(path, &ldCount);
        for (int i = 0; i < ldCount; i++) {
            NSString *className = [NSString stringWithCString:ldClasses[i] encoding:NSUTF8StringEncoding];
            if ([className hasPrefix:@"LDAssets"] || [className hasPrefix:@"UI"] || [className hasPrefix:@"NS"]) {
                continue;
            }
            if (filterClassName) {
                if (filterClassName(className)) {
                    continue;
                }
            }
            
            Class cls = NSClassFromString(className);
            if (!cls) {
                continue;
            }
            [customClasses addObject:cls];
        }
        free(ldClasses);
    }
    return customClasses;
}

@end
