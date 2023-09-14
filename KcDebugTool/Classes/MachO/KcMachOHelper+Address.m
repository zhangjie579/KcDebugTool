//
//  KcMachOHelper+Address.m
//  KcDebugTool
//
//  Created by 张杰 on 2021/7/10.
//

#import "KcMachOHelper+Address.h"
#import <objc/message.h>

@implementation KcMachOHelper (Address)

#pragma mark - 基地址

/// 主工程默认的基地址
+ (uintptr_t)mainProjectAefaultBaseAddress {
    return [self defaultBaseAddressWithImageName:self.mainExecutablePath.UTF8String];
}

/// 默认的基地址
+ (uintptr_t)defaultBaseAddressWithImageName:(const char *)imageName {
    if(imageName == NULL) {
        return 0;
    }
    
    const uint32_t imageCount = _dyld_image_count();

    uint32_t index = -1;
    
    for(uint32_t iImg = 0; iImg < imageCount; iImg++) {
        const char* name = _dyld_get_image_name(iImg);
        if(strcmp(name, imageName) == 0) {
            index = iImg;
            break;
        }
    }
    
    if (index == -1) {
        return 0;
    }
    
    return [self defaultBaseAddressWithIndex:index];
}

/// 默认基地址(一般情况下, 索引0: 映像是dyld库的映像, 主工程index: 1)
+ (uintptr_t)defaultBaseAddressWithIndex:(uint32_t)image_index {
    const kc_mach_header_t *header = (const kc_mach_header_t *)_dyld_get_image_header(image_index);
    
    uintptr_t cmdPtr = [self firstLoadCommandAfterHeader:header];
    
    if (cmdPtr == 0) {
        return 0;
    }
    
//    const kc_segment_command_t *segmentCmd = getsegbyname(SEG_TEXT);
    
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *loadCmd = (struct load_command *)cmdPtr;
        if (loadCmd->cmd == KC_SEGMENT_ARCH_DEPENDENT) {
            const kc_segment_command_t *segmentCmd = (kc_segment_command_t *)cmdPtr;
            if (strcmp(segmentCmd->segname, SEG_TEXT) == 0) {
                return (uintptr_t)segmentCmd->vmaddr;
            }
        }
        cmdPtr += loadCmd->cmdsize;
    }
    
    return 0;
}

/// 随机偏移量 slide = header - LC_SEGMENT_64(__TEXT).vmaddr
+ (uintptr_t)imageVmaddrSlideWithIndex:(uint32_t)image_index {
    uintptr_t defaultBaseAddress = [self defaultBaseAddressWithIndex:image_index];
    
    if (defaultBaseAddress == 0) {
        return 0;
    }
    
    uintptr_t header = (uintptr_t)_dyld_get_image_header(image_index);
    
    return header - defaultBaseAddress;
}

#pragma mark - 分析address

/// 求address地址在二进制库image的索引index
/// 思路: 遍历所有image镜像, 遍历每个镜像image的load command, 看address是否在load command区间内
+ (uint32_t)imageIndexContainingAddress:(const uintptr_t)address {
    const uint32_t imageCount = _dyld_image_count();
    const kc_mach_header_t *header = 0;
    
    // 1.遍历image
    for(uint32_t iImg = 0; iImg < imageCount; iImg++) {
        // 2.求出对应index的image的header
        header = (const kc_mach_header_t *)_dyld_get_image_header(iImg);
        if (header == NULL) {
            continue;
        }
        // Look for a segment command with this address within its range.
        // 3.由于address已经加了ALSR, 而获取的load command的地址没加ALSR, so address需要 - ALSR
        uintptr_t addressWSlide = address - (uintptr_t)_dyld_get_image_vmaddr_slide(iImg);
        
        // 4.获取第1个load command的地址
        uintptr_t cmdPtr = [self firstLoadCommandAfterHeader:header];
        if (cmdPtr == 0) {
            continue;
        }
        
        // 5.遍历load command, 看address是否在它们之间
        for (uint32_t iCmd = 0; iCmd < header->ncmds; iCmd++) {
            const struct load_command *loadCmd = (struct load_command*)cmdPtr;
            if (loadCmd->cmd == KC_SEGMENT_ARCH_DEPENDENT) {
                const kc_segment_command_t* segCmd = (kc_segment_command_t *)cmdPtr;
                if(addressWSlide >= segCmd->vmaddr &&
                   addressWSlide < segCmd->vmaddr + segCmd->vmsize) { // 是否在它们区间内
                    return iImg;
                }
            }
            
            cmdPtr += loadCmd->cmdsize; // next
        }
    }
    return UINT_MAX;
}

