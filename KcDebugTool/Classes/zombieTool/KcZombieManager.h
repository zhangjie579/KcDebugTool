//
//  KcZombieManager.h
//  KcDebugTool
//
//  Created by 张杰 on 2023/9/18.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
 使用说明:
 1、开启野指针检测
    * 缺点: 只能检查 NSObject 的子类, 因为是通过 hook dealloc
 2、在崩溃的地方，打印alloc、dealloc堆栈
    [KcMallocStackLoggingTooler.sharedInstance enumerateMallocStackLoggingRecordsTraceAddress:(uintptr_t)0x13335 isAlloc:false];

    [KcMallocStackLoggingTooler mallocStackLogTraceObjc:objc];
 
 
 原理:
 1、hook NSObject dealloc, 缺点只能处理 NSObject 的子类
 2、只有不free，enumerateMallocStackLoggingRecordsTraceAddress方法获取dealloc的堆栈也是正确的(内存不会被重复使用)
 3、通过将 memset(p, 0x55, memSize) 增加crash
 4、由于对象会一直被free，对于内存压力较大, 通常只需要check自定义class即可, 对于系统的class没有必要
 */
@interface KcZombieManager : NSObject

+ (instancetype)sharedInstance;

/// 检查Zombie的类名, 如果为空的话, 监听全部的NSObject对象
@property (nonatomic, strong) NSMutableArray<NSString *> *blackZombieClassNames;

/// 开启监听zombie, 如果classNames为空的话, 监听全部的NSObject对象
- (void)startWithZombieClassNames:(nullable NSArray<NSString *> *)classNames;

@end

NS_ASSUME_NONNULL_END
