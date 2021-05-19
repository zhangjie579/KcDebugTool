//
//  KcMachO.m
//  KcDebugTool_Example
//
//  Created by 张杰 on 2021/5/11.
//  Copyright © 2021 张杰. All rights reserved.
//

#import "KcMachO.h"
#import "KcMachOHelper.h"
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/types.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach-o/arch.h>
#import <mach-o/getsect.h>

#import <objc/message.h>

//#ifdef __LP64__
//typedef struct mach_header_64 kc_mach_header_t;
//typedef struct segment_command_64 kc_segment_command_t;
//typedef struct section_64 kc_section_t;
//typedef struct nlist_64 kc_nlist_t;
//#define KC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
//#else
//typedef struct mach_header kc_mach_header_t;
//typedef struct segment_command kc_segment_command_t;
//typedef struct section kc_section_t;
//typedef struct nlist kc_nlist_t;
//#define KC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
//#endif

@implementation KcMachO

#pragma mark - 遍历section

+ (void)log_sectionDataWithImageName:(NSString *)imageName {
    void(^findSection)(UInt32 imageIndex) = ^(UInt32 imageIndex) {
        kc_mach_header_t *header = _dyld_get_image_header(imageIndex);
        intptr_t slide = _dyld_get_image_vmaddr_slide(imageIndex);
        
        Dl_info info;
        if (dladdr(header, &info) == 0) {
            return;
        }
        
        kc_segment_command_t *cur_seg_cmd;
        kc_segment_command_t *linkedit_segment = NULL;
        kc_segment_command_t *text_segment = NULL;
        kc_segment_command_t *data_segment = NULL;
        
        intptr_t cur = (uintptr_t)header + sizeof(kc_mach_header_t);
        for (uint32_t i = 0 ; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
            cur_seg_cmd = (kc_segment_command_t *)cur;
            
            if (cur_seg_cmd->cmd == KC_SEGMENT_ARCH_DEPENDENT) {
                if (strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0) {
                    linkedit_segment = cur_seg_cmd;
                } else if (strcmp(cur_seg_cmd->segname, SEG_TEXT) == 0) {
                    text_segment = cur_seg_cmd;
                } else if (strcmp(cur_seg_cmd->segname, SEG_DATA) == 0) {
                    data_segment = cur_seg_cmd;
                }
            }
        }
        
        intptr_t base = slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
        [self log_sectionData:text_segment data_segment:data_segment header:header slide:slide];
    };
    
    
    uint32_t count = _dyld_image_count();
    
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        NSString *imagePath = [NSString stringWithUTF8String:path];

        if (![imagePath hasSuffix:imageName]) {
            continue;
        }
        
        findSection(i);
    }
}

