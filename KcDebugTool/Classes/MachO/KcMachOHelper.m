//
//  KcMachOHelper.m
//  OCTest
//
//  Created by samzjzhang on 2020/11/18.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "KcMachOHelper.h"
#import "NSObject+KcRuntimeExtension.h"
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/arch.h>
#import <mach-o/getsect.h>
#import <stdlib.h>
#import <string.h>
#import <sys/types.h>

@implementation KcMachOHelper

+ (const char *)imageNameWithClass:(Class)cls {
    return class_getImageName(cls);
}

/// 是否是自定义的image
+ (BOOL)isCustomDefinedImage:(const char *)imageName {
    return !strstr(imageName, "/Xcode.app/") &&
        !strstr(imageName, "/Library/PrivateFrameworks/") &&
        !strstr(imageName, "/System/Library/") &&
        !strstr(imageName, "/usr/lib/");
}

/// 主工程可执行文件name
+ (NSString *)mainBundleExecutableName {
    return NSBundle.mainBundle.infoDictionary[@"CFBundleExecutable"];
}

/// 主工程可执行文件路径
+ (NSString *)mainExecutablePath {
    return NSBundle.mainBundle.executablePath;
}

/// header后面的第一个load command的地址
+ (uintptr_t)firstLoadCommandAfterHeader:(const kc_mach_header_t* const)header {
    switch(header->magic) {
        case MH_MAGIC:
        case MH_CIGAM:
            return (uintptr_t)(header + 1);
        case MH_MAGIC_64:
        case MH_CIGAM_64:
            return (uintptr_t)(((struct mach_header_64*)header) + 1);
        default:
            // Header is corrupt
            return 0;
    }
}

/// 求索引idx的镜像image的segment基地址 (未加slide)
/// 对应MachOView: load commands -> LC_segment_64(_LINKEDIT)
+ (uintptr_t)segmentBaseOfImageIndex:(const uint32_t)imageIndex {
    const kc_mach_header_t *header = (const kc_mach_header_t *)_dyld_get_image_header(imageIndex);
    
    uintptr_t cmdPtr = [self firstLoadCommandAfterHeader:header];
    if (cmdPtr == 0) {
        return 0;
    }
    
    for (uint32_t i = 0; header->ncmds; i++) {
        const struct load_command* loadCmd = (struct load_command*)cmdPtr;
        if (loadCmd->cmd == KC_SEGMENT_ARCH_DEPENDENT) {
            const kc_segment_command_t *segmentCmd = (kc_segment_command_t *)cmdPtr;
            // 求为SEG_LINKEDIT的segname
            if(strcmp(segmentCmd->segname, SEG_LINKEDIT) == 0) {
                return segmentCmd->vmaddr - segmentCmd->fileoff;
            }
        }
        cmdPtr += loadCmd->cmdsize;
    }
    
    return 0;
}

/// 查找名称为imageName的已加载二进制镜像
+ (uint32_t)indexOfImageNamed:(const char* const)imageName exactMatch:(BOOL)exactMatch {
    if(imageName == NULL) {
        return UINT32_MAX;
    }
    
    const uint32_t imageCount = _dyld_image_count();

    for(uint32_t iImg = 0; iImg < imageCount; iImg++) {
        const char* name = _dyld_get_image_name(iImg);
        if (exactMatch) {
            if(strcmp(name, imageName) == 0) {
                return iImg;
            }
        } else {
            if(strstr(name, imageName) != NULL) {
                return iImg;
            }
        }
    }
    
    return UINT32_MAX;
}

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

