//
//  KcEnergyMonitor.h
//  Pods
//
//  Created by 张杰 on 2023/6/26.
//  监听CPU https://mp.weixin.qq.com/s/nGLgQfq8k3pzxUaTZa8uNQ

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 原理: 固定的统计窗口内CPU超过限制的次数超过一定次数时(5/8)，抓取当前线程堆栈。当抓取线程堆栈数量超过设定阈值时，将采集到的堆栈聚合、排序并上报。
@interface KcEnergyMonitor : NSObject

/// 使用的CPU阈值, 默认为0.8(80%)
@property (nonatomic, assign) float thresholdUsedCPU;

+ (instancetype)sharedInstance;

- (void)start;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
