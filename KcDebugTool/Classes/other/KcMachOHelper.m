//
//  KcMachOHelper.m
//  OCTest
//
//  Created by samzjzhang on 2020/11/18.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "KcMachOHelper.h"
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/arch.h>
#import <mach-o/getsect.h>

@implementation KcMachOHelper

+ (const char *)imageNameWithClass:(Class)cls {
    return class_getImageName(cls);
}

+ (void)enumerateClassesInImageWithBlock:(void(^)(const char *path))block {
    uint32_t count = _dyld_image_count();
    
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        NSString *imagePath = [NSString stringWithUTF8String:path];
        
        if (block) {
            block(path);
        }
    }
}

/// 遍历image的cls
+ (void)enumerateClassesInImageWithIncludeImages:(NSArray<NSString *> *)includeImages block:(void(^)(NSString *className, Class _Nullable cls))block {
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

//BOOL zix_canEnumerateClassesInImage() {
//    if (canReadSuperclassOfClass([NSObject class]) == NO) {
//        return NO;
//    }
//    NSString *mainBundlePath = [NSBundle mainBundle].executablePath;
//    for (uint32_t i = 0, count = _dyld_image_count(); i < count; i++) {
//        const char *path = _dyld_get_image_name(i);
//        if (strcmp(path, mainBundlePath.UTF8String) == 0) {
//            const mach_header_xx *mh = (const mach_header_xx *)_dyld_get_image_header(i);
//#ifndef __LP64__
//            const struct section *section = getsectbynamefromheader(mh, "__DATA", "__objc_classlist");
//            if (section == NULL) {
//                return NO;
//            }
//            uint32_t size = section->size;
//#else
//            const struct section_64 *section = getsectbynamefromheader_64(mh, "__DATA", "__objc_classlist");
//            if (section == NULL) {
//                return NO;
//            }
//            uint64_t size = section->size;
//#endif
//            if (size > 0) {
//                char *imageBaseAddress = (char *)mh;
//                Class *classReferences = (Class *)(void *)(imageBaseAddress + ((uintptr_t)section->offset&0xffffffff));
//                Class firstClass = classReferences[0];
//                if (canReadSuperclassOfClass(firstClass) == NO) {
//                    return NO;
//                }
//            }
//            break;
//        }
//    }
//    return YES;
//}

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
+ (NSDictionary<NSString *, id> *)dyldImageInfo {
    NSMutableArray *dyldImages = @[].mutableCopy;

    // 1.遍历镜像image
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header *header = (const struct mach_header *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i); // ASTR 随机偏移
        int64_t imageBaseAddr = (uint64_t)header;

        NSString *uuidStr = [self uuidWithBinaryImageHeader:header];
        NSDictionary *image_info = @{
            @"uuid" : uuidStr ?: @"",
            @"base_addr" : [NSString stringWithFormat:@"0x%llx", imageBaseAddr],
            @"addr_slide" : [NSString stringWithFormat:@"0x%lx", slide],
            @"name" : [NSString stringWithUTF8String:name],
        };
        [dyldImages addObject:image_info];
    }

    NSString *version = nil;
    const NXArchInfo *info = NXGetLocalArchInfo();
    NSString *typeOfCpu = [NSString stringWithUTF8String:info->description];
    NSString *executableName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
    NSString *model = nil;

#if TARGET_OS_IOS || TARGET_OS_WATCH || TARGET_OS_TV
    version = [[UIDevice currentDevice] systemVersion];
    model = [[UIDevice currentDevice] valueForKey:@"buildVersion"];
#else

#endif

    NSDictionary<NSString *, id> *infos = @{
        @"os_version" : version ?: @"",
        @"arch" : typeOfCpu ?: @"",
        @"model" : model ?: @"",
        @"name" : executableName ?: @"",
        @"dyld_images" : dyldImages ?: @""
    };
    
    return infos;
}

/// 获取uuid: const mach_header *header = (const mach_header *)_dyld_get_image_header(i);
+ (NSString *)uuidWithBinaryImageHeader:(const void *)header {
    struct uuid_command uuid = {0};
    char uuidstr[64] = {0};
    [self processBinaryImageWithHeader:header out_uuid:&uuid];
    for (int i = 0; i < 16; i++)
        sprintf(&uuidstr[2 * i], "%02x", uuid.uuid[i]);

    NSString *uuidStr = [NSString stringWithCString:uuidstr encoding:NSASCIIStringEncoding];
    
    return uuidStr;
}

