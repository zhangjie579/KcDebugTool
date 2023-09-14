//
//  KcLLDBGlobalHelper.h
//  Pods
//
//  Created by 张杰 on 2023/9/6.
//  lldb帮助类, lldb不好创建对象和方法, 通过这种方式简化script方式的代码

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KcLLDBGlobalHelper : NSObject

/// 地址 : 方法
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *addressMethodNameDictionary;

+ (instancetype)sharedInstance;

/// 根据地址查询出方法名
- (NSArray<NSString *> *)lookupWithAddresses:(NSArray<NSNumber *> *)addresses;

/// 根据地址查询出方法名
- (nullable NSString *)lookupWithAddress:(NSInteger)address;

@end

NS_ASSUME_NONNULL_END
