//
//  KcHookTool.h
//  test001-hook
//
//  Created by samzjzhang on 2020/7/16.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import <Foundation/Foundation.h>
@class KcHookAspectInfo;

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(NSUInteger, KcAspectType) {
    KcAspectTypeAfter   = 0,            /// Called after the original implementation (default)
    KcAspectTypeInstead = 1,            /// Will replace the original implementation.
    KcAspectTypeBefore  = 2,            /// Called before the original implementation.
    
    KcAspectTypeAutomaticRemoval = 1 << 3 /// Will remove the hook after the first execution.
};

@protocol KcAspectable <NSObject>

/// objc可以为对象、class
- (void)kc_hookWithObjc:(id)objc
               selector:(SEL)selector
            withOptions:(KcAspectType)options
             usingBlock:(void(^)(KcHookAspectInfo *info))block
                  error:(NSError **)error;

@end

@interface KcHookAspectInfo : NSObject

@property (nonatomic) id instance;
@property (nonatomic, copy) NSString *selectorName;

@property (nonatomic, nullable) NSArray *arguments;
@property (nonatomic, nullable) id aspectInfo;

- (nullable NSString *)className;

/// 过滤selectorName前缀
- (NSString *)selectorNameFilterPrefix;

/// 方法名 - 可能包含了aspects__前缀
- (SEL)selector;
/// 方法名 - 不包含aspects__前缀
- (SEL)originalSelector;
/// 过滤前缀
- (SEL)selectorFromName:(NSString *)selectorName;

@end

/// 管理切换hook实现的底层
@interface KcHookTool : NSObject <KcAspectable>

/// 如果想切换成其他的hook底层库, 只需要遵守KcAspectable, 切换manager方法的实现
+ (id<KcAspectable>)manager;

- (void)kc_hookWithClassName:(NSString *)className selectorName:(NSString *)selectorName withOptions:(KcAspectType)options usingBlock:(void (^)(KcHookAspectInfo * _Nonnull info))block;

- (void)kc_hookWithClassName:(NSString *)className selector:(SEL)selector withOptions:(KcAspectType)options usingBlock:(void (^)(KcHookAspectInfo * _Nonnull info))block;

- (void)kc_hookWithObjc:(id)objc selectorName:(NSString *)selectorName withOptions:(KcAspectType)options usingBlock:(void (^)(KcHookAspectInfo * _Nonnull info))block;

@end

NS_ASSUME_NONNULL_END
