//
//  UIDevice+KcDebugTool.m
//  KcDebugTool
//
//  Created by 张杰 on 2021/6/18.
//

#import "UIDevice+KcDebugTool.h"
#include <mach/mach_host.h>
#import <sys/utsname.h>

@implementation UIDevice (KcDebugTool)

/// 是否是模拟器
+ (BOOL)isSimulator {
    return ![[self getArch] hasPrefix:@"arm"];
}

/// 架构类型
+ (NSString *)getArch {
    host_basic_info_data_t hostInfo;
    mach_port_msgcount_t infoCount;
    NSString *arch = @"";
    
    infoCount = HOST_BASIC_INFO_COUNT;
    host_info(mach_host_self(), HOST_BASIC_INFO, (host_info_t)&hostInfo, &infoCount);
    switch (hostInfo.cpu_type) {
        case CPU_TYPE_ARM:
        {
            arch = @"arm";
            break;
        }
        case CPU_TYPE_ARM64:
            arch = @"arm64";
            break;
        case CPU_TYPE_X86: {
            if (hostInfo.cpu_subtype == CPU_SUBTYPE_X86_64_H) {
                arch = @"x86_64";
            } else {
                arch = @"i386";
            }
            break;
        }
        case CPU_TYPE_X86_64:
            arch = @"x86_64";
            break;
            
        default:
            break;
    }
    return arch;
}

+ (nullable NSString *)kc_bundleName {
    NSString *_Nullable appName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"];
    if (!appName) {
        return nil;
    }
    
    appName = [appName stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    appName = [appName stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    
    return appName;
}

@end
