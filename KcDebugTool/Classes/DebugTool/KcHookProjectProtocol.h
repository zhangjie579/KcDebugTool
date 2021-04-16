//
//  KcHookProjectProtocol.h
//  OCTest
//
//  Created by samzjzhang on 2020/10/21.
//  Copyright © 2020 samzjzhang. All rights reserved.
//  hook协议 - 为了替换底层hook的工具

#ifndef KcHookProjectProtocol_h
#define KcHookProjectProtocol_h

#import "NSObject+KcMethodExtension.h"
#import "KcHookTool.h"

@protocol KcHookProjectProtocol <NSObject>

/// 立即开始
+ (void)start;
/// 延迟开始
+ (void)startDelay;

@end

#endif /* KcHookProjectProtocol_h */