/// 获取imageUUID
+ (NSString *)imageUUID:(const char * const)imageName exactMatch:(BOOL)exactMatch {
    if (imageName == NULL) {
        return NULL;
    }
    
    const uint32_t iImg = [self indexOfImageNamed:imageName exactMatch:exactMatch];
    if (iImg == UINT32_MAX) {
        return NULL;
    }
    
    const kc_mach_header_t *header = (const kc_mach_header_t *)_dyld_get_image_header(iImg);
    if (header == NULL) {
        return NULL;
    }
    
    uintptr_t cmdPtr = [self firstLoadCommandAfterHeader:header];
    if (cmdPtr == 0) {
        return NULL;
    }
    
    for(uint32_t iCmd = 0;iCmd < header->ncmds; iCmd++) {
        const struct load_command* loadCmd = (struct load_command*)cmdPtr;
        if(loadCmd->cmd == LC_UUID) {
            struct uuid_command* uuidCmd = (struct uuid_command*)cmdPtr;
//            return uuidCmd->uuid;
            return [NSString stringWithCString:uuidCmd->uuid encoding:NSASCIIStringEncoding];
        }
        cmdPtr += loadCmd->cmdsize;
    }
    
    return NULL;
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

/// machO的基础信息
+ (void)machOBaseInfoWithBlock:(void(^)(UInt32 imageIndex,
                                    const char *imagePath,
                                    intptr_t slide,
                                    kc_mach_header_t *header,
                                    kc_segment_command_t *linkedit_segment,
                                    struct symtab_command* symtab_cmd))block {
    uint32_t count = _dyld_image_count();
    
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
//        NSString *imagePath = [NSString stringWithUTF8String:path];
        
        kc_mach_header_t *header = (kc_mach_header_t *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        
        Dl_info info;
        if (dladdr(header, &info) == 0) {
            return;
        }
        
        kc_segment_command_t *cur_seg_cmd;
        kc_segment_command_t *linkedit_segment = NULL;
        struct symtab_command* symtab_cmd = NULL;
        
        intptr_t cur = (uintptr_t)header + sizeof(kc_mach_header_t);
        for (uint j = 0; j < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
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
        
        if (block) {
            block(i, path, slide, header, linkedit_segment, symtab_cmd);
        }
    }
}

/// 打印字符串表
/// string table 字符串之间用\0分割 (因为类型为char *, c的字符串就是用\0分割的)
+ (void)log_stringTableWithImageName:(NSString *)imageName {
    [self machOBaseInfoWithBlock:^(UInt32 imageIndex, const char *imagePath, intptr_t slide, kc_mach_header_t *header, kc_segment_command_t *linkedit_segment, struct symtab_command *symtab_cmd) {
        if (![@(imagePath) hasSuffix:imageName]) {
            return;
        }
        
        uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
        
        char *strTable = (char *)(linkedit_base + symtab_cmd->stroff);
        
        uint32_t nextSymbolNameOffset = 0;
        while (nextSymbolNameOffset < symtab_cmd->strsize) {
            char *name = strTable + nextSymbolNameOffset;
            size_t length = strlen(name);
            if (length > 0 && strcmp(name, " ") == 0) {
                NSLog(@"符号name: %s", name);
            }
            nextSymbolNameOffset += length + 1;
        }
    }];
}

/// 获取符号表的数据
/// [KcMachOHelper log_symbolTableWithImageName:@"KcDebugTool_Example"];
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
        kc_segment_command_t * seg_text = NULL;
        
        // 1.找到符号表
        intptr_t cur = (uintptr_t)header + sizeof(kc_mach_header_t);
        for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
            cur_seg_cmd = (kc_segment_command_t *)cur;
            
            if (cur_seg_cmd->cmd == KC_SEGMENT_ARCH_DEPENDENT) {
                if (strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0) {
                    linkedit_segment = cur_seg_cmd;
                }
                else if (strcmp(cur_seg_cmd->segname, SEG_TEXT) == 0) { // __TEXT
                    seg_text = cur_seg_cmd;
                }
            } else if (cur_seg_cmd->cmd == LC_SYMTAB) {
                symtab_cmd = (struct symtab_command*)cur_seg_cmd;
            }
        }
        
        // 等于 (uintptr_t)header
        uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
        kc_nlist_t *symtab = (kc_nlist_t *)(linkedit_base + symtab_cmd->symoff);
        char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
        
        // 0x1 0000 0000
        uintptr_t simulateBaseAddress = seg_text->vmaddr - seg_text->fileoff;
        
        for (UInt64 i = 0; i < symtab_cmd->nsyms; i++) {
            kc_nlist_t entries = symtab[i];
            // 符号表中的偏移量offset
            // 因为symtab的地址 + slide, so 同MachOView一致, 这里 - slide
            UInt64 entriesAddress = (UInt64)symtab - slide + sizeof(kc_nlist_t) * i;
            
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
            
            // 符号的真实地址
            uintptr_t symbol_real_address = symbol_address + slide;
            
            // 测试动态调用方法👻
//            if (strcmp(symbol_name, "+[KCViewController kc_test]") == 0) {
//                void(*imp)(id, SEL) = (void(*)(id, SEL))symbol_real_address;
//                imp(NSClassFromString(@"KCViewController"), NSSelectorFromString(@"kc_test"));
//            }
            
            // 用%llx, 会加上simulateBaseAddress的值(0x1 + 8个0)
            NSLog(@"name: %s, value: 0x%llx, 真实符号地址: 0x%lx element offset: 0x%llx",
                  symbol_name,
                  symbol_address,
                  symbol_real_address - simulateBaseAddress,
                  entriesAddress - simulateBaseAddress);
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

#pragma mark - 全局对象

/// 获取所有全局对象 - 全局对象存储在 Mach-O 文件的 __DATA segment __bss section
/// 因为定义objc的全局对象: static UIView *test1; 不能定义的时候初始化, so在未初始化中即__bss
/// 这个只适用于objc
/// swift的全局数据是存放在: __DATA,__common, 不管是否初始化、是否是对象、是否全局还是static. 问题: 不知道如何获取偏移量, 不知道如何判断是否是swift对象
+ (NSArray<NSObject *> *)globalObjects {
    NSMutableArray<NSObject *> *objectArray = [NSMutableArray array];

    // 1.class列表
    unsigned int classCount;
    Class *allClasses = objc_copyClassList(&classCount);

    // 2.遍历镜像
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const kc_mach_header_t *header = (const kc_mach_header_t*)_dyld_get_image_header(i);

        // 2.1.截取最后一段作为image_name，只针对QQNews进行处理
        const char *image_name = strrchr(_dyld_get_image_name(i), '/');
        if (image_name) {
            image_name = image_name + 1;
        }

        // 2.2.仅检测主APP
        NSBundle* mainBundle = [NSBundle mainBundle];
        NSDictionary* infoDict = [mainBundle infoDictionary];
        NSString* executableName = infoDict[@"CFBundleExecutable"];
        if (strncmp(image_name, executableName.UTF8String, executableName.length) != 0) {
            continue;
        }

        // 2.3.获取image偏移量
        vm_address_t slide = _dyld_get_image_vmaddr_slide(i);
        long offset = (long)header + sizeof(kc_mach_header_t);
        for (uint32_t i = 0; i < header->ncmds; i++) {
            const kc_segment_command_t *segment = (const kc_segment_command_t *)offset;
            // 获取__DATA.__bss section的数据，即静态内存分配区
            if (segment->cmd != KC_SEGMENT_ARCH_DEPENDENT || strncmp(segment->segname, "__DATA", 6) != 0) {
                offset += segment->cmdsize;
                continue;
            }
            kc_section_t *section = (kc_section_t *)((char *)segment + sizeof(kc_segment_command_t));
            for (uint32_t j = 0; j < segment->nsects; j++) {
                if ((strncmp(section->sectname, "__bss", 5) != 0)) {
                    section = (kc_section_t *)((char *)section + sizeof(kc_section_t));
                    continue;
                }
                // 遍历获取所有全局对象
                vm_address_t begin = (vm_address_t)section->addr + slide;
                vm_size_t size = (vm_size_t)section->size;
                vm_size_t end = begin + size;
                section = (kc_section_t *)((char *)section + sizeof(kc_section_t));

                const uint32_t align_size = sizeof(void *);
                if (align_size <= size) {
//                    uint8_t *ptr_addr = (uint8_t *)begin;
//                    for (uint64_t addr = begin; addr < end && ((end - addr) >= align_size); addr += align_size, ptr_addr += align_size) {
//                        vm_address_t *dest_ptr = (vm_address_t *)ptr_addr;
//                        uintptr_t pointee = (uintptr_t)(*dest_ptr);
//                        // 判断pointee指向的内容是否为OC的NSObject对象
//                        if (isObjcObject((void *)pointee, allClasses, classCount)) {
//                            [objectArray addObject:(NSObject *)pointee];
//                        }
//                    }
                    
                    for (uint64_t addr = begin; addr < end && ((end - addr) >= align_size); addr += align_size) {
                        vm_address_t *dest_ptr = (vm_address_t *)addr;
                        // 获取这个地址保存的值
                        uintptr_t pointee = (uintptr_t)(*dest_ptr);
                        // 判断pointee指向的内容是否为OC的NSObject对象
                        if ([NSObject kc_isObjcObject:(void *)pointee allClasses:allClasses classCount:classCount]) {
                            [objectArray addObject:(__bridge NSObject *)(void *)pointee];
                        }
                    }
                }
            }
            offset += segment->cmdsize;
        }
        // 仅针对主APP image执行一次，执行完直接break
        break;
    }
    free(allClasses);
    return objectArray;
}

@end

