//
//  KcMachOHelper+Address.h
//  KcDebugTool
//
//  Created by 张杰 on 2021/7/10.
//

#import <KcDebugTool/KcDebugTool.h>

NS_ASSUME_NONNULL_BEGIN

@interface KcMachOHelper (Address)

#pragma mark - 基地址

/// 主工程默认的基地址
+ (uintptr_t)mainProjectAefaultBaseAddress;

/// 默认的基地址
+ (uintptr_t)defaultBaseAddressWithImageName:(const char *)imageName;

/// 默认基地址(一般情况下, 索引0: 映像是dyld库的映像, 主工程index: 1)
+ (uintptr_t)defaultBaseAddressWithIndex:(uint32_t)image_index;

/// 随机偏移量 slide = header - LC_SEGMENT_64(__TEXT).vmaddr
+ (uintptr_t)imageVmaddrSlideWithIndex:(uint32_t)image_index;

#pragma mark - 分析address

/// 求address地址在二进制库image的索引index
/// 思路: 遍历所有image镜像, 遍历每个镜像image的load command, 看address是否在load command区间内
+ (uint32_t)imageIndexContainingAddress:(const uintptr_t)address;

@end

NS_ASSUME_NONNULL_END