+ (void)log_sectionData:(kc_segment_command_t *)text_segment
           data_segment:(kc_segment_command_t *)data_segment
                 header:(kc_mach_header_t *)header
                  slide:(intptr_t)slide {
    intptr_t cur = (intptr_t)text_segment + sizeof(kc_segment_command_t);
    kc_section_t *cur_section;
    
    for (NSInteger i = 0; i < text_segment->nsects; i++, cur += sizeof(kc_section_t)) {
        cur_section = (kc_section_t *)cur;
        
        NSLog(@"Section64(%s, %s)", text_segment->segname, cur_section->sectname);
        
        if (strcmp(cur_section->sectname, SECT_TEXT) == 0) {
            kc_section_t *text_section = cur_section;
        } else if (strcmp(cur_section->sectname, "__objc_classname__TEXT") == 0) {
            kc_section_t *classname = cur_section;
            UInt32 offset = classname->offset;
            uint64_t size = classname->size;
            // 基地址
            unsigned long long vm = classname->addr - classname->offset;
            
            // 根据偏移量, 求出对应section的data数据
            uint64_t start = (uint64_t)header + offset;
            
//            uint64_t endName = *(uint64_t *)(start + size);
            
//            char *name = &endName;
            
            // 由于string不是规则排列, 不知道如何读
            for (uint64_t i = 0; i < (size - 1) / 16 + 1; i++) {
                uint64_t address1 = *(uint64_t *)start;
                uint64_t address2 = *(uint64_t *)(start + 4);
                uint64_t address3 = *(uint64_t *)(start + 8);
                uint64_t address4 = *(uint64_t *)(start + 12);
                
                char *name = (char *)start;
                
//                NSLog(@"%x, %x, %x, %x, %s", address1, address2, address3, address4, name);
                
                start += 16;
            }
            
        } else if (strcmp(cur_section->sectname, "__objc_methname") == 0) {
            kc_section_t *classname = cur_section;
        }
    }
    
    NSLog(@" -------------- ");
    
    char *buffer = (char *)calloc(74, sizeof(char));
    
    
    // data
    cur = (intptr_t)data_segment + sizeof(kc_segment_command_t);
    for (NSInteger i = 0; i < data_segment->nsects; i++, cur += sizeof(kc_section_t)) {
        cur_section = (kc_section_t *)cur;
        
        uint64_t addr = cur_section->addr;
        uint64_t size = cur_section->size;
        uint32_t offset = cur_section->offset;
        
        // 基地址
        uint64_t vm = addr - offset;
        
        // 开始偏移量
        uint64_t start = (uint64_t)header + offset;
        
        
        NSLog(@"Section64(%s, %s)", cur_section->segname, cur_section->sectname);
        
        if (strcmp(cur_section->sectname, "__nl_symbol_ptr") == 0) {
            for (uint64_t i = 0; i < (size - 1) / 8 + 1; i++) {
                uint64_t data = *(uint64_t *)start;
                
                void *address = (void *)start;
                
                NSLog(@"offset: %x, data: %x, value: %p", start - (uint64_t)header, data, address);
                
                start += 8;
            }
        } else if (strcmp(cur_section->sectname, "__got") == 0) {
            
        } else if (strcmp(cur_section->sectname, "__la_symbol_ptr") == 0) {
            
        } else if (strcmp(cur_section->sectname, "__objc_classlist__DATA") == 0) {
            
            for (uint64_t i = 0; i < (size - 1) / 8 + 1; i++) {
                uint64_t address = *(uint64_t *)start;
                void *cls_address = (void *)start;
                
                Class cls = (__bridge Class)cls_address;
                
                NSLog(@"offset: %x, data: %x, value:%@", start - (uint64_t)header, address, cls);
                
                start += 8;
            }
            
        } else if (strcmp(cur_section->sectname, "__objc_protolist__DATA") == 0) {
            for (uint64_t i = 0; i < (size - 1) / 8 + 1; i++) {
                uint64_t address = *(uint64_t *)start;
                
                void *pro = (void *)start;
                
                NSLog(@"offset: %x, data: %x, value: %p", start - (uint64_t)header, address, pro);
                
                start += 8;
            }
        } else if (strcmp(cur_section->sectname, "__objc_selrefs") == 0) {
            for (uint64_t i = 0; i < (size - 1) / 8 + 1; i++) {
                uint64_t address = *(uint64_t *)start;
                
                
//                NSLog(@"offset: %x, data: %x, value: %@", start - (uint64_t)header, address, NSStringFromSelector(selector));
                
                start += 8;
            }
        } else if (strcmp(cur_section->sectname, "__objc_classrefs__DATA") == 0) {
//            for (uint64_t i = 0; i < (size - 1) / 8 + 1; i++) {
//                uint64_t address = *(uint64_t *)start;
//
//                Class cls = (__bridge Class)((void *)start);
//
//                NSLog(@"offset: %x, data: %x, value: %@", start - (uint64_t)header, address, cls);
//
//                start += 8;
//            }
        } else if (strcmp(cur_section->sectname, "__objc_ivar") == 0) {
            
        } else if (strcmp(cur_section->sectname, "__const") == 0) {
            
        } else if (strcmp(cur_section->sectname, "__objc_const") == 0) {
            
        } else if (strcmp(cur_section->sectname, "__objc_data") == 0) {
            
        } else if (strcmp(cur_section->sectname, "__data") == 0) {
            
        }
    }
}

@end
