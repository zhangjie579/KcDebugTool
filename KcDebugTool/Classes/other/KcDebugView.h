//
//  KcDebugView.h
//  OCTest
//
//  Created by samzjzhang on 2020/6/16.
//  Copyright © 2020 samzjzhang. All rights reserved.
//  debug的view

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/*
 使用场景
 1.override view property, 监听property的改变, 比如frame
    * 虽然也可以通过KVO监听, but KVO看不到调用的位置
 */
@interface KcDebugView : UIView

@end

/// 监听KVO - 可以用单例作为监听者, 也可以不用
@interface KcDebugKVOTool : NSObject

@property (nonatomic) void(^blockObserver)(NSString *keyPath, id object, NSDictionary<NSKeyValueChangeKey,id> *change);

+ (instancetype)shared;

+ (void)addObserverWithObject:(id)object
                   forKeyPath:(NSString *)keyPath
                      options:(NSKeyValueObservingOptions)options
                      context:(void *)context;

- (void)addObserverWithObject:(id)object forKeyPath:(NSString *)keyPath;

- (void)addObserverWithObject:(id)object
                   forKeyPath:(NSString *)keyPath
                      options:(NSKeyValueObservingOptions)options;

- (void)addObserverWithObject:(id)object
                   forKeyPath:(NSString *)keyPath
                      options:(NSKeyValueObservingOptions)options
                      context:(void *)context;

@end

NS_ASSUME_NONNULL_END
