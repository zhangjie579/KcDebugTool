//
//  KcSymbolInfo.m
//  KcDebugTool
//
//  Created by 张杰 on 2021/6/27.
//

#import "KcSymbolInfo.h"
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/arch.h>
#import <mach-o/getsect.h>
#import <stdlib.h>
//#import <string.h>
#import <sys/types.h>

#pragma mark - KcDylibInfo

@interface KcDylibInfo ()

@property (nonatomic, readwrite) NSMutableArray<KcSymbolInfo *> *symbolInfos;

@end

@implementation KcDylibInfo

- (instancetype)initWithImageIndex:(int)imageIndex {
    if (self = [super init]) {
        self.imageIndex = imageIndex;
        self.imageName = _dyld_get_image_name(imageIndex);
        self.header = (const kc_mach_header_t *)_dyld_get_image_header(imageIndex);
        [self handleLoadCommand];
        [self computerTextSectionStartAndEnd];
        
        self.symbols = [self symbolTable];
    }
    return self;
}

/// 是否包含
- (BOOL)containWithAddress:(const void *)address {
    return address >= (const void *)self.start && address <= (const void *)self.stop;
}

/// 根据地址解析符号信息
- (int)dladdrWithPtr:(const void *)ptr info:(Dl_info *)info {
    const char *strings = self.stringTable;
    
    if (self.symbolInfos.count <= 0) {
        kc_nlist_t *sym = self.symbols;
        for (uint32_t i = 0; i < self.symtab->nsyms; i++, sym++) {
            if (sym->n_type == 0xf) { // _objc_class_$_viewController 这种符号类型为0xf
                KcSymbolInfo *info = [[KcSymbolInfo alloc] init];
                info.symbol = sym;
                [self.symbolInfos addObject:info];
            }
        }
    }
    
    intptr_t value = (intptr_t)ptr - ((intptr_t)self.header - (intptr_t)self.seg_text->vmaddr);
    
    for (KcSymbolInfo *symbolInfo in self.symbolInfos) {
        if (symbolInfo.symbol->n_value == value) {
            info->dli_fname = self.imageName;
            info->dli_fbase = (void *)self.header;
            info->dli_sname = strings + symbolInfo.symbol->n_un.n_strx + 1;
            
            return 1;
        }
    }
    
    return 0;
}

/// 字符串表
- (const char *)stringTable {
    intptr_t file_slide = (intptr_t)self.seg_linkedit->vmaddr - self.seg_linkedit->fileoff - (intptr_t)self.seg_text->vmaddr;
    return (const char *)((intptr_t)self.header + self.symtab->stroff + file_slide);
}

/// 符号表
- (kc_nlist_t *)symbolTable {
//    uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
//    nlist_t *symtab = (nlist_t *)(linkedit_base + symtab_cmd->symoff);
    intptr_t file_slide = (intptr_t)self.seg_linkedit->vmaddr - self.seg_linkedit->fileoff - (intptr_t)self.seg_text->vmaddr;
    return (kc_nlist_t *)((intptr_t)self.header + self.symtab->symoff + file_slide);
}

#pragma mark - private

/// 处理load command
- (void)handleLoadCommand {
    struct load_command *cmd = (struct load_command *)((intptr_t)self.header + sizeof(kc_mach_header_t));
    for (int i = 0; i < self.header->ncmds; i++, cmd = (struct load_command *)((intptr_t)cmd + cmd->cmdsize)) {
        switch(cmd->cmd) {
            case LC_SEGMENT:
            case LC_SEGMENT_64:
                if (!strcmp(((kc_segment_command_t *)cmd)->segname, SEG_TEXT))
                    self.seg_text = (kc_segment_command_t *)cmd;
                else if (!strcmp(((kc_segment_command_t *)cmd)->segname, SEG_LINKEDIT))
                    self.seg_linkedit = (kc_segment_command_t *)cmd;
                break;

            case LC_SYMTAB:
                self.symtab = (struct symtab_command *)cmd;
        }
    }
}

/// 计算text段的开始、结束
- (void)computerTextSectionStartAndEnd {
    const kc_section_t *section = (const kc_section_t *)kc_getsectbynamefromheader_f(self.header, SEG_TEXT, SECT_TEXT);
    if (section == 0) {
        return;
    }
    self.start = (void *)(section->addr + _dyld_get_image_vmaddr_slide(self.imageIndex));
    self.stop = (void *)((intptr_t)self.start + section->size);
}

- (NSMutableArray<KcSymbolInfo *> *)symbolInfos {
    if (!_symbolInfos) {
        _symbolInfos = [[NSMutableArray alloc] init];
    }
    return _symbolInfos;
}

@end

@interface KcDylibManager ()

@property (nonatomic, readwrite) NSMutableArray<KcDylibInfo *> *dylibInfos;

@end

@implementation KcDylibManager

+ (instancetype)shared {
    static dispatch_once_t onceToken;
    static KcDylibManager *manager;
    dispatch_once(&onceToken, ^{
        manager = [[KcDylibManager alloc] init];
    });
    
    return manager;
}

- (void)start {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        KcDylibInfo *infos = [[KcDylibInfo alloc] initWithImageIndex:i];
        [self.dylibInfos addObject:infos];
    }
}

/// 根据地址解析符号信息
- (int)dladdrWithPtr:(const void *)ptr info:(Dl_info *)info {
    if (self.dylibInfos.count <= 0) {
        [self start];
    }
    
    for (KcDylibInfo *dylibInfo in self.dylibInfos) {
        if (![dylibInfo containWithAddress:ptr]) {
            continue;
        }
        
        [dylibInfo dladdrWithPtr:ptr info:info];
        return 1;
    }
    
    return 0;
}

- (NSMutableArray<KcDylibInfo *> *)dylibInfos {
    if (!_dylibInfos) {
        _dylibInfos = [[NSMutableArray alloc] init];
    }
    return _dylibInfos;
}

@end

@implementation KcSymbolInfo

@end

