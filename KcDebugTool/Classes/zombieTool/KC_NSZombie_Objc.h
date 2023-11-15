//
//  KC_NSZombie_Objc.h
//  KcDebugTool
//
//  Created by 张杰 on 2023/9/18.
//  野指针的proxy类

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 野指针的proxy类
@interface KC_NSZombie_Objc : NSObject

/// 对象所需的size
+ (NSInteger)zombieInstanceSize;

@end

NS_ASSUME_NONNULL_END
