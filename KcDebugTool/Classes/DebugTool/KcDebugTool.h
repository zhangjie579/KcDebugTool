//
//  KcDebugTool.h
//  test001
//
//  Created by samzjzhang on 2020/6/18.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "KcHookClassManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface KcDebugTool : NSObject

@end

//#pragma mark - 单例
//
//#define KcSingletonHeader(class) \
//    + (instancetype)shared##class
//
//#define KcSingletonIMP(class) \
//+ (instancetype)shared##class { \
//    static dispatch_once_t onceToken; \
//    static class *share; \
//    dispatch_once(&onceToken, ^{ \
//        share = [[class alloc] init]; \
//    }); \
//    return share; \
//}

NS_ASSUME_NONNULL_END