/* 获取uuid
 const mach_header *header = (const mach_header *)_dyld_get_image_header(i);
 
 struct uuid_command uuid = {0};
 char uuidstr[64] = {0};
 process_binary_image(header, &uuid);
 for (int i = 0; i < 16; i++)
     sprintf(&uuidstr[2 * i], "%02x", uuid.uuid[i]);

 NSString *uuidStr = [NSString stringWithCString:uuidstr encoding:NSASCIIStringEncoding];
 */
+ (void)processBinaryImageWithHeader:(const void *)header out_uuid:(struct uuid_command *)out_uuid {
    uint32_t ncmds;
    const struct mach_header *header32 = (const struct mach_header *)header;
    const struct mach_header_64 *header64 = (const struct mach_header_64 *)header;

    struct load_command *cmd;

    /* Check for 32-bit/64-bit header and extract required values */
    switch (header32->magic) {
            /* 32-bit */
        case MH_MAGIC:
        case MH_CIGAM:
            ncmds = header32->ncmds;
            cmd = (struct load_command *)(header32 + 1);
            break;

            /* 64-bit */
        case MH_MAGIC_64:
        case MH_CIGAM_64:
            ncmds = header64->ncmds;
            cmd = (struct load_command *)(header64 + 1);
            break;

        default:
            NSLog(@"Invalid Mach-O header magic value: %x", header32->magic);
            return;
    }

    /* Compute the image size and search for a UUID */
    struct uuid_command *uuid = NULL;

    for (uint32_t i = 0; cmd != NULL && i < ncmds; i++) {
        /* DWARF dSYM UUID */
        if (cmd->cmd == LC_UUID && cmd->cmdsize == sizeof(struct uuid_command))
            uuid = (struct uuid_command *)cmd;

        cmd = (struct load_command *)((uint8_t *)cmd + cmd->cmdsize);
    }

    if (out_uuid && uuid)
        memcpy(out_uuid, uuid, sizeof(struct uuid_command));
}

/// 获取所有全局对象 - 全局对象存储在 Mach-O 文件的 __DATA segment __bss section
//+ (NSArray<NSObject *> *)globalObjects {
//    NSMutableArray<NSObject *> *objectArray = [NSMutableArray array];
//    uint32_t count = _dyld_image_count();
//    for (uint32_t i = 0; i < count; i++) {
//        const struct mach_header *header = (const struct mach_header*)_dyld_get_image_header(i);
//    // 过滤需要检测的image
//    // ...
//
//        // 获取image偏移量
//        vm_address_t slide = _dyld_get_image_vmaddr_slide(i);
//        long offset = (long)header + sizeof(const struct mach_header);
//        for (uint32_t i = 0; i < header->ncmds; i++) {
//            const struct segment_command *segment = (const struct segment_command *)offset;
//            // 获取__DATA.__bss section的数据，即静态内存分配区
//            if (segment->cmd != SEGMENT_CMD_TYPE || strncmp(segment->segname, "__DATA", 6) != 0) {
//                offset += segment->cmdsize;
//                continue;
//            }
//            struct section *section = (struct section *)((char *)segment + sizeof(struct segment_command));
//            for (uint32_t j = 0; j < segment->nsects; j++) {
//        // 过滤section
//        // ...
//                const uint32_t align_size = sizeof(void *);
//                if (align_size <= size) {
//                    uint8_t *ptr_addr = (uint8_t *)begin;
//                    for (uint64_t addr = begin; addr < end && ((end - addr) >= align_size); addr += align_size, ptr_addr += align_size) {
//                        vm_address_t *dest_ptr = (vm_address_t *)ptr_addr;
//                        uintptr_t pointee = (uintptr_t)(*dest_ptr);
//                        // 省略判断指针是否指向OC对象的代码
//                        // ...
//                        // [objectArray addObject:(NSObject *)pointee];
//                    }
//                }
//            }
//            offset += segment->cmdsize;
//        }
//        // ...
//    }
//    return objectArray;
//}

@end

@implementation NSObject (KcMachO)

#ifdef __LP64__
typedef struct mach_header_64 kc_macho_header;
#else
typedef struct mach_header kc_macho_header;
#endif

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
        
        const kc_macho_header *header = (const kc_macho_header *)_dyld_get_image_header(idx);
        
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
