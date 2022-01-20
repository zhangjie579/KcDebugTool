//
//  KcSymbolInfo.h
//  KcDebugTool
//
//  Created by 张杰 on 2021/6/27.
//  符号信息

#import <Foundation/Foundation.h>
#import "KcMachOHelper.h"

NS_ASSUME_NONNULL_BEGIN

@interface KcSymbolInfo : NSObject

@property (nonatomic) kc_nlist_t symbol;

@end

/// 镜像信息
@interface KcDylibInfo : NSObject

@property (nonatomic) int imageIndex;
@property (nonatomic) intptr_t vmaddr_slide;

@property (nonatomic) const kc_mach_header_t *header;
@property (nonatomic) kc_segment_command_t *seg_linkedit;
@property (nonatomic) kc_segment_command_t *seg_text;
@property (nonatomic) struct symtab_command *symtab;
@property (nonatomic) kc_nlist_t *symbols;

/// 开始地址
@property (nonatomic) intptr_t startAddress;
/// 结束地址
@property (nonatomic) intptr_t endAddress;

@property (nonatomic, readonly) NSMutableArray<KcSymbolInfo *> *symbolInfos;

@property (nonatomic) void *textSectionStart;
@property (nonatomic) void *textSectionStop;
@property (nonatomic) const char *imageName;

- (instancetype)initWithImageIndex:(int)imageIndex;

/// 是否包含
- (BOOL)containWithAddress:(const void *)address;

/// 是否包含在text section
- (BOOL)containTextSectionWithAddress:(const void *)address;

/// 根据地址解析符号信息
- (int)dladdrWithPtr:(const void *)ptr info:(Dl_info *)info;

/// 解析
- (BOOL)dladdr:(const void *)ptr info:(Dl_info *)info;

/// 字符串表
- (const char *)stringTable;

/// 符号表
- (kc_nlist_t *)symbolTable;

@end

@interface KcDylibManager : NSObject

@property (nonatomic, readonly) NSMutableArray<KcDylibInfo *> *dylibInfos;

/// imageName 白名单(如果为空的话, 全部处理)
@property (nonatomic) NSMutableArray<NSString *> *whiteImageNames;

+ (instancetype)shared;

- (void)start;

/// 根据地址解析符号信息
- (int)dladdrWithPtr:(const void *)ptr info:(Dl_info *)info;

@end

NS_ASSUME_NONNULL_END
