//
//  KcHookModel.h
//  NowLive
//
//  Created by samzjzhang on 2020/4/24.
//  Copyright © 2020 now. All rights reserved.
//  泛型模型

#import <Foundation/Foundation.h>
@class KcHookAspectInfo;

NS_ASSUME_NONNULL_BEGIN

@interface KcHookModel<Key, Value> : NSObject

@property (nonatomic) Key key;
@property (nonatomic) Value value;

- (instancetype)initWithKey:(Key __nonnull)key value:(Value __nonnull)value;

@end

/// log model (注意⚠️：log time要用after, 因为要执行了origin invoke才知道)
@interface KcLogParamModel : NSObject

// --- isLog、isOnlyLogTimeout 2选1, isOnlyLogTimeoutMethod > isLog

/// 是否log
@property (nonatomic) BOOL       isLog;
/// 是否只log超时方法
@property (nonatomic) BOOL       isOnlyLogTimeoutMethod;
/// 超时
@property (nonatomic) double     timeout;

/// log函数执行时间(这样的话，堆栈就反过来了, 先log子方法最后才log最外层方法)
@property (nonatomic) BOOL       isLogExecuteTime;

// --- 下面2选1, isLogTarget > isLogClassName

/// 是否log对象
@property (nonatomic) BOOL       isLogTarget;
/// 是否log类名(父类和子类确定不了)
@property (nonatomic) BOOL       isLogClassName;

// --- 过滤高频

/// 过滤高频log
@property (nonatomic) BOOL filterHighFrequencyLog;
/// 频率间隔
@property (nonatomic) NSTimeInterval frequencyInterval;
/// 一段时间的次数
@property (nonatomic) NSInteger frequencyTime;

/// 自定义log的输出函数
+ (void)setInfoLogImpWithBlock:(void(^_Nullable)(NSString *))block beforeLogBlock:(void(^_Nullable)(NSString *))beforeLogBlock;

+ (void)logWithString:(NSString *)string;
+ (void)logWithKey:(NSString *)key format:(NSString *)format, ...;

/// 对象的描述
+ (NSString *)instanceDesc:(id)instance;
/// Swift对象描述
+ (NSString *)swiftInstanceDesc:(id)instance;

- (void)defaultLogWithInfo:(KcHookAspectInfo *)info;

/// 解析name
+ (NSString *)demangleNameWithName:(NSString *)name;

/// 解析name
+ (NSString *)demangleNameWithCString:(const char *)cstring;

/// 堆栈, 将swift符号 demangle了
+ (nullable NSString *)callStack;

@end

/// 方法hook参数
@interface KcMethodInfo : NSObject

/// 是否hook get方法
@property (nonatomic) BOOL       isHookGetMethod;
/// 是否hook set方法
@property (nonatomic) BOOL       isHookSetMethod;
/// 是否hook super class
@property (nonatomic) BOOL       isHookSuperClass;

/// 白名单
@property (nonatomic) NSArray<NSString *> * __nullable whiteSelectors;
/// 黑名单
@property (nonatomic) NSArray<NSString *> * __nullable blackSelectors;

/// 默认黑名单
+ (NSArray<NSString *> *)defaultBlackSelectorNames;

@end

/// hook参数model
@interface KcHookInfo : NSObject

@property (nonatomic) KcMethodInfo      *methodInfo;
@property (nonatomic) KcLogParamModel   *logModel;

+ (instancetype)makeDefaultInfo;

@end

NS_ASSUME_NONNULL_END
