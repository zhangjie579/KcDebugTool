//
//  KcMachOHelper+swiftTool.m
//  KcDebugTool
//
//  Created by 张杰 on 2021/6/27.
//

#import "KcMachOHelper+swiftTool.h"
#import <objc/message.h>
#import <mach-o/arch.h>
#import <stdlib.h>
#import <string.h>
#import <sys/types.h>

static char includeObjcClasses[] = {"CN"};
static char objcClassPrefix[] = {"_OBJC_CLASS_$_"};

@implementation KcMachOHelper (swiftTool)

/// 查找swift符号
/// 原理: 遍历symbol table, 根据swift class name特定的特征
+ (void)findSwiftSymbolsWithBundlePath:(const char *)bundlePath
                                suffix:(const char *)suffix // "CN"
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

+ (void)findSwiftClassesWithBundlePath:(const char *)bundlePath
                              callback:(void(^)(Class cls))callback {
    if (!callback) {
        return;
    }
    
    UInt32 count = _dyld_image_count();
    for (UInt32 i = 0; i < count; i++) {
        const kc_mach_header_t *header = (const kc_mach_header_t *)_dyld_get_image_header(i);
        const char *imageName = _dyld_get_image_name(i);
        
        BOOL isEqual = imageName && (imageName == bundlePath || strcmp(imageName, bundlePath) == 0);
        if (!isEqual) {
            continue;
        }
        
        [self findSwiftClassesWithHeader:header callback:callback];
    }
}

+ (void)findSwiftClassesWithHeader:(const kc_mach_header_t *)header
                          callback:(void(^)(Class cls))callback {
    /// 获取swift class
    void *(^getSwiftClass)(kc_segment_command_t *seg_text, kc_nlist_t *sym, const char *sptr) = ^(kc_segment_command_t *seg_text, kc_nlist_t *sym, const char *sptr) {
        void *aClass;
        if (sym->n_type == 0xf &&
            strncmp(sptr, "_$s", 3) == 0 &&
            strcmp(sptr+strlen(sptr)-2, "CN") == 0 &&
            // n_value + slide, slide = (uintptr_t)header - (segment->vmaddr - segment->fileoff), 因为text段的fileoff = 0, so不需要 -
            (aClass = (void *)(sym->n_value + (intptr_t)header - (intptr_t)seg_text->vmaddr))) {
            return aClass;
        }
        return nil;
    };
    
    kc_segment_command_t *seg_linkedit = NULL;
    kc_segment_command_t *seg_text = NULL;
    struct symtab_command *symtab = NULL;
    
    struct load_command *cmd = (struct load_command *)((intptr_t)header + sizeof(kc_mach_header_t));
    
    for (uint32_t j = 0; j < header->ncmds; j++, cmd = (struct load_command *)((intptr_t)cmd + cmd->cmdsize)) {
        switch (cmd->cmd) {
            case LC_SEGMENT:
            case LC_SEGMENT_64:
                if (!strcmp(((kc_segment_command_t *)cmd)->segname, SEG_TEXT))
                    seg_text = (kc_segment_command_t *)cmd;
                else if (!strcmp(((kc_segment_command_t *)cmd)->segname, SEG_LINKEDIT))
                    seg_linkedit = (kc_segment_command_t *)cmd;
                break;
            case LC_SYMTAB: {
                symtab = (struct symtab_command *)cmd;
                intptr_t file_slide = ((intptr_t)seg_linkedit->vmaddr - (intptr_t)seg_text->vmaddr) - seg_linkedit->fileoff;
                const char *strings = (const char *)header + (symtab->stroff + file_slide);
                kc_nlist_t *sym = (kc_nlist_t *)((intptr_t)header + (symtab->symoff + file_slide));

                for (uint32_t i = 0; i < symtab->nsyms; i++, sym++) {
                    const char *sptr = strings + sym->n_un.n_strx;
                    void *aClass = getSwiftClass(seg_text, sym, sptr);
                    if (!aClass) {
                        continue;
                    }
                    callback((__bridge Class)(aClass));
                }
            }
        }
    }
}


@end
