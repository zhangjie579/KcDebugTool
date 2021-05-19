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
#import <stdlib.h>
#import <string.h>
#import <sys/types.h>

@implementation KcMachOHelper

static char includeObjcClasses[] = {"CN"};
static char objcClassPrefix[] = {"_OBJC_CLASS_$_"};

+ (const char *)imageNameWithClass:(Class)cls {
    return class_getImageName(cls);
}

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

/// 获取符号表的数据
+ (void)log_symbolTableWithImageName:(NSString *)imageName {
    void(^findSymbolTableFromMachO)(UInt32 i) = ^(UInt32 i) {
        kc_mach_header_t *header = (kc_mach_header_t *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        
        Dl_info info;
        if (dladdr(header, &info) == 0) {
            return;
        }
        
        kc_segment_command_t *cur_seg_cmd;
        kc_segment_command_t *linkedit_segment = NULL;
        struct symtab_command* symtab_cmd = NULL;
//        kc_segment_command_t * seg_text = NULL;
        
        // 1.找到符号表
        intptr_t cur = (uintptr_t)header + sizeof(kc_mach_header_t);
        for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
            cur_seg_cmd = (kc_segment_command_t *)cur;
            
            if (cur_seg_cmd->cmd == KC_SEGMENT_ARCH_DEPENDENT) {
                if (strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0) {
                    linkedit_segment = cur_seg_cmd;
                }
//                else if (strcmp(cur_seg_cmd->segname, SEG_TEXT) == 0) { // __TEXT
//                    seg_text = cur_seg_cmd;
//                }
            } else if (cur_seg_cmd->cmd == LC_SYMTAB) {
                symtab_cmd = (struct symtab_command*)cur_seg_cmd;
            }
        }
        
        // 等于 (uintptr_t)header
        uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
        kc_nlist_t *symtab = (kc_nlist_t *)(linkedit_base + symtab_cmd->symoff);
        char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
        
        for (UInt64 i = 0; i < symtab_cmd->nsyms; i++) {
            kc_nlist_t entries = symtab[i];
            // 因为symtab的地址 + slide, so 同MachOView一致, 这里 - slide
            UInt64 entriesAddress = (UInt64)symtab + sizeof(kc_nlist_t) * i - slide;
            
            char *symbol_name = strtab + entries.n_un.n_strx;
            /* 真实地址需要加slide⚠️
             比如:
             slide:             0x000000000854c000
             header:            0x000000010854c000
             symbol_address:    0x0000000100001280
             seg_text->vmaddr:  0x0000000100000000
             
             slide = header - seg_text->vmaddr
             */
            UInt64 symbol_address = entries.n_value;
            
            NSLog(@"name: %s, value: 0x%x, 真实符号地址: 0x%x element offset: 0x%x", symbol_name, symbol_address, symbol_address + slide, entriesAddress);
        }
    };
    
    uint32_t count = _dyld_image_count();
    
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        NSString *imagePath = [NSString stringWithUTF8String:path];

        if (![imagePath hasSuffix:imageName]) {
            continue;
        }
        
        findSymbolTableFromMachO(i);
    }
}

/// 查找swift符号
/// 原理: 遍历symbol table, 根据swift class name特定的特征
+ (void)findSwiftSymbolsWithBundlePath:(const char *)bundlePath
                                suffix:(const char *)suffix
                              callback:(void (^)(const void *symval, const char *symname, void *typeref, void *typeend))callback {
    // 1.遍历镜像image
    for (int32_t i = _dyld_image_count(); i >= 0 ; i--) {
        const char *imageName = _dyld_get_image_name(i);
        // 2.比较bundlePath
        if (!(imageName && (!bundlePath || imageName == bundlePath ||
                            strcmp(imageName, bundlePath) == 0)))
            continue;
        
        const kc_mach_header_t *header =
            (const kc_mach_header_t *)_dyld_get_image_header(i);
        kc_segment_command_t *seg_linkedit = NULL; // __LINKEDIT
        kc_segment_command_t *seg_text = NULL; // __TEXT
        struct symtab_command *symtab = NULL; // 符号表
        
        // 3.遍历__Text, __swift5_typeref 段
        // to filter associated type witness entries
        uint64_t typeref_size = 0;
        char *typeref_start = getsectdatafromheader_f(header, SEG_TEXT,
                                            "__swift5_typeref", &typeref_size);

        // 4.load_command = header + struct header size
        struct load_command *cmd =
            (struct load_command *)((intptr_t)header + sizeof(kc_mach_header_t));
        // 5.遍历load_command
        for (uint32_t i = 0; i < header->ncmds; i++,
             cmd = (struct load_command *)((intptr_t)cmd + cmd->cmdsize)) {
            switch(cmd->cmd) {
                case LC_SEGMENT:
                case LC_SEGMENT_64:
                    if (!strcmp(((kc_segment_command_t *)cmd)->segname, SEG_TEXT)) // __TEXT
                        seg_text = (kc_segment_command_t *)cmd;
                    else if (!strcmp(((kc_segment_command_t *)cmd)->segname, SEG_LINKEDIT)) // __LINKEDIT
                        seg_linkedit = (kc_segment_command_t *)cmd;
                    break;

                case LC_SYMTAB: { // 符号表
                    symtab = (struct symtab_command *)cmd;
                    intptr_t file_slide = ((intptr_t)seg_linkedit->vmaddr - (intptr_t)seg_text->vmaddr) - seg_linkedit->fileoff; // 这个还有不是 = 0的时候 ❓
                    // 字符串表
                    const char *strings = (const char *)header +
                                               (symtab->stroff + file_slide);
                    // 符号表
                    kc_nlist_t *sym = (kc_nlist_t *)((intptr_t)header +
                                               (symtab->symoff + file_slide));
                    
                    // ❓❓❓
                    size_t sufflen = strlen(suffix);
                    BOOL witnessFuncSearch = strcmp(suffix+sufflen-2, "Wl") == 0 ||
                                             strcmp(suffix+sufflen-5, "pACTK") == 0;
                    uint8_t symbolVisibility = witnessFuncSearch ? 0x1e : 0xf; // 符号可见性

                    for (uint32_t i = 0; i < symtab->nsyms; i++, sym++) {
                        // 符号name = 字符串表 + offset
                        const char *symname = strings + sym->n_un.n_strx;
                        void *address;

                        if (sym->n_type == symbolVisibility &&
                            ((strncmp(symname, "_$s", 3) == 0 && // 都以_$s开头
                              strcmp(symname+strlen(symname)-sufflen, suffix) == 0) ||
                             (suffix == includeObjcClasses && strncmp(symname,
                              objcClassPrefix, sizeof objcClassPrefix-1) == 0)) &&
                            (address = (void *)(sym->n_value +
                             (intptr_t)header - (intptr_t)seg_text->vmaddr))) {
                            // slide = (uintptr_t)header - (segment->vmaddr - segment->fileoff), 因为text段的fileoff = 0, so不需要 -
                            callback(address, symname+1, typeref_start,
                                     typeref_start + typeref_size);
                        }
                    }

                    if (bundlePath)
                        return;
                }
            }
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