/// 获取地址为address的二进制镜像的信息Dl_info
/// 通常查询符号表，找到最佳匹配的address, 从而得到result
//bool ksdl_dladdr(const uintptr_t address, Dl_info* const info)
+ (BOOL)dladdr:(const uintptr_t)address info:(Dl_info *const)info {
    info->dli_fname = NULL;
    info->dli_fbase = NULL;
    info->dli_sname = NULL;
    info->dli_saddr = NULL;

    // 1.获取地址在二进制镜像中的index
    const uint32_t idx = [self imageIndexContainingAddress:address];
    if (idx == UINT_MAX) {
        return false;
    }
    
    // 2.求索引idx的镜像image的segment基地址
    const kc_mach_header_t *header = (const kc_mach_header_t *)_dyld_get_image_header(idx);
    const uintptr_t imageVMAddrSlide = (uintptr_t)_dyld_get_image_vmaddr_slide(idx);
    const uintptr_t addressWithSlide = address - imageVMAddrSlide;
    const uintptr_t segmentBase = [self segmentBaseOfImageIndex:idx] + imageVMAddrSlide;
    if (segmentBase == 0) {
        return false;
    }

    info->dli_fname = _dyld_get_image_name(idx);
    info->dli_fbase = (void*)header;

    // Find symbol tables and get whichever symbol is closest to the address.
    // 3.求第1个load command
    const kc_nlist_t* bestMatch = NULL;
    uintptr_t bestDistance = ULONG_MAX;
    uintptr_t cmdPtr = [self firstLoadCommandAfterHeader:header];
    if (cmdPtr == 0) {
        return false;
    }
    
    // 4.遍历load command, 求出符号表LC_SYMTAB
    for(uint32_t iCmd = 0; iCmd < header->ncmds; iCmd++) {
        const struct load_command* loadCmd = (struct load_command*)cmdPtr;
        // 4.1.符号表
        if (loadCmd->cmd == LC_SYMTAB) {
            const struct symtab_command* symtabCmd = (struct symtab_command*)cmdPtr;
            // 4.2.符号表section地址: LC_segment_64(_linkedit)的基地址 + load command(LC_symtab) 符号表的 symbol table offset
            const kc_nlist_t* symbolTable = (kc_nlist_t*)(segmentBase + symtabCmd->symoff);
            // 4.3.字符串表section地址: LC_segment_64(_linkedit)的基地址 + load command(LC_symtab) 符号表的 string table offset
            const uintptr_t stringTable = segmentBase + symtabCmd->stroff;

            // 5.遍历符号的个数
            for (uint32_t iSym = 0; iSym < symtabCmd->nsyms; iSym++) {
                // 5.1.If n_value is 0, the symbol refers to an external object. (n_value为0, 该符号是外部对象)
                if (symbolTable[iSym].n_value == 0) {
                    continue;
                }
                uintptr_t symbolBase = symbolTable[iSym].n_value;
                uintptr_t currentDistance = addressWithSlide - symbolBase;
                // 排布: symbolBase ... addressWithSlide 👻
                if((addressWithSlide >= symbolBase) && (currentDistance <= bestDistance)) {
                    bestMatch = symbolTable + iSym;
                    bestDistance = currentDistance;
                }
            }
            if (bestMatch != NULL) {
                // 地址 + ALSR
                info->dli_saddr = (void*)(bestMatch->n_value + imageVMAddrSlide);
                if (bestMatch->n_desc == 16) {
                    // This image has been stripped. The name is meaningless, and
                    // almost certainly resolves to "_mh_execute_header"
                    info->dli_sname = NULL;
                }
                else {
                    // 求符号名
                    info->dli_sname = (char*)((intptr_t)stringTable + (intptr_t)bestMatch->n_un.n_strx);
                    if (*info->dli_sname == '_') {
                        info->dli_sname++;
                    }
                }
                break;
            }
        }
        cmdPtr += loadCmd->cmdsize;
    }
    
    return true;
}

/// 根据地址查询出方法名
- (nullable NSString *)lookupWithAddress:(NSInteger)address {
    
    NSNumber *numberAddress = [NSNumber numberWithInteger:address];
    
    if (self.addressMethodNameDictionary != nil) {
        return self.addressMethodNameDictionary[numberAddress];
    }
    
    self.addressMethodNameDictionary = [[NSMutableDictionary alloc] init];
    
    unsigned int outCount = outCount;
    Class *classList = objc_copyClassList(&outCount);
    for (int k = 0; k < outCount; k++) {
        Class cls = classList[k];
        
//        if (!(Class)class_getSuperclass(cls)) {
//            continue;
//        }
        unsigned int methCount = 0;
        Method *methods = class_copyMethodList(cls, &methCount);
        for (int j = 0; j < methCount; j++) {
            Method meth = methods[j];
            uintptr_t implementation = (uintptr_t)method_getImplementation(meth);
            NSString *methodName = [NSString stringWithFormat:@"-[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(method_getName(meth))];
            self.addressMethodNameDictionary[@(implementation)] = methodName;
        }
        
        free(methods);
        methods = nil;
        
        unsigned int classMethCount = 0;
        
        Method *classMethods = class_copyMethodList(objc_getMetaClass(class_getName(cls)), &classMethCount);
        for (int j = 0; j < classMethCount; j++) {
            Method meth = classMethods[j];
            uintptr_t implementation = (uintptr_t)method_getImplementation(meth);
            NSString *methodName = [NSString stringWithFormat:@"+[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(method_getName(meth))];
            self.addressMethodNameDictionary[@(implementation)] = methodName;
        }
        
        free(classMethods);
        classMethods = nil;
    }
    
    free(classList);
    classList = nil;
    
    return self.addressMethodNameDictionary[numberAddress];
}

@end
