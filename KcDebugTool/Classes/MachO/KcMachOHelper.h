//
//  KcMachOHelper.h
//  OCTest
//
//  Created by samzjzhang on 2020/11/18.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#import <mach-o/nlist.h>
#import <dlfcn.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __LP64__
typedef struct mach_header_64 kc_mach_header_t;
typedef struct segment_command_64 kc_segment_command_t;
typedef struct section_64 kc_section_t;
typedef struct nlist_64 kc_nlist_t;
#define KC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#define getsectdatafromheader_f getsectdatafromheader_64
#define kc_getsectbynamefromheader_f getsectbynamefromheader_64
#else
typedef struct mach_header kc_mach_header_t;
typedef struct segment_command kc_segment_command_t;
typedef struct section kc_section_t;
typedef struct nlist kc_nlist_t;
#define KC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#define getsectdatafromheader_f getsectdatafromheader
#define kc_getsectbynamefromheader_f getsectbynamefromheader
#endif

@interface KcMachOHelper : NSObject

/// 地址 : 方法
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *addressMethodNameDictionary;

+ (instancetype)sharedInstance;

+ (const char *)imageNameWithClass:(Class)cls;

/// 是否是自定义的image
+ (BOOL)isCustomDefinedImage:(const char *)imageName;

/// 主工程可执行文件name
+ (NSString *)mainBundleExecutableName;
/// 主工程可执行文件路径
+ (NSString *)mainExecutablePath;

/// header后面的第一个load command的地址
+ (uintptr_t)firstLoadCommandAfterHeader:(const kc_mach_header_t* const)header;

/// 求索引idx的镜像image的segment基地址 (未加slide)
/// 对应MachOView: load commands -> LC_segment_64(_LINKEDIT)
+ (uintptr_t)segmentBaseOfImageIndex:(const uint32_t)imageIndex;

/// 查找名称为imageName的已加载二进制镜像
+ (uint32_t)indexOfImageNamed:(const char* const)imageName exactMatch:(BOOL)exactMatch;

/// 获取imageUUID
+ (NSString *)imageUUID:(const char * const)imageName exactMatch:(BOOL)exactMatch;

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

/// machO的基础信息
+ (void)machOBaseInfoWithBlock:(void(^)(UInt32 imageIndex,
                                    const char *imagePath,
                                    intptr_t slide,
                                    kc_mach_header_t *header,
                                    kc_segment_command_t *linkedit_segment,
                                    struct symtab_command* symtab_cmd))block;

/// 打印字符串表
/// string table 字符串之间用\0分割 (因为类型为char *, c的字符串就是用\0分割的)
+ (void)log_stringTableWithImageName:(NSString *)imageName;

/// 获取符号表的数据
/// /// [KcMachOHelper log_symbolTableWithImageName:@"KcDebugTool_Example"];
+ (void)log_symbolTableWithImageName:(NSString *)imageName;

/// 获取所有全局对象 - 全局对象存储在 Mach-O 文件的 __DATA segment __bss section
+ (NSArray<NSObject *> *)globalObjects;

@end

NS_ASSUME_NONNULL_END
